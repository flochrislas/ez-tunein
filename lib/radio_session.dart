import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_prefs.dart';
import 'audio_handler.dart';
import 'csv_utils.dart';
import 'icy_reader.dart';
import 'log.dart';
import 'models/station.dart';
import 'storage_paths.dart';
import 'stream_recorder.dart';
import 'track_utils.dart';

// ---------------------------------------------------------------------------
// Pure helpers (no I/O, no state) — the display/gating logic, extracted so it's
// unit-tested directly without a live audio backend.
// ---------------------------------------------------------------------------

/// Message shown in the now-playing box when there's no title yet — distinct per
/// metadata state so the user can tell "still connecting" from "this station has
/// no track info" from "the metadata connection failed".
String metaStatusMessage(MetadataStatus status) {
  switch (status) {
    case MetadataStatus.idle:
    case MetadataStatus.connecting:
      return 'Connecting…';
    case MetadataStatus.unsupported:
      return 'This station doesn\'t provide track info.';
    case MetadataStatus.failed:
      return 'Track info unavailable.';
    case MetadataStatus.waitingForFirstTitle:
    case MetadataStatus.active:
      return 'Waiting for track info…';
  }
}

/// The now-playing line. Shows a live title when the feed is fresh; keeps a stale
/// title visible across a brief reconnect; and, once reconnects are exhausted,
/// flags it as stale rather than passing it off as current.
String nowPlayingLine({
  required bool loading,
  required bool playing,
  required bool streamError,
  required bool trackInfoFresh,
  required String nowPlaying,
  required MetadataStatus metaStatus,
}) {
  if (loading) return 'Connecting…';
  if (!playing) return '—';
  // A dead player wins over any (auto-reconnecting) ICY title, so lost audio
  // can't keep masquerading as playing (C3).
  if (streamError) return 'Stream lost — tap the station to reconnect.';
  if (trackInfoFresh && nowPlaying.isNotEmpty) return nowPlaying;
  if (nowPlaying.isNotEmpty && metaStatus == MetadataStatus.failed) {
    return 'Track info unavailable — last: $nowPlaying';
  }
  // Reconnecting gap: keep the (stale) title rather than flicker the message.
  if (nowPlaying.isNotEmpty && metaStatus == MetadataStatus.connecting) {
    return nowPlaying;
  }
  return metaStatusMessage(metaStatus);
}

/// Whether recording can be *started* now: buffering on, a station playing, and
/// either a fresh live title (auto mode) or a title-less station we're streaming
/// raw (manual mode).
bool canRecordNow({
  required bool recBuffering,
  required bool hasStation,
  required bool trackInfoFresh,
  required MetadataStatus metaStatus,
}) =>
    recBuffering &&
    hasStation &&
    (trackInfoFresh || metaStatus == MetadataStatus.unsupported);

/// Bytes of a stream at [kbps] over [seconds] (kbps × 1000 / 8 = kbps × 125).
/// Used to cap a manual recording's lead-in.
int leadInBytes(int kbps, int seconds) => kbps * 125 * seconds;

/// A friendly codec label from a stream's `Content-Type`, or null if it's
/// missing/unrecognised (better to show nothing than a cryptic MIME string).
String? streamFormatLabel(String? contentType) {
  final c = (contentType ?? '').toLowerCase();
  if (c.isEmpty) return null;
  if (c.contains('aac')) return 'AAC';
  if (c.contains('opus')) return 'Opus';
  if (c.contains('ogg') || c.contains('vorbis')) return 'OGG';
  if (c.contains('flac')) return 'FLAC';
  if (c.contains('wav')) return 'WAV';
  if (c.contains('mpeg') || c.contains('mp3')) return 'MP3';
  return null;
}

// ---------------------------------------------------------------------------

/// Owns the live radio session — the [AudioPlayer], the [IcyReader] metadata
/// side-channel, and the [StreamRecorder] — plus all the session/staleness/
/// freshness state. Extracted from the player page's State so the audio logic is
/// isolated (and testable at the seams) while the widget keeps only UI: it
/// listens for [notifyListeners] to rebuild, sends user-facing text through
/// [onMessage] (snackbars), and calls the methods below from its controls.
///
/// It is the [AudioModeDriver] for the radio mode, so media-session / Bluetooth
/// transport routes straight here.
class RadioSession extends ChangeNotifier implements AudioModeDriver {
  final _player = AudioPlayer();
  final _icy = IcyReader();
  final _recorder = StreamRecorder();
  StreamSubscription<PlaybackEvent>? _playbackSub;
  SharedPreferences? _prefs;
  bool _disposed = false;

