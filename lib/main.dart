import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'csv_utils.dart';
import 'icy_reader.dart';
import 'storage_paths.dart';
import 'stream_recorder.dart';
import 'track_utils.dart';

const _winWidthKey = 'win_w';
const _winHeightKey = 'win_h';
// Whether the player logs played songs to the history CSV. Toggled from the
// History view, read by the player; defaults to on. Top-level so both screens
// share it (shared_preferences returns one cached instance, so a write here is
// immediately visible to the player without extra plumbing).
const _historyLoggingKey = 'history_logging';
// Player volume (0.0–1.0); shared by the radio player and the recordings library.
const _volumeKey = 'volume';

// Recording settings (shared across the player and the recording-settings view,
// same single-cached-instance trick as the history toggle above).
//  - rec_buffering: whether the stream is buffered (off ⇒ no Record button).
//  - rec_buffer_mb: buffer cap in MB (the "rewind" window before recording).
//  - rec_dir:       output folder; null/empty ⇒ the OS Downloads folder.
const _recBufferingKey = 'rec_buffering';
const _recBufferMbKey = 'rec_buffer_mb';
// rec_dir lives in storage_paths.dart (recDirKey) since recordingsDir() reads it.
const _recBufferMbDefault = 50;
// Recordings-library playback toggles (the _RecordingsPage view).
const _recNeverStopsKey = 'rec_never_stops'; // auto-play the next file at end
const _recRandomizeKey = 'rec_randomize'; // pick the next file at random

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Register the libmpv-based backend for desktop. On Android/iOS this is a
  // no-op — just_audio uses ExoPlayer/AVPlayer there.
  JustAudioMediaKit.ensureInitialized(
    linux: true,
    windows: true,
    macOS: true,
  );

  // Android: configure the foreground service that runs while audio plays. It
  // holds the app process in the foreground so the OS won't freeze it with the
  // screen off — keeping both playback and the recording/metadata socket loop
  // alive — and shows a notification with a Stop button (see _syncPlayback
  // Service). Pure-Dart config only here; the service starts on demand.
  if (Platform.isAndroid) {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ez_tunein_playback',
        channelName: 'Playback',
        channelDescription: 'Shown while EZ-TuneIn is playing or recording.',
        // Silent + low-key: it's a status indicator, not an alert.
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No periodic task isolate — the handler only relays Stop-button taps
        // (see _foregroundTaskCallback); the service exists to hold the process
        // in the foreground so playback + the metadata loop survive the screen
        // turning off.
        eventAction: ForegroundTaskEventAction.nothing(),
        // Keep the CPU and Wi-Fi radio awake so the stream keeps flowing.
        allowWakeLock: true,
        allowWifiLock: true,
        // If the user swipes the app away, stop everything rather than linger.
        stopWithTask: true,
      ),
    );
  }

  // On desktop, restore the saved window size before showing the window.
  if (isDesktop) {
    await windowManager.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    final w = prefs.getDouble(_winWidthKey);
    final h = prefs.getDouble(_winHeightKey);
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: (w != null && h != null) ? Size(w, h) : const Size(640, 720),
        minimumSize: const Size(420, 480),
        title: 'EZ-TuneIn Radio',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(const RadioApp());
}

/// Entry point for the foreground-service task isolate (Android). It runs in a
/// separate isolate, so it can't touch the player directly — it only relays
/// notification-button taps back to the UI isolate via [sendDataToMain], where
/// [_PlayerPageState._onForegroundData] acts on them. Must be top-level and
/// annotated so it survives tree-shaking / AOT compilation.
@pragma('vm:entry-point')
void _foregroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_PlaybackServiceHandler());
}

class _PlaybackServiceHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  // Unused: eventAction is .nothing(), so this never fires.
  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) =>
      FlutterForegroundTask.sendDataToMain(id);

  // Tapping the notification body brings the app back to the front.
  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}

/// A radio station: a display name and an Icecast/Shoutcast stream URL.
class Station {
  const Station(this.name, this.url);
  final String name;
  final String url;

  Map<String, String> toJson() => {'name': name, 'url': url};
  factory Station.fromJson(Map<String, dynamic> j) =>
      Station(j['name'] as String, j['url'] as String);
}

