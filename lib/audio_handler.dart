import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart' show MethodChannel;

/// Which page currently owns the single media session.
enum PlaybackMode { idle, radio, recordings }

/// What the media session needs from whichever page is currently driving audio.
/// The radio player and the recordings library each implement this; exactly one
/// is attached to [EzAudioHandler] at a time. Transport events from the
/// notification / lock screen / Bluetooth / car are forwarded to the active
/// driver, which owns the actual [AudioPlayer] + recorder + metadata lifecycle.
///
/// Radio has no natural pause/seek/skip: `driverPause` silences the speaker while
/// keeping the recording/metadata socket alive (non-destructive), and seek/skip
/// are no-ops. Recordings implement all of them.
abstract class AudioModeDriver {
  Future<void> driverPlay();
  Future<void> driverPause();
  Future<void> driverStop();
  Future<void> driverSeek(Duration position);
  Future<void> driverSkipNext();
}

/// Best-effort native Wi-Fi lock (Android only), mirroring what
/// flutter_foreground_task used to hold. `audio_service` keeps a wake lock and a
/// foreground service but does NOT hold a `WifiManager.WifiLock`, and the ICY
/// metadata/recording socket (a separate connection from ExoPlayer) needs the
/// Wi-Fi radio kept awake under Doze to keep feeding the recorder with the screen
/// off. Backed by a tiny MethodChannel implemented in MainActivity.kt.
class WifiLock {
  static const _channel = MethodChannel('ez_tunein/wifi_lock');

  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('acquire');
    } catch (_) {}
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('release');
    } catch (_) {}
  }
}

/// Requests the Android 13+ (`API 33`) `POST_NOTIFICATIONS` runtime permission.
/// Without it audio_service can't post its foreground-service media notification,
/// so there are **no** lock-screen / notification / Bluetooth-card controls AND
/// the foreground service can't keep the app alive — playback dies ~20s after the
/// screen turns off. Below API 33 the permission is install-time granted, so the
/// native side no-ops. Best-effort, Android-only. Backed by a MethodChannel in
/// MainActivity.kt.
class NotificationPermission {
  static const _channel = MethodChannel('ez_tunein/notifications');

  static Future<void> request() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('requestPermission');
    } catch (_) {}
  }
}

/// The app's single [AudioHandler]. It owns the platform MediaSession (rich media
/// notification, lock-screen controls, Bluetooth/headset/car AVRCP) but delegates
/// all actual playback to the active [AudioModeDriver] — this is what lets the app
/// keep TWO independent [AudioPlayer]s (radio + recordings) behind one session,
/// which `just_audio_background` could not do.
///
/// On desktop this object is constructed directly (never handed to
/// `AudioService.init`), so no native session is bound and the publish/transport
/// calls are harmless pushes to unobserved streams.
class EzAudioHandler extends BaseAudioHandler {
  PlaybackMode _mode = PlaybackMode.idle;
  AudioModeDriver? _driver;
  Uri? _artUri; // file:// to the cached app icon, used as consistent card art

  PlaybackMode get mode => _mode;

  /// Set once at startup (see `_prepareArtUri` in main.dart).
  void setArtUri(Uri uri) => _artUri = uri;

  /// A page becomes the active driver (radio on `_play`, recordings on first
  /// `_playAt`). Acquires the Wi-Fi lock so the background socket keeps flowing.
  void attach(PlaybackMode mode, AudioModeDriver driver) {
    _mode = mode;
    _driver = driver;
    WifiLock.acquire();
  }

  /// A page relinquishes control (radio `_stop`, recordings `_stopPlayback` /
  /// dispose). Only clears the session if the caller is still the active driver —
  /// a late detach from a page that already handed off can't wipe the other
  /// page's session (the key handoff-race guard).
  void detach(AudioModeDriver driver) {
    if (!identical(_driver, driver)) return;
    _driver = null;
    _mode = PlaybackMode.idle;
    WifiLock.release();
    mediaItem.add(null);
    playbackState.add(playbackState.value.copyWith(
      controls: const [],
      systemActions: const {},
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }

  // ---- Driver → handler: publish what the card should show ----

  /// Radio: title = station, artist = now-playing text (or a status), no
  /// duration (live/indeterminate). Controls: Play/Pause + Stop.
  void publishRadio({
    required String stationName,
    required String nowPlaying,
    required bool playing,
    required bool recording,
  }) {
    mediaItem.add(MediaItem(
      id: 'radio:$stationName',
      title: stationName,
      artist: nowPlaying.isNotEmpty
          ? nowPlaying
          : (recording ? 'Recording…' : 'Live'),
      album: recording ? 'Recording…' : 'EZ-TuneIn',
      artUri: _artUri,
    ));
    playbackState.add(playbackState.value.copyWith(
      controls: [
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop
      },
      androidCompactActionIndices: const [0, 1],
      processingState: AudioProcessingState.ready,
      playing: playing,
    ));
  }

  /// Recordings: a finite file with a duration + a working lock-screen scrubber.
  /// Controls: Play/Pause + Skip + Stop.
  void publishRecording({
    required String label,
    required Duration? duration,
    required bool playing,
  }) {
    mediaItem.add(MediaItem(
      id: 'rec:$label',
      title: label,
      album: 'EZ-TuneIn recordings',
      artUri: _artUri,
      duration: duration,
    ));
    playbackState.add(playbackState.value.copyWith(
      controls: [
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop,
        MediaAction.skipToNext,
        MediaAction.seek,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: AudioProcessingState.ready,
      playing: playing,
    ));
  }

  /// Recordings only: push position/buffered so the lock-screen scrubber tracks.
  void updateRecordingPosition({
    required Duration position,
    required Duration buffered,
    required bool playing,
  }) {
    playbackState.add(playbackState.value.copyWith(
      updatePosition: position,
      bufferedPosition: buffered,
      playing: playing,
    ));
  }

  // ---- Handler → driver: transport from notification / BT / car / headset ----

  @override
  Future<void> play() async => _driver?.driverPlay();

  @override
  Future<void> pause() async => _driver?.driverPause();

  @override
  Future<void> stop() async => _driver?.driverStop();

  @override
  Future<void> seek(Duration position) async => _driver?.driverSeek(position);

  @override
  Future<void> skipToNext() async => _driver?.driverSkipNext();

  /// Swiped away from Recents: stop through the active driver so an in-progress
  /// recording is finalized/saved before the process dies (the handler runs on
  /// the main isolate, so the recorder is reachable — unlike the old
  /// flutter_foreground_task isolate, which just dropped it).
  @override
  Future<void> onTaskRemoved() async {
    await _driver?.driverStop();
    await super.onTaskRemoved();
  }
}