  Station? _current;
  // True while paused from the media session/Bluetooth: audio is stopped but the
  // metadata/recording socket stays alive (non-destructive).
  bool _paused = false;
  bool _loading = false;
  // True when the player has errored (mid-stream drop, decode failure, a failed
  // play()). Surfaces "Stream lost" instead of the fake "playing" the ICY
  // auto-reconnect would otherwise mask (C3). Cleared on a fresh play/stop.
  bool _streamError = false;
  String _nowPlaying = ''; // raw "Artist - Title" string from the stream
  MetadataStatus _metaStatus = MetadataStatus.idle;
  // Whether the displayed title reflects a *live* metadata feed (status active).
  bool _trackInfoFresh = false;
  // Monotonic play-session id: bumped on every play() so late async work from a
  // superseded station (a fast switch) can't update state / history / recording.
  int _playSession = 0;
  double _volume = 1.0;
  bool _muted = false;
  String _lastHistoryTitle = '';
  bool _recording = false;
  bool _manualRecording = false;
  bool _arming = false; // an arm() call is awaiting the recorder op queue (C2)
  bool _recBuffering = true;
  int _recLeadSeconds = recLeadSecondsDefault;
  String _lastRecTitle = '';

  /// One-shot user messages (snackbars). Set by the widget.
  void Function(String message)? onMessage;

  // --- read-only state for the UI ---
  Station? get current => _current;
  bool get paused => _paused;
  bool get loading => _loading;
  bool get isPlaying => _current != null;
  bool get recording => _recording;
  bool get manualRecording => _manualRecording;
  bool get recBuffering => _recBuffering;
  bool get trackInfoFresh => _trackInfoFresh;
  double get volume => _volume;
  bool get muted => _muted;

  bool get canRecord => canRecordNow(
        recBuffering: _recBuffering,
        hasStation: _current != null,
        trackInfoFresh: _trackInfoFresh,
        metaStatus: _metaStatus,
      );

  String get nowPlayingText => nowPlayingLine(
        loading: _loading,
        playing: isPlaying,
        streamError: _streamError,
        trackInfoFresh: _trackInfoFresh,
        nowPlaying: _nowPlaying,
        metaStatus: _metaStatus,
      );