// The list users start with on first launch; afterwards it's whatever they've
// saved (see _stationsKey). Add/remove from the UI.
// Sourced from radios-selection.csv — keep the two in sync if you curate the set.
const _defaultStations = <Station>[
  // Direct relay from swissgroove.ch's listen.php M3U.
  Station('SwissGroove', 'http://relay1.swissgroove.ch:80'),
  // Nightride FM — Icecast mounts, 320 kbps MP3.
  Station('Nightride FM (Synthwave / Outrun)',
      'https://stream.nightride.fm/nightride.mp3'),
  Station('Nightride FM — Chillsynth',
      'https://stream.nightride.fm/chillsynth.mp3'),
  Station('Nightride FM — Datawave (Glitchy Retro Computing / IDM)',
      'https://stream.nightride.fm/datawave.mp3'),
  Station('Nightride FM — Darksynth (Cyberpunk / Synthmetal)',
      'https://stream.nightride.fm/darksynth.mp3'),
  Station('Nightride FM — Spacesynth (Space Disco / Italo)',
      'https://stream.nightride.fm/spacesynth.mp3'),
  Station('Nightride FM — Horrorsynth',
      'https://stream.nightride.fm/horrorsynth.mp3'),
  Station('Nightride FM — EBSM (Industrial / Electronic Body Synth Music)',
      'https://stream.nightride.fm/ebsm.mp3'),
  Station('Rekt Network — Rekt (Drum & Bass / EDM)',
      'https://stream.nightride.fm/rekt.mp3'),
  Station('Rekt Network — Rektory (1930s Fallout-style Jazz)',
      'https://stream.nightride.fm/rektory.mp3'),
  Station(
      'SomaFM — Groove Salad', 'http://ice5.somafm.com/groovesalad-128-mp3'),
  Station('SomaFM — Drone Zone', 'http://ice5.somafm.com/dronezone-128-mp3'),
  Station(
      'SomaFM — Deep Space One', 'http://ice5.somafm.com/deepspaceone-128-mp3'),
  Station('SomaFM — Space Station Soma',
      'http://ice5.somafm.com/spacestation-128-mp3'),
  Station('SomaFM — The Dark Zone', 'http://ice5.somafm.com/darkzone-128-mp3'),
  Station(
      'SomaFM — Beat Blender', 'http://ice5.somafm.com/beatblender-128-mp3'),
  Station('SomaFM — Vaporwaves', 'http://ice5.somafm.com/vaporwaves-128-mp3'),
  Station('SomaFM — Underground 80s', 'http://ice5.somafm.com/u80s-128-mp3'),
  Station('SomaFM — Lush', 'http://ice5.somafm.com/lush-128-mp3'),
  Station('SomaFM — The Trip', 'http://ice5.somafm.com/thetrip-128-mp3'),
  Station(
      'SomaFM — Suburbs of Goa', 'http://ice5.somafm.com/suburbsofgoa-128-mp3'),
  Station('SomaFM — DEF CON Radio', 'http://ice5.somafm.com/defcon-128-mp3'),
  Station('SomaFM — Mission Control',
      'http://ice5.somafm.com/missioncontrol-128-mp3'),
  Station(
      'SomaFM — Secret Agent', 'http://ice5.somafm.com/secretagent-128-mp3'),
  Station(
      'SomaFM — Indie Pop Rocks!', 'http://ice5.somafm.com/indiepop-128-mp3'),
  Station('Funky Radio (Classic Uncut Funk) — 320kbps MP3',
      'https://funkyradio.streamingmedia.it/play.mp3'),
  Station('Funky Radio (Classic Uncut Funk) — 192kbps AAC',
      'https://funkyradio.streamingmedia.it/audio.aac'),
  Station('WEFUNK Radio — 128kbps MP3',
      'http://stream.wefunkradio.com:8000/wefunk'),
  Station('Funky Corner Radio — 128kbps MP3',
      'http://icecast.unitedradio.it/FunkyCornerRadio'),
  Station('B4B Disco Funk — 128kbps MP3',
      'http://b4b-disco-funk.ice.infomaniak.ch/b4b-disco-funk-128.mp3'),
  Station('Radio Meuh — 128kbps MP3',
      'http://radiomeuh.ice.infomaniak.ch/radiomeuh-128.mp3'),
  Station('Classic Rock Replay (1.FM) — 192kbps MP3',
      'http://185.33.21.112:80/crock_64a'),
  Station(
      'Progulus Radio — 192kbps MP3', 'http://stream.progulus.com:8000/live'),
  Station('Morow — 128kbps MP3', 'http://stream.morow.com:8080/morow_med.mp3'),
  Station('Radio BOB! Prog-Rock — 192kbps MP3',
      'http://streams.radiobob.de/progrock/mp3-192/homepage'),
  Station('St. Louis Classic Rock — 256kbps MP3',
      'http://74.208.89.18:8000/SLCR4_highdef.mp3'),
  Station('Radio BOB! Grunge — 192kbps MP3',
      'https://streams.radiobob.de/bob-grunge/mp3-192/'),
  Station('Radio BOB! Punk — 192kbps MP3',
      'https://streams.radiobob.de/bob-punk/mp3-192/'),
  Station('Prog Rock and Metal (PRM) — 128kbps MP3',
      'http://149.56.234.138:8025/stream'),
  Station('Proteus Radio — 128kbps MP3',
      'https://proteusradio.ddns.net:9900/proteus.mp3'),
  Station('Radio BOB! Power Metal — 192kbps MP3',
      'https://streams.radiobob.de/powermetal/mp3-192/'),
  Station('Radio BOB! Symphonic Metal — 192kbps MP3',
      'https://streams.radiobob.de/symphonicmetal/mp3-192/'),
  Station("Mouv' (Radio France) — 128kbps MP3",
      'https://direct.mouv.fr/live/mouv-midfi.mp3'),
  Station(
      'Skyrock — 128kbps MP3', 'http://icecast.skyrock.net/s/natio_mp3_128k'),
  Station('Générations — 128kbps MP3',
      'http://broadcast.infomaniak.net/generationfm-high.mp3'),
  Station('J-Pop Powerplay — 128kbps MP3',
      'https://kathy.torontocast.com:3560/stream'),
  Station('J-Rock Powerplay — 128kbps MP3',
      'https://kathy.torontocast.com:3340/stream'),
  Station('J-Pop Powerplay Kawaii — 128kbps MP3',
      'https://kathy.torontocast.com:3060/stream'),
  Station('AnimeNfo Radio (Zeno Mirror) — 128kbps MP3',
      'https://stream.zeno.fm/xwa8ckz7mzzuv'),
  Station('Eurobeat FM — 128kbps MP3', 'https://stream.laut.fm/eurobeat'),
  Station('Radio BOB! Gaming Rock — 192kbps MP3',
      'https://streams.radiobob.de/gamingrock/mp3-192/'),
  Station('SLAY Radio (Retro Gaming) — 128kbps AAC',
      'http://relay1.slayradio.org:8000/'),
  Station(
      'Bigbeat-Radio — 128kbps MP3', 'https://stream.laut.fm/bigbeat-radio'),
  Station('Record Breakbeat — 128kbps MP3',
      'http://air2.radiorecord.ru:805/brb_128'),
  Station('Joint Radio Reggae — 128kbps MP3',
      'http://radio.jointil.net:9998/stream'),
  Station('Skafari — 128kbps MP3', 'https://stream.laut.fm/skafari'),
  Station('Ruffneck Smille — 128kbps MP3',
      'https://stream.laut.fm/ruffneck-smille'),
  Station('Radio Swiss Classic (French) — 128kbps MP3',
      'http://stream.srg-ssr.ch/m/rsc_fr/mp3_128'),
  Station('Radio Swiss Classic (German) — 128kbps MP3',
      'http://stream.srg-ssr.ch/m/rsc_de/mp3_128'),
  Station('WQXR Classical — 128kbps MP3', 'http://stream.wqxr.org/wqxr'),
  Station('FIP Sacré Français ! — 128kbps MP3',
      'https://icecast.radiofrance.fr/fipsacrefrancais-midfi.mp3'),
  Station('Chante France — 128kbps MP3',
      'http://chantefrance.ice.infomaniak.ch/chantefrance-128.mp3'),
  Station('Dubstep.fm — 256kbps MP3', 'http://stream.dubstep.fm/256mp3'),
  Station('Dubstep.fm — 128kbps MP3', 'http://stream.dubstep.fm/128mp3'),
  Station('Best of Trap — 128kbps MP3', 'https://stream.laut.fm/bestoftrap'),
  Station('Neverdie Radio (Dubstep) — 128kbps MP3',
      'https://stream.laut.fm/neverdie-radio'),
  Station('Radio BOB! Nu Metal — 192kbps MP3',
      'https://streams.radiobob.de/numetal/mp3-192/'),
  Station('Radio BOB! Rap Metal — 192kbps MP3',
      'https://streams.radiobob.de/rapmetal/mp3-192/'),
  Station('Radio BOB! Alternative — 192kbps MP3',
      'https://streams.radiobob.de/alternative/mp3-192/'),
  Station('Celtic Music Radio (Glasgow) — 128kbps MP3',
      'http://stream.celticmusicradio.net:8000/celticmusic.mp3'),
  Station('SomaFM — Folk Forward — 128kbps MP3',
      'http://ice5.somafm.com/folkfwd-128-mp3'),
  Station(
      'RTÉ Raidió na Gaeltachta — 128kbps MP3', 'https://icecast.rte.ie/rnag'),
];