  /// Small "format · bitrate" line under the title, from the ICY response
  /// headers (either may be absent). Null when neither is known.
  String? get streamInfoLine {
    final fmt = streamFormatLabel(_icy.contentType);
    final br = _icy.bitrateKbps;
    if (fmt == null && br == null) return null;
    if (fmt != null && br != null) return '$fmt · $br kbps';
    return fmt ?? '$br kbps';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Wire the player error listener, versioned User-Agent, output folder, and
  /// load the volume + recording prefs. Call once after construction.
  Future<void> init() async {
    _recorder.outputDirResolver = recordingsDir;
    _icy.userAgent = appUserAgent;
    // Observe the player so a mid-stream failure surfaces instead of the UI (and
    // the auto-reconnecting ICY feed) pretending it's still playing (C3).
    _playbackSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace _) => _onPlayerError(e),
    );
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final savedVolume = prefs.getDouble(volumeKey);
    if (savedVolume != null) {
      _volume = savedVolume;
      await _player.setVolume(savedVolume);
    }
    // Recording config (defaults: buffering on, 35 MB). Clamp to recBufferMbMax
    // so an old saved value above the new cap is still bounded.
    final buffering = prefs.getBool(recBufferingKey) ?? true;
    final bufMb = (prefs.getInt(recBufferMbKey) ?? recBufferMbDefault)
        .clamp(5, recBufferMbMax);
    _recorder.bufferingEnabled = buffering;
    _recorder.bufferCapBytes = bufMb * 1024 * 1024;
    _recBuffering = buffering;
    _recLeadSeconds = prefs.getInt(recLeadSecondsKey) ?? recLeadSecondsDefault;
    _notify();
  }

  /// Re-apply recording prefs after the settings view changes them, and reflect a
  /// buffering on/off switch on the live stream.
  Future<void> applyRecordingPrefs() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final buffering = prefs.getBool(recBufferingKey) ?? true;
    final bufMb = (prefs.getInt(recBufferMbKey) ?? recBufferMbDefault)
        .clamp(5, recBufferMbMax);
    final was = _recBuffering;
    _recorder.bufferingEnabled = buffering;
    _recorder.bufferCapBytes = bufMb * 1024 * 1024;
    _recBuffering = buffering;
    _recLeadSeconds = prefs.getInt(recLeadSecondsKey) ?? recLeadSecondsDefault;
    _notify();
    if (_current != null && buffering != was) {
      if (buffering) {
        await _recorder.startBuffering();
      } else {
        final result = await _recorder.onStreamStopped();
        _recording = false;
        _manualRecording = false;
        _notify();
        _publishRadio(); // clear "recording" from the card
        if (result.path != null) {
          onMessage?.call('Saved recording: ${baseName(result.path!)}');
        } else if (result.error != null) {
          onMessage?.call('Recording failed: ${result.error}');
        }
      }
      // A title-less station only streams its (second) audio connection when
      // buffering is on, so restart the reader to match the new flag. Also cover
      // a mid-reconnect (connecting) or exhausted (failed) reader — it may be an
      // unsupported station whose flag now needs to change (C5).
      if (_metaStatus == MetadataStatus.unsupported ||
          _metaStatus == MetadataStatus.connecting ||
          _metaStatus == MetadataStatus.failed) {
        _startIcy(_current!, ++_playSession);
      }
    }
  }

  Future<void> play(Station station) async {
    // A new session: any late work from the previous station (a fast switch)
    // checks this id and bails before touching state / history / recording.
    final session = ++_playSession;
    _current = station;
    _paused = false;
    _loading = true;
    _streamError = false;
    _nowPlaying = '';
    _trackInfoFresh = false;
    _metaStatus = MetadataStatus.connecting;
    _lastHistoryTitle = ''; // new session: let the first song log even if same
    _lastRecTitle = ''; // reset the recorder's track-change dedup
    _recording = false;
    _manualRecording = false;
    _notify();
    // Drop the previous station's metadata connection up front — it's irrelevant
    // once the user switched, and this ensures even a *failed* retune (setUrl
    // throws below) doesn't leave the old reader reconnecting in the background.
    await _icy.stop();
    // Switching station ends any in-progress recording (spec: a station change
    // stops recording) — finalize it before we retune.
    final result = await _recorder.onStreamStopped();
    if (session != _playSession) return; // superseded while finalizing
    if (result.path != null) {
      onMessage?.call('Saved recording: ${baseName(result.path!)}');
    } else if (result.error != null) {
      onMessage?.call('Recording failed: ${result.error}');
    }
    try {
      await _player.setUrl(station.url);
      // Don't await play(): for an endless radio stream just_audio's play()
      // Future never completes (it only resolves when playback ends/stops), so
      // awaiting it would block here forever. catchError so a late play() failure
      // surfaces instead of going unhandled.
      unawaited(_player.play().catchError((Object e) => _onPlayerError(e)));
    } catch (e) {
      // Playback failed: return to the stopped state instead of looking like
      // we're playing and waiting for track info.
      if (session != _playSession || _disposed) return;
      _current = null;
      _loading = false;
      _nowPlaying = '';
      _trackInfoFresh = false;
      _metaStatus = MetadataStatus.idle;
      _lastHistoryTitle = '';
      _lastRecTitle = '';
      _recording = false;
      _manualRecording = false;
      _notify();
      onMessage?.call('Could not play ${station.name}: $e');
      audioHandler.detach(this); // no station on ⇒ tear the session down
      return;
    }
    if (session != _playSession || _disposed) return; // superseded
    _loading = false;
    _notify();
    // Start a fresh buffer (if enabled) before audio flows, then the metadata/
    // audio reader. The callbacks are session-guarded so a stale connection
    // can't write into current state.
    await _recorder.startBuffering();
    if (session != _playSession) return;
    _startIcy(station, session);
    _publishRadio(); // raise (or refresh) the media session for this station
  }

  /// Open the metadata/audio reader for [station], tagging its callbacks with
  /// [session] so a superseded connection can't write into current state.
  void _startIcy(Station station, int session) {
    _icy.start(
      station.url,
      bufferWithoutMetadata: _recBuffering,
      onTitle: (title) {
        if (session != _playSession || _disposed) return;
        // The reader re-emits the same title every icy-metaint bytes
        // (~1–2.5×/sec). Rebuild only on a real change or on recovery from a
        // non-active status — otherwise we rebuild for nothing (P1). History +
        // track-change still run each tick (they dedup); _recordHistory must,
        // so re-enabling history mid-song still logs the current track.
        final unchanged = title == _nowPlaying &&
            _trackInfoFresh &&
            _metaStatus == MetadataStatus.active;
        if (!unchanged) {
          _nowPlaying = title;
          _metaStatus = MetadataStatus.active;
          _trackInfoFresh = true; // live title ⇒ Save/Record are meaningful
          _notify();
        }
        _recordHistory(title);
        _handleTrackChange(title);
      },
      // No buffering ⇒ no audio sink, so the parser skips copying/forwarding
      // audio runs entirely (P7).
      onAudio: _recBuffering ? _recorder.addAudio : null,
      onStatus: (status) {
        if (session != _playSession || _disposed) return;
        _metaStatus = status;
        // Only an active feed is "fresh". A drop/exhausted-reconnect (failed),
        // an unsupported station, or a reconnecting gap (connecting) means the
        // shown title is stale — don't let it be saved/recorded.
        _trackInfoFresh = status == MetadataStatus.active;
        _notify();
      },
    );
  }

  Future<void> setVolume(double value) async {
    // Touching the slider is an explicit volume choice, so it also unmutes.
    _volume = value;
    _muted = false;
    _notify();
    await _player.setVolume(value);
  }

  /// Persist the volume once, on slider release, rather than on every drag frame
  /// (P9). Called from the slider's onChangeEnd.
  Future<void> persistVolume(double value) async {
    await _prefs?.setDouble(volumeKey, value);
  }

  /// Re-read the shared `volume` pref (the recordings view can change it) and
  /// apply it to the player + slider so they don't drift out of sync.
  Future<void> reloadVolume() async {
    final v = _prefs?.getDouble(volumeKey);
    if (v == null || v == _volume) return;
    _volume = v;
    _notify();
    if (!_muted) await _player.setVolume(v);
  }

  /// Silence the radio without disconnecting (keeps the stream + metadata alive).
  Future<void> toggleMute() async {
    _muted = !_muted;
    _notify();
    await _player.setVolume(_muted ? 0 : _volume);
  }

  Future<void> stop() async {
    _playSession++; // invalidate any in-flight play / metadata callbacks
    await _player.stop();
    await _icy.stop();
    final result = await _recorder.onStreamStopped();
    // Drop mute and restore the real volume so the next station isn't silent.
    if (_muted) await _player.setVolume(_volume);
    _current = null;
    _paused = false;
    _nowPlaying = '';
    _trackInfoFresh = false;
    _metaStatus = MetadataStatus.idle;
    _lastHistoryTitle = '';
    _lastRecTitle = '';
    _recording = false;
    _manualRecording = false;
    _muted = false;
    _streamError = false;
    _notify();
    // Nothing playing now ⇒ tear the media session down.
    audioHandler.detach(this);
    if (result.path != null) {
      onMessage?.call('Saved recording: ${baseName(result.path!)}');
    } else if (result.error != null) {
      onMessage?.call('Recording failed: ${result.error}');
    }
  }

  /// Non-destructive pause for live radio, from the media session / Bluetooth /
  /// car. Silences the speaker (stops ExoPlayer) but keeps the ICY metadata +
  /// recording socket running, so an in-progress recording is NOT interrupted.
  Future<void> _pauseRadio() async {
    if (_current == null || _paused) return;
    await _player.pause();
    _paused = true;
    _notify();
    _publishRadio();
  }

  /// Resume after [_pauseRadio]: ExoPlayer restarts from the live edge. The
  /// metadata/recording socket never stopped, so nothing else needs restarting.
  Future<void> _resumeRadio() async {
    if (_current == null || !_paused) return;
    // never await an endless stream (see play); catch a late failure.
    unawaited(_player.play().catchError((Object e) => _onPlayerError(e)));
    _paused = false;
    _streamError = false;
    _notify();
    _publishRadio();
  }

  /// The player errored (mid-stream drop, decode failure, or a failed late
  /// play()). Surface it instead of the fake "playing" the ICY auto-reconnect
  /// would otherwise mask. Reconnect is manual — the user re-taps the station.
  void _onPlayerError(Object e) {
    if (_disposed || _current == null) return; // already stopped / switching
    _streamError = true;
    _loading = false;
    _notify();
    onMessage?.call('Stream lost — tap the station to reconnect.');
  }

  /// React to a genuine track change (the ICY reader re-emits the same title each
  /// tick, so we dedup on [_lastRecTitle]). The very first title of a session is
  /// the initial track — the buffer is already running from [play], so we don't
  /// reset it; only a real change finalizes an armed recording and clears it.
  Future<void> _handleTrackChange(String title) async {
    if (title == _lastRecTitle) return;
    final isFirst = _lastRecTitle.isEmpty;
    _lastRecTitle = title;
    if (isFirst) {
      _publishRadio(); // reflect the first real title in the media card
      return;
    }
    final result = await _recorder.onTrackChanged();
    // A finished (path) or failed (error) recording both end the recording
    // state — clear the red glow either way, else it persists indefinitely.
    if (result.path != null || result.error != null) {
      _recording = false;
      _manualRecording = false;
      _notify();
      onMessage?.call(result.path != null
          ? 'Saved recording: ${baseName(result.path!)}'
          : 'Recording failed: ${result.error}');
    }
    _publishRadio(); // refresh the card for the new track / cleared state
  }

  /// Arm recording, or finish/cancel an in-progress one.
  Future<void> toggleRecord() async {
    if (_recording) {
      if (_manualRecording) {
        // No upcoming track change to auto-save on — this tap is the save.
        unawaited(_saveManualRecording());
      } else {
        _recorder.cancel();
        _recording = false;
        _notify();
        _publishRadio(); // card back to "playing"
        onMessage?.call('Recording cancelled.');
      }
      return;
    }
    if (_current == null) {
      onMessage?.call('Start a station first.');
      return;
    }
    // A prior arm is still resolving — ignore the double-tap.
    if (_arming) return;
    // Title-less station ⇒ user-bounded ("manual") recording, named after the
    // station + a timestamp since there's no Artist - Title.
    final manual = !_trackInfoFresh;
    if (!manual && _nowPlaying.isEmpty) {
      onMessage?.call('Wait for the track info before recording.');
      return;
    }
    final recName = manual ? '${_current!.name} ${_recStamp()}' : _nowPlaying;
    // Cap the lead-in for manual recordings (title-less stations have no song
    // boundary). Titled recordings pass null: the buffer starts at the song.
    int? lead;
    if (manual && _recLeadSeconds >= 0) {
      final kbps = _icy.bitrateKbps ?? 128; // fall back if the server omits it
      lead = leadInBytes(kbps, _recLeadSeconds);
    }
    // arm() is queued through the recorder's op lock, so a tap landing during an
    // in-flight finalize/startBuffering (e.g. right at a track change) waits for
    // the fresh buffer and arms it rather than silently no-opping (C2). Only mark
    // the UI as recording once arming actually succeeded.
    _arming = true;
    final armed = await _recorder.arm(recName, _current!.name, _icy.contentType,
        leadInBytes: lead);
    _arming = false;
    if (_disposed) return;
    if (!armed) {
      onMessage?.call('Couldn\'t start recording — try again.');
      return;
    }
    _recording = true;
    _manualRecording = manual;
    _notify();
    _publishRadio(); // reflect "recording" in the card
    onMessage?.call(manual
        ? 'Recording… tap again to save.'
        : 'Recording… it saves automatically when the track changes.');
  }

  /// Finalize a manual (title-less) recording and start a fresh buffer.
  Future<void> _saveManualRecording() async {
    final result = await _recorder.onTrackChanged(); // finalize + fresh buffer
    _recording = false;
    _manualRecording = false;
    _notify();
    _publishRadio();
    if (result.path != null) {
      onMessage?.call('Saved recording: ${baseName(result.path!)}');
    } else if (result.error != null) {
      onMessage?.call('Recording failed: ${result.error}');
    } else {
      onMessage?.call('Nothing recorded yet.');
    }
  }

  /// Save the currently-playing title to the saved-tracks CSV.
  Future<void> saveCurrentTrack() async {
    if (_current == null || _nowPlaying.isEmpty) {
      onMessage?.call('Nothing playing yet — no track to save.');
      return;
    }
    // ICY only gives us "Artist - Title". Album is rarely present.
    final parts = splitArtistTitle(_nowPlaying);
    final artist = parts.artist;
    final title = parts.title;
    final row = [
      DateTime.now().toIso8601String(),
      _current!.name,
      artist,
      title,
      '', // album (not available from ICY)
      _nowPlaying, // raw, as a fallback
    ].map(csvField).join(',');
    try {
      final file = await savedTracksFile();
      if (!await file.exists()) {
        await file.writeAsString('timestamp,station,artist,title,album,raw\n');
      }
      await file.writeAsString('$row\n', mode: FileMode.append);
      onMessage?.call('Saved: ${artist.isEmpty ? title : "$artist — $title"}');
    } catch (e) {
      onMessage?.call('Save failed: $e');
    }
  }

  /// Append a song to the play history the first time we see its title for the
  /// current session (the ICY reader re-emits the same title each tick — hence
  /// the dedup). Best-effort, like metadata.
  Future<void> _recordHistory(String rawTitle) async {
    final station = _current;
    if (station == null || rawTitle.isEmpty || rawTitle == _lastHistoryTitle) {
      return;
    }
    // Logging can be turned off from the History view. Bail before updating
    // _lastHistoryTitle so re-enabling mid-song still logs the current track.
    if (!(_prefs?.getBool(historyLoggingKey) ?? true)) return;
    _lastHistoryTitle = rawTitle;
    final parts = splitArtistTitle(rawTitle);
    final row = [
      DateTime.now().toIso8601String(),
      station.name,
      parts.artist,
      parts.title,
      '', // album (not available from ICY)
      rawTitle, // raw, as a fallback
    ].map(csvField).join(',');
    try {
      final file = await historyFile();
      if (!await file.exists()) {
        await file.writeAsString('timestamp,station,artist,title,album,raw\n');
      }
      await file.writeAsString('$row\n', mode: FileMode.append);
      // Keep the unbounded history in check: rewrite to the newest rows once it
      // grows past the size cap (rarely, so O(file) isn't paid per song).
      if (await file.length() > historyCapBytes) {
        final trimmed = capCsvRows(await file.readAsString(), historyKeepRows);
        if (trimmed != null) await file.writeAsString(trimmed);
      }
    } catch (e) {
      // History is a best-effort log — don't disrupt playback, just trace it.
      logSwallowed('_recordHistory', e);
    }
  }

  /// A filename-safe `YYYY-MM-DD HH.MM` stamp for naming title-less recordings.
  String _recStamp() {
    final n = DateTime.now();
    return '${n.year}-${pad2(n.month)}-${pad2(n.day)} '
        '${pad2(n.hour)}.${pad2(n.minute)}';
  }

  /// Update the current station's label after the user edits it (playback keeps
  /// running on the old connection until they re-tap).
  void renameCurrent(Station updated) {
    if (_current == null) return;
    _current = updated;
    _notify();
    _publishRadio();
  }

  /// Publish the current radio state to the media session (rich notification +
  /// lock screen + Bluetooth/car). No-op off mobile; best-effort.
  void _publishRadio() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    if (_current == null) {
      audioHandler.detach(this);
      return;
    }
    audioHandler.attach(PlaybackMode.radio, this);
    audioHandler.publishRadio(
      stationName: _current!.name,
      nowPlaying: _nowPlaying,
      playing: !_paused,
      recording: _recording,
    );
  }

  // --- AudioModeDriver: transport from the media session / Bluetooth / car ---

  @override
  Future<void> driverPlay() async {
    // driverPlay only fires while this is the active driver, which means a
    // station is loaded (playing or paused). So the only meaningful action is
    // resuming from a pause; a full Stop detaches the session entirely.
    if (_paused) await _resumeRadio();
  }

  @override
  Future<void> driverPause() => _pauseRadio();

  @override
  Future<void> driverStop() => stop();

  // Live radio has no seek/skip.
  @override
  Future<void> driverSeek(Duration position) async {}

  @override
  Future<void> driverSkipNext() async {}

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _playbackSub?.cancel();
    _player.dispose();
    _icy.stop();
    _recorder.dispose();
    audioHandler.detach(this);
    super.dispose();
  }

  /// Await-able teardown for the desktop close path, which hard-exits (`exit(0)`)
  /// and so skips [dispose]. Awaits the recorder's cleanup so its private temp
  /// dir is actually removed before the process dies (S3/C6). Call [stop] first
  /// to finalize any in-progress recording.
  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    await _playbackSub?.cancel();
    await _icy.stop();
    await _recorder.dispose();
    await _player.dispose();
    audioHandler.detach(this);
    super.dispose();
  }
}