class RadioApp extends StatelessWidget {
  const RadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EZ-TuneIn Radio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const PlayerPage(),
    );
  }
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WindowListener {
  final _player = AudioPlayer();
  final _icy = IcyReader();
  Timer? _resizeDebounce;

  static const _stationsKey = 'stations';

  SharedPreferences? _prefs;
  List<Station> _stations = List.of(_defaultStations);
  Station? _current;
  bool _loading = false;
  String _nowPlaying = ''; // raw "Artist - Title" string from the stream
  // State of the ICY metadata side-channel; drives the now-playing message when
  // there's no title yet (connecting / unsupported / failed / waiting).
  MetadataStatus _metaStatus = MetadataStatus.idle;
  // Monotonic play-session id: bumped on every _play so late async work from a
  // superseded station (a fast switch) can't update the UI / history / recording.
  int _playSession = 0;
  double _volume = 1.0; // 0.0–1.0
  // Last title written to the play history; the ICY reader re-emits the same
  // title every metadata tick, so we dedup against this to log a song once.
  String _lastHistoryTitle = '';

  // Stream recorder + UI state. The ICY reader re-emits the same title each tick,
  // so track-change handling dedups against _lastRecTitle (mirrors history).
  final _recorder = StreamRecorder();
  bool _recording = false;
  bool _recBuffering = true; // mirrors _recBufferingKey; gates the Record button
  String _lastRecTitle = '';

  // Type-to-search filter over station names. On desktop, typing a printable
  // character while the page is focused opens the search bar; on mobile the
  // app-bar magnifier does. Matching is case-insensitive substring on the name.
  String _query = '';
  bool _searching = false;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(); // the search TextField
  // Holds keyboard focus when not searching so we can catch the first keystroke.
  final _pageFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    if (isDesktop) windowManager.addListener(this);
    // ICY callbacks are wired per-station in _play (with a session guard); see
    // there. Just the output-folder resolver and the service hook here.
    _recorder.outputDirResolver = _resolveOutputDir;
    // Receive notification-button taps relayed from the foreground service.
    if (Platform.isAndroid) {
      FlutterForegroundTask.addTaskDataCallback(_onForegroundData);
    }
    _restorePrefs();
  }

  // Resize fires rapidly while dragging; debounce so we persist only the
  // final size rather than hammering the prefs store on every frame.
  @override
  void onWindowResize() {
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 400), () async {
      final size = await windowManager.getSize();
      await _prefs?.setDouble(_winWidthKey, size.width);
      await _prefs?.setDouble(_winHeightKey, size.height);
    });
  }

  Future<void> _restorePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    final savedVolume = prefs.getDouble(_volumeKey);
    if (savedVolume != null) await _player.setVolume(savedVolume);

    // Recording config (defaults: buffering on, 50 MB, Downloads folder).
    final buffering = prefs.getBool(_recBufferingKey) ?? true;
    final bufMb = prefs.getInt(_recBufferMbKey) ?? _recBufferMbDefault;
    _recorder.bufferingEnabled = buffering;
    _recorder.bufferCapBytes = bufMb * 1024 * 1024;

    List<Station>? loadedStations;
    final savedStations = prefs.getString(_stationsKey);
    if (savedStations != null) {
      try {
        loadedStations = (jsonDecode(savedStations) as List)
            .map((e) => Station.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        loadedStations = null; // corrupt — fall back to defaults
      }
    }

    if (!mounted) return;
    setState(() {
      if (savedVolume != null) _volume = savedVolume;
      if (loadedStations != null) _stations = loadedStations;
      _recBuffering = buffering;
    });
  }

  /// Folder recordings are written to (shared with the recordings library view).
  Future<Directory> _resolveOutputDir() => recordingsDir();

  /// Re-apply recording prefs after the settings view changes them, and reflect a
  /// buffering on/off switch on the live stream.
  Future<void> _applyRecordingPrefs() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final buffering = prefs.getBool(_recBufferingKey) ?? true;
    final bufMb = prefs.getInt(_recBufferMbKey) ?? _recBufferMbDefault;
    final was = _recBuffering;
    _recorder.bufferingEnabled = buffering;
    _recorder.bufferCapBytes = bufMb * 1024 * 1024;
    if (mounted) setState(() => _recBuffering = buffering);
    if (_current != null && buffering != was) {
      if (buffering) {
        await _recorder.startBuffering();
      } else {
        await _recorder.onStreamStopped();
        if (mounted) setState(() => _recording = false);
        unawaited(_syncPlaybackService()); // clear "recording" from the notif
      }
    }
  }

  Future<void> _saveStations() async {
    await _prefs?.setString(
      _stationsKey,
      jsonEncode(_stations.map((s) => s.toJson()).toList()),
    );
  }

  Future<void> _addStation() async {
    final station = await showDialog<Station>(
      context: context,
      builder: (_) => const _StationDialog(),
    );
    if (station == null) return;
    if (_stations.any((s) => s.url == station.url)) {
      _snack('That stream URL is already in the list.');
      return;
    }
    setState(() => _stations.add(station));
    await _saveStations();
  }

  Future<void> _editStation(Station old) async {
    final updated = await showDialog<Station>(
      context: context,
      builder: (_) => _StationDialog(initial: old),
    );
    if (updated == null) return;
    // Reject a URL change that would collide with a *different* station.
    if (updated.url != old.url && _stations.any((s) => s.url == updated.url)) {
      _snack('That stream URL is already in the list.');
      return;
    }
    final i = _stations.indexWhere((s) => s.url == old.url);
    if (i < 0) return; // gone (e.g. removed while the dialog was open)
    setState(() {
      _stations[i] = updated;
      // Keep the now-playing highlight/title in sync if we edited the current
      // station. Playback itself keeps running on the old connection until the
      // user re-taps — only the list entry and label update.
      if (_current?.url == old.url) _current = updated;
    });
    await _saveStations();
  }

  Future<void> _removeStation(Station station) async {
    if (_current?.url == station.url) await _stop();
    setState(() => _stations.removeWhere((s) => s.url == station.url));
    await _saveStations();
  }

  /// Import stations from a user-picked CSV (`name,url` per row, optional
  /// header). Merges into the current list, skipping URLs already present, so
  /// importing is always non-destructive (same dedup rule as [_addStation]).
  Future<void> _importStations() async {
    final FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Import radio stations',
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true, // need the bytes on mobile (no readable file path)
      );
    } catch (e) {
      _snack('Import failed: $e');
      return;
    }
    if (result == null) return; // user cancelled

    final picked = result.files.single;
    String content;
    try {
      if (picked.bytes != null) {
        content = utf8.decode(picked.bytes!, allowMalformed: true);
      } else if (picked.path != null) {
        content = await File(picked.path!).readAsString();
      } else {
        _snack('Could not read the selected file.');
        return;
      }
    } catch (e) {
      _snack('Could not read the selected file: $e');
      return;
    }

    final seen = _stations.map((s) => s.url).toSet();
    final toAdd = <Station>[];
    var skipped = 0;
    for (final r in parseCsv(content)) {
      if (r.length < 2) continue;
      final name = r[0].trim();
      final url = r[1].trim();
      if (name.isEmpty || url.isEmpty) continue;
      // Tolerate a header row written by our own export (or by hand).
      if (name.toLowerCase() == 'name' && url.toLowerCase() == 'url') continue;
      if (!seen.add(url)) {
        skipped++; // duplicate within the file or already in the list
        continue;
      }
      toAdd.add(Station(name, url));
    }

    if (toAdd.isEmpty) {
      _snack(skipped > 0
          ? 'Nothing to import — those $skipped station(s) are already in your list.'
          : 'No stations found in that file.');
      return;
    }
    setState(() => _stations.addAll(toAdd));
    await _saveStations();
    _snack('Imported ${toAdd.length} station(s)'
        '${skipped > 0 ? ' ($skipped already present)' : ''}.');
  }

  /// Export the current station list to a user-chosen CSV file (`name,url`,
  /// with a header row that [_importStations] knows to skip).
  Future<void> _exportStations() async {
    if (_stations.isEmpty) {
      _snack('No stations to export.');
      return;
    }
    final csv = StringBuffer('name,url\n');
    for (final s in _stations) {
      csv.writeln('${csvField(s.name)},${csvField(s.url)}');
    }
    final bytes = utf8.encode(csv.toString());

    String? path;
    try {
      path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export radio stations',
        fileName: 'ez_tunein_stations.csv',
        type: FileType.custom,
        allowedExtensions: ['csv'],
        // Mobile can't hand back a writable path, so file_picker writes these
        // bytes itself; on desktop it returns the path and we write below.
        bytes: isDesktop ? null : bytes,
      );
    } catch (e) {
      _snack('Export failed: $e');
      return;
    }
    if (path == null) return; // user cancelled

    try {
      if (isDesktop) await File(path).writeAsString(csv.toString());
      _snack('Exported ${_stations.length} station(s).');
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  @override
  void dispose() {
    _resizeDebounce?.cancel();
    if (isDesktop) windowManager.removeListener(this);
    _searchController.dispose();
    _searchFocus.dispose();
    _pageFocus.dispose();
    _player.dispose();
    _icy.stop();
    _recorder.dispose();
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(_onForegroundData);
      unawaited(FlutterForegroundTask.stopService());
    }
    super.dispose();
  }

  /// Open the search bar, optionally seeding it with the first typed character,
  /// and move keyboard focus into the field.
  void _openSearch({String? seed}) {
    setState(() {
      _searching = true;
      if (seed != null) {
        _searchController.text = seed;
        _searchController.selection =
            TextSelection.collapsed(offset: seed.length);
        _query = seed;
      }
    });
    _searchFocus.requestFocus();
  }

  /// Clear the query and dismiss the search bar, returning focus to the page so
  /// the next keystroke can re-open it.
  void _closeSearch() {
    setState(() {
      _searching = false;
      _query = '';
      _searchController.clear();
    });
    _pageFocus.requestFocus();
  }

  // First keystroke handler: when not already searching, a printable character
  // (with no Ctrl/Alt/Meta held) opens the search bar seeded with that char.
  KeyEventResult _onPageKey(FocusNode _, KeyEvent event) {
    if (_searching || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final ch = event.character;
    // A single printable, non-control character (filters out Enter, Tab, etc.).
    if (ch == null || ch.length != 1 || ch.codeUnitAt(0) < 0x20) {
      return KeyEventResult.ignored;
    }
    _openSearch(seed: ch);
    return KeyEventResult.handled;
  }

  Future<void> _play(Station station) async {
    // A new session: any late work from the previous station (a fast switch)
    // checks this id and bails before touching UI / history / recording state.
    final session = ++_playSession;
    setState(() {
      _current = station;
      _loading = true;
      _nowPlaying = '';
      _metaStatus = MetadataStatus.connecting;
      _lastHistoryTitle =
          ''; // new session: let the first song log even if same
      _lastRecTitle = ''; // reset the recorder's track-change dedup
      _recording = false;
    });
    // Switching station ends any in-progress recording (spec: a station change
    // stops recording) — finalize it before we retune.
    final saved = await _recorder.onStreamStopped();
    if (session != _playSession) return; // superseded while finalizing
    if (saved != null) _snack('Saved recording: ${_baseName(saved)}');
    try {
      await _player.setUrl(station.url);
      // Don't await play(): for an endless radio stream just_audio's play()
      // Future never completes (it only resolves when playback ends/stops), so
      // awaiting it would block here forever — leaving "Connecting…" stuck and
      // the metadata reader below unreached. (The media_kit desktop backend
      // returned promptly, so this only surfaced on Android/ExoPlayer.)
      unawaited(_player.play());
    } catch (e) {
      // Playback failed: return to the stopped state instead of looking like
      // we're playing and waiting for track info. Don't start the buffer, the
      // metadata reader, or the foreground service for a station that isn't on.
      if (session != _playSession || !mounted) return;
      setState(() {
        _current = null;
        _loading = false;
        _nowPlaying = '';
        _metaStatus = MetadataStatus.idle;
        _lastHistoryTitle = '';
        _lastRecTitle = '';
        _recording = false;
      });
      _snack('Could not play ${station.name}: $e');
      unawaited(_syncPlaybackService()); // _current == null ⇒ tears it down
      return;
    }
    if (session != _playSession || !mounted) return; // superseded
    setState(() => _loading = false);
    // Start a fresh buffer (if enabled) before audio flows, then the metadata/
    // audio reader. Both are best-effort on a separate connection. The callbacks
    // are session-guarded so a stale connection can't write into current state.
    await _recorder.startBuffering();
    if (session != _playSession) return;
    _icy.start(
      station.url,
      onTitle: (title) {
        if (session != _playSession || !mounted) return;
        setState(() {
          _nowPlaying = title;
          _metaStatus = MetadataStatus.active;
        });
        _recordHistory(title);
        _handleTrackChange(title);
      },
      onAudio: _recorder.addAudio,
      onStatus: (status) {
        if (session != _playSession || !mounted) return;
        setState(() => _metaStatus = status);
      },
    );
    // Raise (or refresh) the playback foreground service for this station.
    unawaited(_syncPlaybackService());
  }

  Future<void> _setVolume(double value) async {
    setState(() => _volume = value);
    await _player.setVolume(value);
    await _prefs?.setDouble(_volumeKey, value);
  }

  Future<void> _stop() async {
    _playSession++; // invalidate any in-flight _play / metadata callbacks
    await _player.stop();
    await _icy.stop();
    final saved = await _recorder.onStreamStopped();
    setState(() {
      _current = null;
      _nowPlaying = '';
      _metaStatus = MetadataStatus.idle;
      _lastHistoryTitle = '';
      _lastRecTitle = '';
      _recording = false;
    });
    // _current is now null, so this tears the service down.
    unawaited(_syncPlaybackService());
    if (saved != null) _snack('Saved recording: ${_baseName(saved)}');
  }

  /// React to a genuine track change (the ICY reader re-emits the same title each
  /// tick, so we dedup on [_lastRecTitle]). The very first title of a session is
  /// the initial track — the buffer is already running from [_play], so we don't
  /// reset it; only a real change finalizes an armed recording and clears it.
  Future<void> _handleTrackChange(String title) async {
    if (title == _lastRecTitle) return;
    final isFirst = _lastRecTitle.isEmpty;
    _lastRecTitle = title;
    if (isFirst) {
      // Reflect the first real title in the playback notification.
      unawaited(_syncPlaybackService());
      return;
    }
    final saved = await _recorder.onTrackChanged();
    if (saved != null && mounted) {
      setState(() => _recording = false);
      _snack('Saved recording: ${_baseName(saved)}');
    } else if (saved != null) {
      _recording = false;
    }
    // Refresh the notification text for the new track / cleared recording state.
    unawaited(_syncPlaybackService());
  }

  /// Arm recording for the current song, or cancel an in-progress one.
  void _toggleRecord() {
    if (_recording) {
      _recorder.cancel();
      setState(() => _recording = false);
      unawaited(_syncPlaybackService()); // notification back to plain "playing"
      _snack('Recording cancelled.');
      return;
    }
    if (_current == null || _nowPlaying.isEmpty) {
      _snack('Wait for the track info before recording.');
      return;
    }
    _recorder.arm(_nowPlaying, _current!.name, _icy.contentType);
    setState(() => _recording = true);
    unawaited(_syncPlaybackService()); // reflect "recording" in the notification
    _snack('Recording… it saves automatically when the track changes.');
  }

  /// Keep the Android playback foreground service in sync with the current
  /// state. While a station is active the service holds the app process in the
  /// foreground so the OS won't freeze it with the screen off (keeping both
  /// playback and the recording/metadata socket loop alive), and shows a
  /// notification — with a Stop button — reflecting what's playing/recording.
  /// When nothing is active the service is torn down. No-op off Android;
  /// best-effort (a failure here never breaks playback or recording).
  Future<void> _syncPlaybackService() async {
    if (!Platform.isAndroid) return;
    try {
      final running = await FlutterForegroundTask.isRunningService;
      // Nothing playing ⇒ no service.
      if (_current == null) {
        if (running) await FlutterForegroundTask.stopService();
        return;
      }
      final title = _current!.name;
      final text = _recording
          ? 'Recording: ${_nowPlaying.isEmpty ? 'current song' : _nowPlaying}'
          : (_nowPlaying.isEmpty ? 'Playing' : _nowPlaying);
      const buttons = [NotificationButton(id: 'stop', text: 'Stop')];
      if (running) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
          notificationButtons: buttons,
        );
      } else {
        final perm = await FlutterForegroundTask.checkNotificationPermission();
        if (perm != NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
        await FlutterForegroundTask.startService(
          serviceTypes: const [ForegroundServiceTypes.mediaPlayback],
          notificationTitle: title,
          notificationText: text,
          notificationButtons: buttons,
          callback: _foregroundTaskCallback,
        );
      }
    } catch (_) {}
  }

  /// Handle data relayed from the foreground-service isolate (notification
  /// button taps). Currently just the Stop button.
  void _onForegroundData(Object data) {
    if (data == 'stop') unawaited(_stop());
  }

  String _baseName(String path) =>
      path.split(Platform.pathSeparator).last;

  /// Message shown in the now-playing box when there's no title yet — distinct
  /// per metadata state so the user can tell "still connecting" from "this
  /// station has no track info" from "the metadata connection failed".
  String _metaStatusMessage() {
    switch (_metaStatus) {
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

  /// Append a song to the play history the first time we see its title for the
  /// current session. Fires from [IcyReader.onTitle] (which re-emits the same
  /// title each metadata tick — hence the dedup). Best-effort, like metadata.
  Future<void> _recordHistory(String rawTitle) async {
    final station = _current;
    if (station == null || rawTitle.isEmpty || rawTitle == _lastHistoryTitle) {
      return;
    }
    // Logging can be turned off from the History view. Bail before updating
    // _lastHistoryTitle so re-enabling mid-song still logs the current track.
    if (!(_prefs?.getBool(_historyLoggingKey) ?? true)) return;
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
    } catch (_) {
      // History is a best-effort log — ignore write failures.
    }
  }

  Future<void> _saveCurrentTrack() async {
    if (_current == null || _nowPlaying.isEmpty) {
      _snack('Nothing playing yet — no track to save.');
      return;
    }

    // ICY only gives us "Artist - Title". Album is rarely present, so it stays
    // empty unless you later add a per-station metadata source.
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
        await file.writeAsString(
          'timestamp,station,artist,title,album,raw\n',
        );
      }
      await file.writeAsString('$row\n', mode: FileMode.append);
      _snack('Saved: ${artist.isEmpty ? title : "$artist — $title"}');
    } catch (e) {
      _snack('Save failed: $e');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// A dimmed, italic list row that reads as an action rather than a station
  /// entry (used for add / import / export at the end of the list).
  Widget _actionTile(IconData icon, String label, VoidCallback onTap) {
    final muted =
        Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.55);
    return ListTile(
      leading: Icon(icon, color: muted),
      title: Text(
        label,
        style: TextStyle(color: muted, fontStyle: FontStyle.italic),
      ),
      onTap: onTap,
    );
  }

  /// The live filter field, shown above the station list while [_searching].
  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        autofocus: true,
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: 'Filter stations…',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Clear search',
            onPressed: _closeSearch,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playing = _current != null;
    // Case-insensitive substring match on the station name.
    final visible = _query.isEmpty
        ? _stations
        : _stations
            .where((s) => s.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('EZ-TuneIn Radio'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Filter stations',
            onPressed: _openSearch,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _TrackListPage(
                  title: 'History',
                  fileResolver: historyFile,
                  emptyMessage: 'No songs played yet.',
                  shareSubject: 'EZ-TuneIn play history',
                  isHistory: true,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.favorite),
            tooltip: 'Saved tracks',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _TrackListPage(
                  title: 'Saved tracks',
                  fileResolver: savedTracksFile,
                  emptyMessage: 'No saved tracks yet.',
                  shareSubject: 'EZ-TuneIn saved tracks',
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.library_music),
            tooltip: 'Recordings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _RecordingsPage(stopRadio: _stop),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Recording settings',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      _RecordingSettingsPage(streamBitrateKbps: _icy.bitrateKbps),
                ),
              );
              await _applyRecordingPrefs(); // pick up any changes
            },
          ),
        ],
      ),
      // Esc dismisses the filter from anywhere (incl. while the field is
      // focused); the page-level Focus catches the first keystroke to open it.
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
        },
        child: Focus(
          focusNode: _pageFocus,
          autofocus: true,
          onKeyEvent: _onPageKey,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Volume
                Row(
                  children: [
                    Icon(
                      _volume == 0
                          ? Icons.volume_off
                          : (_volume < 0.5
                              ? Icons.volume_down
                              : Icons.volume_up),
                    ),
                    Expanded(
                      child: Slider(
                        value: _volume,
                        onChanged: _setVolume,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Now playing — glows with a thin red neon border while recording.
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _recording
                          ? Colors.red.shade500
                          : Colors.transparent,
                      width: 1.5,
                    ),
                    boxShadow: _recording
                        ? [
                            BoxShadow(
                              color: Colors.red.shade500.withValues(alpha: 0.6),
                              blurRadius: 16,
                              spreadRadius: 1,
                            ),
                            BoxShadow(
                              color: Colors.red.shade400.withValues(alpha: 0.3),
                              blurRadius: 32,
                              spreadRadius: 4,
                            ),
                          ]
                        : const [],
                  ),
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          Text(
                            playing ? _current!.name : 'Stopped',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _loading
                                ? 'Connecting…'
                                : (_nowPlaying.isNotEmpty
                                    ? _nowPlaying
                                    : (playing ? _metaStatusMessage() : '—')),
                            style: Theme.of(context).textTheme.headlineSmall,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (playing)
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _stop,
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop'),
                        ),
                      ),
                    // "Save title" needs a current track, like Record.
                    if (playing && _nowPlaying.isNotEmpty)
                      const SizedBox(width: 12),
                    if (playing && _nowPlaying.isNotEmpty)
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _saveCurrentTrack,
                          icon: const Icon(Icons.favorite),
                          label: const Text('Save title'),
                        ),
                      ),
                  ],
                ),
                // Record appears only while buffering is on and a track is known
                // (you can't record without a buffer to draw the song-start from).
                if (playing && _recBuffering && _nowPlaying.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: _recording
                        ? FilledButton.icon(
                            onPressed: _toggleRecord,
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.red.shade700,
                              foregroundColor: Colors.white,
                            ),
                            icon: const Icon(Icons.stop_circle),
                            label: const Text('Recording… tap to cancel'),
                          )
                        : FilledButton.tonalIcon(
                            onPressed: _toggleRecord,
                            icon: Icon(Icons.fiber_manual_record,
                                color: Colors.red.shade400),
                            label: const Text('Record this song'),
                          ),
                  ),
                ],
                const SizedBox(height: 16),
                const Divider(),
                if (_searching) _searchBar(),
                Expanded(
                  child: (_query.isNotEmpty && visible.isEmpty)
                      ? Center(
                          child: Text(
                            'No stations match “$_query”.',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        )
                      : ListView.builder(
                          // Trailing add/import/export rows only when not filtering,
                          // so a query shows just the matching stations.
                          itemCount: visible.length + (_query.isEmpty ? 3 : 0),
                          itemBuilder: (context, i) {
                            if (_query.isEmpty) {
                              switch (i - visible.length) {
                                case 0:
                                  return _actionTile(Icons.add,
                                      'Add a new radio station…', _addStation);
                                case 1:
                                  return _actionTile(
                                      Icons.file_download_outlined,
                                      'Import stations from CSV…',
                                      _importStations);
                                case 2:
                                  return _actionTile(
                                      Icons.file_upload_outlined,
                                      'Export stations to CSV…',
                                      _exportStations);
                              }
                            }
                            final s = visible[i];
                            return _StationTile(
                              station: s,
                              isCurrent: _current?.url == s.url,
                              onTap: () => _play(s),
                              onEdit: () => _editStation(s),
                              onDelete: () => _removeStation(s),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A station row that reveals a delete button only while hovered.
class _StationTile extends StatefulWidget {
  const _StationTile({
    required this.station,
    required this.isCurrent,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final Station station;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_StationTile> createState() => _StationTileState();
}

class _StationTileState extends State<_StationTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ListTile(
        leading: Icon(
          widget.isCurrent ? Icons.graphic_eq : Icons.radio,
          color: widget.isCurrent ? scheme.primary : null,
        ),
        title: Text(widget.station.name),
        selected: widget.isCurrent,
        onTap: widget.onTap,
        trailing: _hovered
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Edit station',
                    onPressed: widget.onEdit,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove station',
                    onPressed: widget.onDelete,
                  ),
                ],
              )
            : null,
      ),
    );
  }
}

/// A minimal dialog that collects a station name + stream URL. Pass [initial]
/// to pre-fill it for editing an existing station; omit it to add a new one.
class _StationDialog extends StatefulWidget {
  const _StationDialog({this.initial});

  final Station? initial;

  @override
  State<_StationDialog> createState() => _StationDialogState();
}

class _StationDialogState extends State<_StationDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _url = TextEditingController(text: widget.initial?.url ?? '');

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty || url.isEmpty) return;
    Navigator.of(context).pop(Station(name, url));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return AlertDialog(
      title: Text(editing ? 'Edit station' : 'Add station'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            textInputAction: TextInputAction.next,
          ),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'Stream URL',
              hintText: 'https://…',
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

/// Settings for the song recorder: buffering on/off, buffer size, and where
/// recordings are saved. Persists straight to shared_preferences (the player
/// re-reads them via _applyRecordingPrefs when this page is popped).
class _RecordingSettingsPage extends StatefulWidget {
  const _RecordingSettingsPage({this.streamBitrateKbps});

  /// Bitrate of the currently playing stream, if any — shown read-only because
  /// recordings keep the stream's own rate (no re-encoding).
  final int? streamBitrateKbps;

  @override
  State<_RecordingSettingsPage> createState() => _RecordingSettingsPageState();
}

class _RecordingSettingsPageState extends State<_RecordingSettingsPage> {
  SharedPreferences? _prefs;
  bool _buffering = true;
  int _bufferMb = _recBufferMbDefault;
  String? _dir; // null/empty ⇒ Downloads (desktop) / app folder (mobile)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _buffering = prefs.getBool(_recBufferingKey) ?? true;
      _bufferMb = prefs.getInt(_recBufferMbKey) ?? _recBufferMbDefault;
      _dir = prefs.getString(recDirKey);
    });
  }

  Future<void> _setBuffering(bool v) async {
    setState(() => _buffering = v);
    await _prefs?.setBool(_recBufferingKey, v);
  }

  Future<void> _setBufferMb(int mb) async {
    setState(() => _bufferMb = mb);
    await _prefs?.setInt(_recBufferMbKey, mb);
  }

  Future<void> _pickDir() async {
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose where to save recordings',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open folder picker: $e')),
        );
      }
      return;
    }
    final picked = path;
    if (picked == null) return; // cancelled
    setState(() => _dir = picked);
    await _prefs?.setString(recDirKey, picked);
  }

  Future<void> _resetDir() async {
    setState(() => _dir = null);
    await _prefs?.remove(recDirKey);
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final hasDir = _dir != null && _dir!.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Recording settings')),
      body: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          SwitchListTile(
            title: const Text('Buffer the stream'),
            subtitle: const Text(
                'Required to record. When off, the Record button is hidden.'),
            value: _buffering,
            onChanged: _setBuffering,
          ),
          const Divider(),
          ListTile(
            title: const Text('Buffer size'),
            subtitle: Text(
              '$_bufferMb MB — how far back into a song you can reach when you '
              'hit Record (≈1 min ≈ 1 MB at 128 kbps).',
              style: TextStyle(color: _buffering ? null : muted),
            ),
          ),
          Slider(
            value: _bufferMb.clamp(5, 500).toDouble(),
            min: 5,
            max: 500,
            divisions: 99,
            label: '$_bufferMb MB',
            onChanged:
                _buffering ? (v) => setState(() => _bufferMb = v.round()) : null,
            onChangeEnd: _buffering ? (v) => _setBufferMb(v.round()) : null,
          ),
          const Divider(),
          ListTile(
            title: const Text('Save recordings to'),
            subtitle: Text(
              hasDir
                  ? _dir!
                  : (isDesktop
                      ? 'Downloads folder (default)'
                      : 'App folder — share recordings from the file manager'),
            ),
            trailing: isDesktop
                ? Wrap(
                    spacing: 4,
                    children: [
                      if (hasDir)
                        TextButton(
                          onPressed: _resetDir,
                          child: const Text('Reset'),
                        ),
                      FilledButton.tonal(
                        onPressed: _pickDir,
                        child: const Text('Change…'),
                      ),
                    ],
                  )
                : null,
          ),
          if (!isDesktop)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'On Android, recordings save to the app folder; picking an '
                'arbitrary folder isn\'t supported yet.',
                style: TextStyle(color: muted, fontStyle: FontStyle.italic),
              ),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              widget.streamBitrateKbps != null
                  ? 'Recordings keep the stream\'s own bitrate '
                      '(${widget.streamBitrateKbps} kbps) — no re-encoding, so '
                      'they\'re lossless and saved instantly.'
                  : 'Recordings keep the stream\'s own bitrate — no re-encoding, '
                      'so they\'re lossless and saved instantly.',
              style: TextStyle(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Browse and play the recorded songs in the output folder — a tiny local
/// jukebox. Owns its **own** [AudioPlayer] (separate from the radio's) and stops
/// playback when the view is left. Starting a song stops the live radio first
/// (passed in as [stopRadio]) so the two never play at once. Track names come
/// from the filenames; "never stops" auto-advances and "randomize" shuffles.
class _RecordingsPage extends StatefulWidget {
  const _RecordingsPage({required this.stopRadio});

  /// Stops the live radio stream; called once before the first recording plays.
  final Future<void> Function() stopRadio;

  @override
  State<_RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<_RecordingsPage> {
  final _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration?>? _durSub;
  SharedPreferences? _prefs;

  List<File> _files = [];
  int _index = -1; // currently playing file, or -1
  double _volume = 1.0; // 0.0–1.0; shares the radio's `volume` pref
  bool _isPlaying = false;
  Duration? _duration; // length of the current file (from durationStream)
  double? _seekDragMs; // slider position while the user is dragging the seek bar
  ProcessingState? _lastState; // to act on the transition *into* completed only
  bool _neverStops = false;
  bool _randomize = false;
  bool _radioStopped = false; // stop the radio only once, on first play

  @override
  void initState() {
    super.initState();
    _init();
    // Receive notification-button taps relayed from the foreground service.
    if (Platform.isAndroid) {
      FlutterForegroundTask.addTaskDataCallback(_onForegroundData);
    }
    _stateSub = _player.playerStateStream.listen((s) {
      if (!mounted) return;
      final ps = s.processingState;
      // "Playing" is false once a track completes (the icon should read play).
      setState(() => _isPlaying = s.playing && ps != ProcessingState.completed);
      // Keep the lock-screen notification (play/pause label, etc.) in step.
      unawaited(_syncRecordingsService());
      // Local files are finite, so completed fires at the end → auto-advance.
      // Only on the *transition* into completed (it can re-emit), and deferred
      // off this callback: driving the player from inside its own event leaves
      // the next track loaded-but-parked (was the "shows next song, stuck at
      // 0:00" bug).
      if (ps == ProcessingState.completed &&
          _lastState != ProcessingState.completed &&
          _neverStops) {
        Future.delayed(Duration.zero, _advance);
      }
      _lastState = ps;
    });
    // Duration isn't reliably returned by setFilePath on the media_kit backend —
    // it arrives here instead.
    _durSub = _player.durationStream.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final files = await listRecordings();
    final vol = prefs.getDouble(_volumeKey);
    if (vol != null) await _player.setVolume(vol);
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _files = files;
      if (vol != null) _volume = vol;
      _neverStops = prefs.getBool(_recNeverStopsKey) ?? false;
      _randomize = prefs.getBool(_recRandomizeKey) ?? false;
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _durSub?.cancel();
    _player.dispose(); // stops playback when leaving the view
    // Leaving the view stops playback, so drop the foreground service too.
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(_onForegroundData);
      unawaited(FlutterForegroundTask.stopService());
    }
    super.dispose();
  }

  String _fileName(File f) => f.path.split(Platform.pathSeparator).last;

  ({String artist, String title}) _parts(File f) {
    final name = _fileName(f);
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return splitArtistTitle(base);
  }

  String _label(File f) {
    final p = _parts(f);
    return p.artist.isEmpty ? p.title : '${p.artist} — ${p.title}';
  }

  Future<void> _playAt(int i) async {
    if (i < 0 || i >= _files.length) return;
    if (!_radioStopped) {
      await widget.stopRadio(); // first play silences the live radio
      _radioStopped = true;
    }
    // Re-selecting the file that's already loaded (e.g. a one-song list under
    // "never stops", which loops back to the same index) — just restart it.
    // setFilePath on the same, already-completed source wouldn't replay.
    if (i == _index) {
      await _player.seek(Duration.zero);
      unawaited(_player.play());
      return;
    }
    try {
      final dur = await _player.setFilePath(_files[i].path);
      // Don't await play() (see the stream gotcha) — completion arrives on the
      // player-state stream, which drives "never stops".
      unawaited(_player.play());
      if (mounted) {
        setState(() {
          _index = i;
          _duration = dur;
          _seekDragMs = null;
        });
      }
      unawaited(_syncRecordingsService()); // reflect the new track in the notif
    } catch (e) {
      if (mounted) {
        setState(() {
          _index = -1;
          _duration = null;
        });
        _snack('Could not play that file: $e');
      }
    }
  }

  int _nextIndex() {
    final n = _files.length;
    if (n == 0) return -1;
    if (_randomize) {
      if (n == 1) return 0;
      var r = Random().nextInt(n);
      if (r == _index) r = (r + 1) % n; // avoid an immediate repeat
      return r;
    }
    return _index < 0 ? 0 : (_index + 1) % n;
  }

  void _advance() => _playAt(_nextIndex());
  void _skip() => _playAt(_nextIndex());

  void _togglePlayPause() {
    if (_player.playing) {
      _player.pause();
    } else {
      unawaited(_player.play());
    }
  }

  /// Stop playback entirely (the lock-screen Stop button). Clears the now-playing
  /// row, which also tears the foreground service down via [_syncRecordingsService].
  Future<void> _stopPlayback() async {
    await _player.stop();
    if (mounted) {
      setState(() {
        _index = -1;
        _duration = null;
        _seekDragMs = null;
        _isPlaying = false;
      });
    }
    unawaited(_syncRecordingsService());
  }

  /// Handle notification-button taps relayed from the foreground-service isolate.
  /// IDs are prefixed `rec_` so the radio player's handler ignores them (both
  /// pages keep a callback registered while the recordings view is on top).
  void _onForegroundData(Object data) {
    switch (data) {
      case 'rec_toggle':
        _togglePlayPause();
      case 'rec_skip':
        _skip();
      case 'rec_stop':
        unawaited(_stopPlayback());
    }
  }

  /// Keep the Android playback foreground service in step with recordings
  /// playback: while a file is loaded it shows a notification (current track,
  /// Pause/Play + Skip + Stop buttons) and holds the process in the foreground so
  /// playback survives the screen turning off; with nothing loaded it's stopped.
  /// No-op off Android; best-effort.
  Future<void> _syncRecordingsService() async {
    if (!Platform.isAndroid) return;
    try {
      final running = await FlutterForegroundTask.isRunningService;
      if (_index < 0 || _index >= _files.length) {
        if (running) await FlutterForegroundTask.stopService();
        return;
      }
      final buttons = [
        NotificationButton(id: 'rec_toggle', text: _isPlaying ? 'Pause' : 'Play'),
        const NotificationButton(id: 'rec_skip', text: 'Skip'),
        const NotificationButton(id: 'rec_stop', text: 'Stop'),
      ];
      final title = _label(_files[_index]);
      final text = _isPlaying ? 'Playing' : 'Paused';
      if (running) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
          notificationButtons: buttons,
        );
      } else {
        final perm = await FlutterForegroundTask.checkNotificationPermission();
        if (perm != NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
        await FlutterForegroundTask.startService(
          serviceTypes: const [ForegroundServiceTypes.mediaPlayback],
          notificationTitle: title,
          notificationText: text,
          notificationButtons: buttons,
          callback: _foregroundTaskCallback,
        );
      }
    } catch (_) {}
  }

  Future<void> _setNeverStops(bool v) async {
    setState(() => _neverStops = v);
    await _prefs?.setBool(_recNeverStopsKey, v);
  }

  Future<void> _setRandomize(bool v) async {
    setState(() => _randomize = v);
    await _prefs?.setBool(_recRandomizeKey, v);
  }

  Future<void> _setVolume(double v) async {
    setState(() => _volume = v);
    await _player.setVolume(v);
    await _prefs?.setDouble(_volumeKey, v); // shared with the radio player
  }

  /// Export the list as a two-column `artist,title` CSV (same file-picker flow as
  /// the station export: desktop writes the path, mobile gets the bytes).
  Future<void> _export() async {
    if (_files.isEmpty) {
      _snack('No recordings to export.');
      return;
    }
    final csv = StringBuffer('artist,title\n');
    for (final f in _files) {
      final p = _parts(f);
      csv.writeln('${csvField(p.artist)},${csvField(p.title)}');
    }
    final bytes = utf8.encode(csv.toString());
    String? path;
    try {
      path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export recordings list',
        fileName: 'ez_tunein_recordings.csv',
        type: FileType.custom,
        allowedExtensions: ['csv'],
        bytes: isDesktop ? null : bytes,
      );
    } catch (e) {
      _snack('Export failed: $e');
      return;
    }
    if (path == null) return; // cancelled
    try {
      if (isDesktop) await File(path).writeAsString(csv.toString());
      _snack('Exported ${_files.length} recording(s).');
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Permanently delete a recording (with confirmation) to free up space — the
  /// in-app way to manage files, which matters on Android where the folder isn't
  /// browsable. Stops playback first if it's the track currently playing.
  Future<void> _deleteFile(int i) async {
    if (i < 0 || i >= _files.length) return;
    final file = _files[i];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text('Permanently delete “${_label(file)}”?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final wasCurrent = i == _index;
    try {
      if (wasCurrent) await _player.stop();
      if (await file.exists()) await file.delete();
    } catch (e) {
      _snack('Could not delete: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _files.removeAt(i);
      if (wasCurrent) {
        _index = -1;
        _duration = null;
      } else if (i < _index) {
        _index -= 1; // keep pointing at the same playing file
      }
    });
    _snack('Deleted.');
  }

  /// Share a recording via the OS share sheet — lets the user move/copy it off
  /// the device (the practical "save elsewhere" on mobile).
  Future<void> _shareFile(int i) async {
    if (i < 0 || i >= _files.length) return;
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(_files[i].path)],
        subject: _label(_files[i]),
      ));
    } catch (e) {
      _snack('Share failed: $e');
    }
  }

  /// Open the recordings folder in the desktop file manager so the user can
  /// rename / delete files directly. Best-effort, desktop only.
  Future<void> _openFolder() async {
    try {
      final dir = (await recordingsDir()).path;
      if (Platform.isLinux) {
        await Process.run('xdg-open', [dir]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      }
    } catch (e) {
      _snack('Could not open the folder: $e');
    }
  }

  /// A draggable progress bar for the playing file: current position on the left,
  /// total length on the right, slide anywhere to seek. Position ticks come from
  /// the player; while dragging we show the drag value and seek on release.
  Widget _seekBar() {
    final total = _duration ?? Duration.zero;
    final maxMs = total.inMilliseconds.toDouble();
    return StreamBuilder<Duration>(
      stream: _player.positionStream,
      builder: (context, snap) {
        final posMs = (snap.data ?? Duration.zero)
            .inMilliseconds
            .clamp(0, maxMs.toInt())
            .toDouble();
        final value = _seekDragMs ?? posMs;
        return Row(
          children: [
            Text(fmtDuration(Duration(milliseconds: value.round())),
                style: Theme.of(context).textTheme.bodySmall),
            Expanded(
              // The default inactive track is the surface-variant grey, which is
              // the same as this panel's background — override it so the unplayed
              // portion is visible.
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  inactiveTrackColor:
                      Theme.of(context).colorScheme.onSurface.withValues(
                            alpha: 0.30,
                          ),
                ),
                child: Slider(
                  value: maxMs == 0 ? 0 : value.clamp(0, maxMs),
                  max: maxMs == 0 ? 1 : maxMs,
                  onChanged: maxMs == 0
                      ? null
                      : (v) => setState(() => _seekDragMs = v),
                  onChangeEnd: maxMs == 0
                      ? null
                      : (v) async {
                          await _player.seek(Duration(milliseconds: v.round()));
                          if (mounted) setState(() => _seekDragMs = null);
                        },
                ),
              ),
            ),
            Text(fmtDuration(total),
                style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      },
    );
  }

  /// A compact switch sitting right next to its label (the whole row toggles).
  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: value, onChanged: onChanged),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          if (isDesktop)
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: 'Open recordings folder',
              onPressed: _openFolder,
            ),
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Export list to CSV',
            onPressed: _files.isEmpty ? null : _export,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final volIcon = Icon(
                  _volume == 0
                      ? Icons.volume_off
                      : (_volume < 0.5 ? Icons.volume_down : Icons.volume_up),
                );
                final slider = Slider(value: _volume, onChanged: _setVolume);
                final toggles = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _toggle('Never stops', _neverStops, _setNeverStops),
                    const SizedBox(width: 16),
                    _toggle('Randomize', _randomize, _setRandomize),
                  ],
                );
                // Approx fixed width of the icon + spacing + both toggles. If the
                // slider couldn't get at least half the row, drop the toggles to
                // a second row and let the slider span the full width.
                const reserved = 320.0;
                final sliderGetsHalf =
                    constraints.maxWidth - reserved >= constraints.maxWidth / 2;
                if (sliderGetsHalf) {
                  return Row(
                    children: [
                      volIcon,
                      Expanded(child: slider),
                      const SizedBox(width: 8),
                      toggles,
                    ],
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        volIcon,
                        Expanded(child: slider),
                      ],
                    ),
                    Align(alignment: Alignment.centerRight, child: toggles),
                  ],
                );
              },
            ),
          ),
          if (_index >= 0 && _index < _files.length)
            Container(
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _label(_files[_index]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      IconButton(
                        icon:
                            Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                        tooltip: _isPlaying ? 'Pause' : 'Play',
                        onPressed: _togglePlayPause,
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next),
                        tooltip: 'Skip',
                        onPressed: _files.length > 1 ? _skip : null,
                      ),
                    ],
                  ),
                  _seekBar(),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: _files.isEmpty
                ? Center(
                    child: Text(
                      'No recordings yet — record a song first.',
                      style:
                          TextStyle(color: muted, fontStyle: FontStyle.italic),
                    ),
                  )
                : ListView.builder(
                    itemCount: _files.length,
                    itemBuilder: (context, i) {
                      final current = i == _index;
                      return ListTile(
                        leading: Icon(
                          current ? Icons.graphic_eq : Icons.music_note,
                          color: current ? scheme.primary : null,
                        ),
                        title: Text(_label(_files[i])),
                        subtitle: Text(
                          _fileName(_files[i]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted),
                        ),
                        selected: current,
                        onTap: () => _playAt(i),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'More',
                          icon: const Icon(Icons.more_vert),
                          onSelected: (v) {
                            if (v == 'delete') _deleteFile(i);
                            if (v == 'share') _shareFile(i);
                          },
                          itemBuilder: (ctx) => [
                            // Sharing files isn't supported by share_plus on
                            // desktop Linux; the folder button covers that there.
                            if (!isDesktop)
                              const PopupMenuItem(
                                value: 'share',
                                child: ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.share_outlined),
                                  title: Text('Share / move…'),
                                ),
                              ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.delete_outline),
                                title: Text('Delete'),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// One saved track. [timestamp] is kept as the raw ISO-8601 string (which sorts
/// chronologically as plain text).
class SavedTrack {
  SavedTrack(this.timestamp, this.station, this.artist, this.title);
  final String timestamp;
  final String station;
  final String artist;
  final String title;
}

/// A dark, sortable, searchable table of tracks read from a CSV file. Used for
/// both the saved-tracks list and the auto-recorded play history — they differ
/// only in which file they read and their labels. Tap a row to copy
/// "artist - title"; type (or tap the search icon) to filter by artist / title /
/// station; sort by any column; export or clear the whole file.
class _TrackListPage extends StatefulWidget {
  const _TrackListPage({
    required this.title,
    required this.fileResolver,
    required this.emptyMessage,
    required this.shareSubject,
    this.isHistory = false,
  });

  final String title;
  final Future<File> Function() fileResolver;
  final String emptyMessage;
  final String shareSubject;
  // History gets an extra control bar (entry count + a logging on/off toggle).
  final bool isHistory;

  @override
  State<_TrackListPage> createState() => _TrackListPageState();
}

class _TrackListPageState extends State<_TrackListPage> {
  List<SavedTrack> _tracks = [];
  bool _loading = true;
  int? _sortColumn;
  bool _ascending = true;

  // Type-to-search filter (same UX as the station list): matches artist, title,
  // or station, case-insensitive substring.
  String _query = '';
  bool _searching = false;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _pageFocus = FocusNode();

  // History only: whether the player is currently logging played songs.
  bool _logging = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final file = await widget.fileResolver();
    final tracks = <SavedTrack>[];
    if (await file.exists()) {
      final rows = parseCsv(await file.readAsString());
      // Row 0 is the header (timestamp,station,artist,title,album,raw); skip it.
      for (final r in rows.skip(1)) {
        if (r.length < 4) continue;
        tracks.add(SavedTrack(r[0], r[1], r[2], r[3]));
      }
    }
    var logging = true;
    if (widget.isHistory) {
      final prefs = await SharedPreferences.getInstance();
      logging = prefs.getBool(_historyLoggingKey) ?? true;
    }
    if (!mounted) return;
    setState(() {
      _tracks = tracks;
      _loading = false;
      _logging = logging;
    });
  }

  Future<void> _setLogging(bool value) async {
    setState(() => _logging = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_historyLoggingKey, value);
  }

  /// History-only band: how many songs are logged + a switch to pause/resume
  /// logging. Shown even when the list is empty so logging can be toggled first.
  Widget _historyControls(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = _tracks.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.history, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$n ${n == 1 ? 'entry' : 'entries'} logged',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
              Text(
                _logging ? 'Logging on' : 'Logging off',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              Switch(value: _logging, onChanged: _setLogging),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  /// The rows actually shown: the full list, or those matching the query on
  /// artist / title / station (case-insensitive substring).
  List<SavedTrack> get _visible {
    if (_query.isEmpty) return _tracks;
    final q = _query.toLowerCase();
    return _tracks
        .where((t) =>
            t.artist.toLowerCase().contains(q) ||
            t.title.toLowerCase().contains(q) ||
            t.station.toLowerCase().contains(q))
        .toList();
  }

  void _openSearch({String? seed}) {
    setState(() {
      _searching = true;
      if (seed != null) {
        _searchController.text = seed;
        _searchController.selection =
            TextSelection.collapsed(offset: seed.length);
        _query = seed;
      }
    });
    _searchFocus.requestFocus();
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _query = '';
      _searchController.clear();
    });
    _pageFocus.requestFocus();
  }

  KeyEventResult _onPageKey(FocusNode _, KeyEvent event) {
    if (_searching || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final ch = event.character;
    if (ch == null || ch.length != 1 || ch.codeUnitAt(0) < 0x20) {
      return KeyEventResult.ignored;
    }
    _openSearch(seed: ch);
    return KeyEventResult.handled;
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        autofocus: true,
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: 'Filter by artist, title or station…',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Clear search',
            onPressed: _closeSearch,
          ),
        ),
      ),
    );
  }

  void _onSort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumn = columnIndex;
      _ascending = ascending;
      _tracks.sort((a, b) {
        final int r;
        switch (columnIndex) {
          case 1:
            r = a.station.toLowerCase().compareTo(b.station.toLowerCase());
          case 2:
            r = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
          case 3:
            r = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          default:
            r = a.timestamp.compareTo(b.timestamp);
        }
        return ascending ? r : -r;
      });
    });
  }

  Future<void> _copy(SavedTrack t) async {
    final text = t.artist.isEmpty ? t.title : '${t.artist} - ${t.title}';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('Copied: $text')));
  }

  /// Get the CSV off the device. On mobile this hands the file to the OS share
  /// sheet (email, Quick Share, Drive, Save to Files…). On desktop the file
  /// already lives in the user's Documents folder, so instead we point them at
  /// it: copy the path and offer to open the containing folder. Always exports
  /// the whole file, not the filtered view.
  Future<void> _export() async {
    final file = await widget.fileResolver();
    if (_tracks.isEmpty || !await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Nothing to export yet.')));
      return;
    }
    if (isDesktop) {
      await Clipboard.setData(ClipboardData(text: file.path));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text('Path copied: ${file.path}'),
          action: SnackBarAction(
            label: 'Open folder',
            onPressed: () => _openContainingFolder(file),
          ),
        ));
    } else {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'text/csv')],
        subject: widget.shareSubject,
      ));
    }
  }

  /// Best-effort reveal of [file]'s folder in the desktop file manager.
  Future<void> _openContainingFolder(File file) async {
    final dir = file.parent.path;
    try {
      if (Platform.isLinux) {
        await Process.run('xdg-open', [dir]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      }
    } catch (_) {
      // Opening a file manager is a nicety; ignore failures.
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Clear all of ${widget.title.toLowerCase()}?'),
        content: const Text('This permanently deletes every entry.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final file = await widget.fileResolver();
    if (await file.exists()) {
      await file.writeAsString('timestamp,station,artist,title,album,raw\n');
    }
    if (!mounted) return;
    setState(() => _tracks = []);
  }

  /// Desktop layout: the full sortable table (a wide window can scroll if it
  /// ever needs to).
  Widget _buildDataTable(List<SavedTrack> rows) {
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          sortColumnIndex: _sortColumn,
          sortAscending: _ascending,
          showCheckboxColumn: false,
          columns: [
            DataColumn(label: const Text('When'), onSort: _onSort),
            DataColumn(label: const Text('Radio station'), onSort: _onSort),
            DataColumn(label: const Text('Artist'), onSort: _onSort),
            DataColumn(label: const Text('Title'), onSort: _onSort),
          ],
          rows: [
            for (final t in rows)
              DataRow(
                onSelectChanged: (_) => _copy(t),
                cells: [
                  DataCell(Text(fmtDateTime(t.timestamp))),
                  DataCell(Text(t.station)),
                  DataCell(Text(t.artist)),
                  DataCell(Text(t.title)),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// Phone layout: a vertical list that never scrolls horizontally. Each row
  /// stacks "Artist — Title" over a muted "station · date" line; tapping copies
  /// "artist - title" (same as a table-row tap). Sorting is via the app-bar menu.
  Widget _buildCompactList(BuildContext context, List<SavedTrack> rows) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = rows[i];
        final headline =
            t.artist.isEmpty ? t.title : '${t.artist} — ${t.title}';
        return ListTile(
          title: Text(
            headline.isEmpty ? '(untitled)' : headline,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${t.station} · ${fmtDateTime(t.timestamp)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          onTap: () => _copy(t),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      // Force the dark scheme for this screen regardless of system setting.
      data: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Filter',
              onPressed: _tracks.isEmpty ? null : _openSearch,
            ),
            // The compact phone list has no column headers, so sorting moves
            // here. (record = (columnIndex, ascending) — see _onSort.)
            if (!isDesktop)
              PopupMenuButton<(int, bool)>(
                icon: const Icon(Icons.sort),
                tooltip: 'Sort',
                enabled: _tracks.isNotEmpty,
                onSelected: (c) => _onSort(c.$1, c.$2),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: (0, false), child: Text('Newest first')),
                  PopupMenuItem(value: (0, true), child: Text('Oldest first')),
                  PopupMenuItem(value: (2, true), child: Text('Artist A–Z')),
                  PopupMenuItem(value: (3, true), child: Text('Title A–Z')),
                  PopupMenuItem(value: (1, true), child: Text('Station A–Z')),
                ],
              ),
            IconButton(
              icon: Icon(isDesktop ? Icons.folder_open : Icons.share),
              tooltip: isDesktop ? 'Show file location' : 'Share',
              onPressed: _tracks.isEmpty ? null : _export,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear all',
              onPressed: _tracks.isEmpty ? null : _clearAll,
            ),
          ],
        ),
        // Esc dismisses the filter; the page-level Focus catches the first
        // keystroke to open it (same type-to-search UX as the station list).
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _closeSearch,
          },
          child: Focus(
            focusNode: _pageFocus,
            autofocus: true,
            onKeyEvent: _onPageKey,
            child: _buildBody(context),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        if (widget.isHistory) _historyControls(context),
        if (_searching) _searchBar(),
        Expanded(child: _buildListArea(context)),
      ],
    );
  }

  Widget _buildListArea(BuildContext context) {
    if (_tracks.isEmpty) return Center(child: Text(widget.emptyMessage));
    final visible = _visible;
    if (visible.isEmpty) {
      return Center(
        child: Text(
          'No entries match “$_query”.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }
    return isDesktop
        ? _buildDataTable(visible)
        : _buildCompactList(context, visible);
  }
}
