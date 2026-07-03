import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app_prefs.dart';
import 'audio_handler.dart';
import 'csv_utils.dart';
import 'icy_reader.dart';
import 'models/saved_track.dart';
import 'models/station.dart';
import 'settings/color_swatch.dart';
import 'stations/station_dialog.dart';
import 'stations/station_search_page.dart';
import 'stations/station_tile.dart';
import 'storage_paths.dart';
import 'stream_recorder.dart';
import 'track_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Register the libmpv-based backend for desktop. On Android/iOS this is a
  // no-op — just_audio uses ExoPlayer/AVPlayer there.
  JustAudioMediaKit.ensureInitialized(
    linux: true,
    windows: true,
    macOS: true,
  );

  // Set up the media session. On Android/iOS AudioService.init binds the native
  // MediaSession + mediaPlayback foreground service (keeps playback + the
  // recording/metadata socket alive with the screen off, and exposes lock-screen
  // / Bluetooth / car controls). On desktop we construct the same handler
  // directly — no native session — so playback and the exit(0) close path are
  // unaffected.
  if (Platform.isAndroid || Platform.isIOS) {
    audioHandler = await AudioService.init(
      builder: () => EzAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'io.github.flochrislas.eztunein.audio',
        androidNotificationChannelName: 'Playback',
        // Keep the foreground service alive when paused so a paused radio stream
        // still records in the background; ongoing must be false to satisfy
        // audio_service's assertion (ongoing ⇒ stopForegroundOnPause).
        androidStopForegroundOnPause: false,
        androidNotificationOngoing: false,
        // A monochrome small status icon (the multicolour launcher would render
        // as a white square in the status bar).
        androidNotificationIcon: 'drawable/ic_stat_media',
      ),
    );
  } else {
    audioHandler = EzAudioHandler();
  }

  // Materialise the bundled app icon to a cache file once, for a consistent
  // media-card artwork across both radio and recordings modes.
  await _prepareArtUri();

  // Restore the saved accent color before the first frame.
  final prefs = await SharedPreferences.getInstance();
  accentColor.value = Color(prefs.getInt(accentColorKey) ?? defaultAccentValue);

  // On desktop, restore the saved window size before showing the window.
  if (isDesktop) {
    await windowManager.ensureInitialized();
    final w = prefs.getDouble(winWidthKey);
    final h = prefs.getDouble(winHeightKey);
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

/// Copy the bundled launcher icon to a real file once and hand its `file://` URI
/// to the media handler as the notification/lock-screen artwork. audio_service
/// needs a loadable bitmap (file/http/content), not an `asset:` path. Best-effort
/// — if it fails the card simply shows no art.
Future<void> _prepareArtUri() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/media_art.png');
    if (!await f.exists()) {
      final data = await rootBundle.load('assets/icon/app_icon_256.png');
      await f.writeAsBytes(data.buffer.asUint8List());
    }
    audioHandler.setArtUri(f.uri);
  } catch (_) {}
}

// The list users start with on first launch; afterwards it's whatever they've
// saved (see stationsKey). Add/remove from the UI.
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
  Station('Le Mellotron (Soul / Funk / Hip-Hop) — 128kbps MP3',
      'https://listen.radioking.com/radio/477719/stream/534044'),
  Station('Funky Corner Radio — 192kbps MP3',
      'https://ais-sa2.cdnstream1.com/2447_192.mp3'),
  Station('B4B Disco Funk — 128kbps MP3',
      'https://eu10.fastcast4u.com:8120/stream?sid=1'),
  Station('Radio Meuh — 128kbps MP3',
      'http://radiomeuh.ice.infomaniak.ch/radiomeuh-128.mp3'),
  Station('Classic Rock Replay (1.FM) — 192kbps MP3',
      'http://185.33.21.112:80/crock_64a'),
  Station('Progulus Radio — 192kbps MP3',
      'https://centova.radioservers.biz/proxy/klemmer/stream'),
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
      'https://generationfm.ice.infomaniak.ch/generationfm-high.mp3'),
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
  Station('Sub.FM (Dubstep / Garage / Grime) — 192kbps MP3',
      'http://subfm.radioca.st/Sub.FM'),
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
    // Rebuilds whenever the user picks a new accent color in Settings.
    return ValueListenableBuilder<Color>(
      valueListenable: accentColor,
      builder: (context, color, _) => MaterialApp(
        title: 'EZ-TuneIn Radio',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: color,
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        home: const PlayerPage(),
      ),
    );
  }
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with WindowListener
    implements AudioModeDriver {
  final _player = AudioPlayer();
  final _icy = IcyReader();
  Timer? _resizeDebounce;

  SharedPreferences? _prefs;
  List<Station> _stations = List.of(_defaultStations);
  Station? _current;
  // True while the stream is paused from the media session/Bluetooth: audio is
  // stopped but the metadata/recording socket stays alive (non-destructive).
  bool _paused = false;
  bool _loading = false;
  String _nowPlaying = ''; // raw "Artist - Title" string from the stream
  // State of the ICY metadata side-channel; drives the now-playing message when
  // there's no title yet (connecting / unsupported / failed / waiting).
  MetadataStatus _metaStatus = MetadataStatus.idle;
  // Whether the displayed title reflects a *live* metadata feed (status active).
  // Gates Save/Record so a stale title (feed dropped after a first title) can't
  // be saved/recorded; the title itself may still be shown (as "last: …").
  bool _trackInfoFresh = false;
  // Monotonic play-session id: bumped on every _play so late async work from a
  // superseded station (a fast switch) can't update the UI / history / recording.
  int _playSession = 0;
  double _volume = 1.0; // 0.0–1.0
  bool _muted =
      false; // quick-silence while staying connected (see _toggleMute)
  // Last title written to the play history; the ICY reader re-emits the same
  // title every metadata tick, so we dedup against this to log a song once.
  String _lastHistoryTitle = '';

  // Stream recorder + UI state. The ICY reader re-emits the same title each tick,
  // so track-change handling dedups against _lastRecTitle (mirrors history).
  final _recorder = StreamRecorder();
  bool _recording = false;
  // True when the in-progress recording is user-bounded (a title-less station,
  // so there's no track change to auto-save on — the user taps again to save).
  bool _manualRecording = false;
  bool _recBuffering = true; // mirrors recBufferingKey; gates the Record button
  int _recLeadSeconds = recLeadSecondsDefault; // mirrors recLeadSecondsKey
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
    if (isDesktop) {
      windowManager.addListener(this);
      // Intercept the window close so we can quiesce audio before the engine
      // tears down — closing mid-stream otherwise races media_kit's native
      // shutdown and segfaults. See onWindowClose.
      unawaited(windowManager.setPreventClose(true));
    }
    // ICY callbacks are wired per-station in _play (with a session guard); see
    // there. Just the output-folder resolver here.
    _recorder.outputDirResolver = _resolveOutputDir;
    _restorePrefs();
  }

  // Resize fires rapidly while dragging; debounce so we persist only the
  // final size rather than hammering the prefs store on every frame.
  @override
  void onWindowResize() {
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(const Duration(milliseconds: 400), () async {
      final size = await windowManager.getSize();
      await _prefs?.setDouble(winWidthKey, size.width);
      await _prefs?.setDouble(winHeightKey, size.height);
    });
  }

  Future<void> _restorePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;

    final savedVolume = prefs.getDouble(volumeKey);
    if (savedVolume != null) await _player.setVolume(savedVolume);

    // Recording config (defaults: buffering on, 35 MB, Downloads folder). Clamp
    // to recBufferMbMax so an old saved value above the new cap is still bounded.
    final buffering = prefs.getBool(recBufferingKey) ?? true;
    final bufMb = (prefs.getInt(recBufferMbKey) ?? recBufferMbDefault)
        .clamp(5, recBufferMbMax);
    _recorder.bufferingEnabled = buffering;
    _recorder.bufferCapBytes = bufMb * 1024 * 1024;
    final leadSec = prefs.getInt(recLeadSecondsKey) ?? recLeadSecondsDefault;

    List<Station>? loadedStations;
    final savedStations = prefs.getString(stationsKey);
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
      _recLeadSeconds = leadSec;
    });
  }

  /// Folder recordings are written to (shared with the recordings library view).
  Future<Directory> _resolveOutputDir() => recordingsDir();

  /// Re-apply recording prefs after the settings view changes them, and reflect a
  /// buffering on/off switch on the live stream.
  Future<void> _applyRecordingPrefs() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final buffering = prefs.getBool(recBufferingKey) ?? true;
    final bufMb = (prefs.getInt(recBufferMbKey) ?? recBufferMbDefault)
        .clamp(5, recBufferMbMax);
    final was = _recBuffering;
    _recorder.bufferingEnabled = buffering;
    _recorder.bufferCapBytes = bufMb * 1024 * 1024;
    final leadSec = prefs.getInt(recLeadSecondsKey) ?? recLeadSecondsDefault;
    if (mounted) {
      setState(() {
        _recBuffering = buffering;
        _recLeadSeconds = leadSec;
      });
    }
    if (_current != null && buffering != was) {
      if (buffering) {
        await _recorder.startBuffering();
      } else {
        await _recorder.onStreamStopped();
        if (mounted) {
          setState(() {
            _recording = false;
            _manualRecording = false;
          });
        }
        _publishRadio(); // clear "recording" from the card
      }
      // A title-less station only streams its (second) audio connection when
      // buffering is on, so restart the reader to match the new flag.
      if (_metaStatus == MetadataStatus.unsupported) {
        _startIcy(_current!, ++_playSession);
      }
    }
  }

  Future<void> _saveStations() async {
    await _prefs?.setString(
      stationsKey,
      jsonEncode(_stations.map((s) => s.toJson()).toList()),
    );
  }

  /// Opens the online station search (with a manual-add fallback inside) and
  /// merges whatever the user picked. Uses the same non-destructive `Set.add`
  /// dedup as [_importStations], so duplicates are silently skipped.
  Future<void> _addStation() async {
    final picked = await Navigator.of(context).push<List<Station>>(
      MaterialPageRoute(
        builder: (_) => StationSearchPage(
          existingUrls: _stations.map((s) => s.url).toSet(),
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    final seen = _stations.map((s) => s.url).toSet();
    final toAdd = picked.where((s) => seen.add(s.url)).toList();
    if (toAdd.isEmpty) {
      _snack('Already in your list.');
      return;
    }
    setState(() => _stations.addAll(toAdd));
    await _saveStations();
    _snack('Added ${toAdd.length} station(s).');
  }

  Future<void> _editStation(Station old) async {
    final updated = await showDialog<Station>(
      context: context,
      builder: (_) => StationDialog(initial: old),
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

  bool _closing = false; // guards onWindowClose against re-entry

  // Desktop window-close handler (WindowListener). setPreventClose(true) routes
  // the close here first. Closing while media_kit is playing races its native
  // shutdown and segfaults (the engine also errors removing its implicit view),
  // so we finalize any in-progress recording via _stop() and then hard-exit,
  // skipping the racy engine/plugin teardown entirely. exit() also covers the
  // recordings library's separate AudioPlayer, which this State can't reach.
  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      await _stop();
    } catch (_) {}
    exit(0);
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
    audioHandler.detach(this);
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
      _paused = false;
      _loading = true;
      _nowPlaying = '';
      _trackInfoFresh = false;
      _metaStatus = MetadataStatus.connecting;
      _lastHistoryTitle =
          ''; // new session: let the first song log even if same
      _lastRecTitle = ''; // reset the recorder's track-change dedup
      _recording = false;
      _manualRecording = false;
    });
    // Drop the previous station's metadata connection up front — it's irrelevant
    // once the user switched, and this ensures even a *failed* retune (setUrl
    // throws below) doesn't leave the old reader reconnecting in the background.
    await _icy.stop();
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
        _trackInfoFresh = false;
        _metaStatus = MetadataStatus.idle;
        _lastHistoryTitle = '';
        _lastRecTitle = '';
        _recording = false;
        _manualRecording = false;
      });
      _snack('Could not play ${station.name}: $e');
      audioHandler.detach(this); // no station on ⇒ tear the session down
      return;
    }
    if (session != _playSession || !mounted) return; // superseded
    setState(() => _loading = false);
    // Start a fresh buffer (if enabled) before audio flows, then the metadata/
    // audio reader. Both are best-effort on a separate connection. The callbacks
    // are session-guarded so a stale connection can't write into current state.
    await _recorder.startBuffering();
    if (session != _playSession) return;
    _startIcy(station, session);
    // Raise (or refresh) the media session / notification for this station.
    _publishRadio();
  }

  /// Open the metadata/audio reader for [station], tagging its callbacks with
  /// [session] so a superseded connection can't write into current state. Passes
  /// the buffering flag so title-less stations only keep their (second) audio
  /// connection open when there's a buffer to feed.
  void _startIcy(Station station, int session) {
    _icy.start(
      station.url,
      bufferWithoutMetadata: _recBuffering,
      onTitle: (title) {
        if (session != _playSession || !mounted) return;
        setState(() {
          _nowPlaying = title;
          _metaStatus = MetadataStatus.active;
          _trackInfoFresh = true; // live title ⇒ Save/Record are meaningful
        });
        _recordHistory(title);
        _handleTrackChange(title);
      },
      onAudio: _recorder.addAudio,
      onStatus: (status) {
        if (session != _playSession || !mounted) return;
        setState(() {
          _metaStatus = status;
          // Only an active feed is "fresh". A drop/exhausted-reconnect (failed),
          // an unsupported station, or a reconnecting gap (connecting) means the
          // shown title is stale — don't let it be saved/recorded.
          _trackInfoFresh = status == MetadataStatus.active;
        });
      },
    );
  }

  Future<void> _setVolume(double value) async {
    // Touching the slider is an explicit volume choice, so it also unmutes.
    setState(() {
      _volume = value;
      _muted = false;
    });
    await _player.setVolume(value);
    await _prefs?.setDouble(volumeKey, value);
  }

  /// Silence the radio without disconnecting (keeps the stream + metadata alive).
  /// The slider still shows the intended [_volume]; the button reflects the mute.
  Future<void> _toggleMute() async {
    final muted = !_muted;
    setState(() => _muted = muted);
    await _player.setVolume(muted ? 0 : _volume);
  }

  Future<void> _stop() async {
    _playSession++; // invalidate any in-flight _play / metadata callbacks
    await _player.stop();
    await _icy.stop();
    final saved = await _recorder.onStreamStopped();
    // Drop mute and restore the real volume so the next station isn't silent.
    if (_muted) await _player.setVolume(_volume);
    setState(() {
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
    });
    // Nothing playing now ⇒ tear the media session down.
    audioHandler.detach(this);
    if (saved != null) _snack('Saved recording: ${_baseName(saved)}');
  }

  /// Non-destructive pause for live radio, from the media session / Bluetooth /
  /// car. Silences the speaker (stops ExoPlayer) but keeps the ICY metadata +
  /// recording socket running, so an in-progress recording is NOT interrupted and
  /// still auto-finalizes on the next track. Play (driverPlay) resumes to live.
  Future<void> _pauseRadio() async {
    if (_current == null || _paused) return;
    await _player.pause();
    setState(() => _paused = true);
    _publishRadio();
  }

  /// Resume after [_pauseRadio]: ExoPlayer restarts from the live edge. The
  /// metadata/recording socket never stopped, so nothing else needs restarting.
  Future<void> _resumeRadio() async {
    if (_current == null || !_paused) return;
    unawaited(_player.play()); // never await an endless stream (see _play)
    setState(() => _paused = false);
    _publishRadio();
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
      // Reflect the first real title in the media card.
      _publishRadio();
      return;
    }
    final saved = await _recorder.onTrackChanged();
    if (saved != null && mounted) {
      setState(() {
        _recording = false;
        _manualRecording = false;
      });
      _snack('Saved recording: ${_baseName(saved)}');
    } else if (saved != null) {
      _recording = false;
      _manualRecording = false;
    }
    // Refresh the card for the new track / cleared recording state.
    _publishRadio();
  }

  /// Whether recording can be *started* now: buffering on, a station playing,
  /// and either a fresh live title (auto mode) or a title-less station we're
  /// streaming raw (manual mode).
  bool get _canRecord =>
      _recBuffering &&
      _current != null &&
      (_trackInfoFresh || _metaStatus == MetadataStatus.unsupported);

  /// Arm recording, or finish/cancel an in-progress one.
  void _toggleRecord() {
    if (_recording) {
      if (_manualRecording) {
        // No upcoming track change to auto-save on — this tap is the save.
        unawaited(_saveManualRecording());
      } else {
        _recorder.cancel();
        setState(() => _recording = false);
        _publishRadio(); // card back to "playing"
        _snack('Recording cancelled.');
      }
      return;
    }
    if (_current == null) {
      _snack('Start a station first.');
      return;
    }
    // Title-less station ⇒ user-bounded ("manual") recording, named after the
    // station + a timestamp since there's no Artist - Title.
    final manual = !_trackInfoFresh;
    if (!manual && _nowPlaying.isEmpty) {
      _snack('Wait for the track info before recording.');
      return;
    }
    final recName = manual ? '${_current!.name} ${_recStamp()}' : _nowPlaying;
    // Cap the lead-in for manual recordings (title-less stations have no song
    // boundary, so the buffer could otherwise prepend many minutes of unrelated
    // audio). Titled recordings pass null: the buffer already starts at the song.
    int? leadInBytes;
    if (manual && _recLeadSeconds >= 0) {
      final kbps = _icy.bitrateKbps ?? 128; // fall back if the server omits it
      leadInBytes =
          kbps * 125 * _recLeadSeconds; // kbps*1000/8 bytes per second
    }
    _recorder.arm(recName, _current!.name, _icy.contentType,
        leadInBytes: leadInBytes);
    setState(() {
      _recording = true;
      _manualRecording = manual;
    });
    _publishRadio(); // reflect "recording" in the card
    _snack(manual
        ? 'Recording… tap again to save.'
        : 'Recording… it saves automatically when the track changes.');
  }

  /// Finalize a manual (title-less) recording and start a fresh buffer.
  Future<void> _saveManualRecording() async {
    final saved = await _recorder.onTrackChanged(); // finalize + fresh buffer
    if (mounted) {
      setState(() {
        _recording = false;
        _manualRecording = false;
      });
    }
    _publishRadio();
    if (saved != null) {
      _snack('Saved recording: ${_baseName(saved)}');
    } else {
      _snack('Nothing recorded yet.');
    }
  }

  /// A filename-safe `YYYY-MM-DD HH.MM` stamp for naming title-less recordings.
  String _recStamp() {
    final n = DateTime.now();
    String two(int x) => x.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)} '
        '${two(n.hour)}.${two(n.minute)}';
  }

  /// Publish the current radio state to the media session (rich notification +
  /// lock screen + Bluetooth/car). While a station is active it also holds the
  /// process in the foreground so playback + the recording/metadata socket
  /// survive the screen turning off. When nothing is active it tears the session
  /// down. No-op off mobile; best-effort (never breaks playback/recording).
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
    // driverPlay only fires while this page is the active driver, which means a
    // station is loaded (playing or paused). So the only meaningful action is
    // resuming from a pause; a full Stop detaches the session entirely (there's
    // no lingering notification to Play from — the user restarts from the app).
    if (_paused) await _resumeRadio();
  }

  @override
  Future<void> driverPause() => _pauseRadio();

  @override
  Future<void> driverStop() => _stop();

  // Live radio has no seek/skip.
  @override
  Future<void> driverSeek(Duration position) async {}

  @override
  Future<void> driverSkipNext() async {}

  String _baseName(String path) => path.split(Platform.pathSeparator).last;

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

  /// The now-playing line. Shows a live title when the feed is fresh; keeps a
  /// stale title visible across a brief reconnect; and, once reconnects are
  /// exhausted, flags it as stale rather than passing it off as current.
  String _nowPlayingText(bool playing) {
    if (_loading) return 'Connecting…';
    if (!playing) return '—';
    if (_trackInfoFresh && _nowPlaying.isNotEmpty) return _nowPlaying;
    if (_nowPlaying.isNotEmpty && _metaStatus == MetadataStatus.failed) {
      return 'Track info unavailable — last: $_nowPlaying';
    }
    // Reconnecting gap: keep the (stale) title rather than flicker the message.
    if (_nowPlaying.isNotEmpty && _metaStatus == MetadataStatus.connecting) {
      return _nowPlaying;
    }
    return _metaStatusMessage();
  }

  /// A friendly codec label from the stream's `Content-Type`, or null if it's
  /// missing/unrecognised (better to show nothing than a cryptic MIME string).
  String? _streamFormatLabel(String? contentType) {
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

  /// Small "format · bitrate" line under the title, from the ICY response
  /// headers (either may be absent). Null when neither is known.
  String? _streamInfoLine() {
    final fmt = _streamFormatLabel(_icy.contentType);
    final br = _icy.bitrateKbps;
    if (fmt == null && br == null) return null;
    if (fmt != null && br != null) return '$fmt · $br kbps';
    return fmt ?? '$br kbps';
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
        // Phones are width-constrained, so drop "Radio" from the app-bar name
        // on Android; desktop keeps the full title.
        title: Text(Platform.isAndroid ? 'EZ-TuneIn' : 'EZ-TuneIn Radio'),
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
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const _SettingsPage(),
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
                // Volume — the speaker icon toggles mute; muting greys out the
                // slider (the stream stays connected either way).
                Row(
                  children: [
                    IconButton(
                      onPressed: _toggleMute,
                      tooltip: _muted ? 'Unmute' : 'Mute',
                      icon: Icon(
                        _muted || _volume == 0
                            ? Icons.volume_off
                            : (_volume < 0.5
                                ? Icons.volume_down
                                : Icons.volume_up),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: _volume,
                        onChanged: _muted ? null : _setVolume,
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
                      color:
                          _recording ? Colors.red.shade500 : Colors.transparent,
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
                            _nowPlayingText(playing),
                            style: Theme.of(context).textTheme.headlineSmall,
                            textAlign: TextAlign.center,
                          ),
                          if (playing && _streamInfoLine() != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              _streamInfoLine()!,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
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
                    // Mute keeps the station connected — a quick silence toggle.
                    if (playing) const SizedBox(width: 12),
                    if (playing)
                      IconButton.filledTonal(
                        onPressed: _toggleMute,
                        isSelected: _muted,
                        tooltip: _muted ? 'Unmute' : 'Mute',
                        icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
                      ),
                    // "Save title" needs a *fresh* live title (not a stale one
                    // left over after the metadata feed dropped).
                    if (playing && _trackInfoFresh) const SizedBox(width: 12),
                    if (playing && _trackInfoFresh)
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _saveCurrentTrack,
                          icon: const Icon(Icons.favorite),
                          label: const Text('Save title'),
                        ),
                      ),
                  ],
                ),
                // Record needs buffering on and either a fresh title (auto mode,
                // saves on the next track change) or a title-less station we're
                // streaming raw (manual mode, tap again to save). Stays visible
                // while recording so you can finish/cancel even if the feed drops.
                if (playing && (_recording || _canRecord)) ...[
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
                            label: Text(_manualRecording
                                ? 'Recording… tap to save'
                                : 'Recording… tap to cancel'),
                          )
                        : FilledButton.tonalIcon(
                            onPressed: _toggleRecord,
                            icon: Icon(Icons.fiber_manual_record,
                                color: Colors.red.shade400),
                            label: Text(_trackInfoFresh
                                ? 'Record this song'
                                : 'Record'),
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
                            return StationTile(
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

/// Settings for the song recorder: buffering on/off, buffer size, and where
/// recordings are saved. Persists straight to shared_preferences (the player
/// re-reads them via _applyRecordingPrefs when this page is popped).
class _SettingsPage extends StatefulWidget {
  const _SettingsPage();

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  SharedPreferences? _prefs;
  bool _buffering = true;
  int _bufferMb = recBufferMbDefault;
  int _leadSeconds = recLeadSecondsDefault; // -1 ⇒ whole buffer
  String? _dir; // null/empty ⇒ Downloads (desktop) / app folder (mobile)
  Color _accent = const Color(defaultAccentValue);

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
      _buffering = prefs.getBool(recBufferingKey) ?? true;
      _bufferMb = (prefs.getInt(recBufferMbKey) ?? recBufferMbDefault)
          .clamp(5, recBufferMbMax);
      _leadSeconds = prefs.getInt(recLeadSecondsKey) ?? recLeadSecondsDefault;
      _dir = prefs.getString(recDirKey);
      _accent = accentColor.value;
    });
  }

  // Re-theme the whole app live as the user drags, without hammering prefs.
  void _previewAccent(Color c) {
    setState(() => _accent = c);
    accentColor.value = c;
  }

  // Persist the choice (on release / swatch tap).
  Future<void> _commitAccent(Color c) async {
    _previewAccent(c);
    await _prefs?.setInt(accentColorKey, c.toARGB32());
  }

  int _chan(double v) => (v * 255).round(); // Color component (0..1) → 0..255

  Future<void> _setBuffering(bool v) async {
    setState(() => _buffering = v);
    await _prefs?.setBool(recBufferingKey, v);
  }

  Future<void> _setBufferMb(int mb) async {
    setState(() => _bufferMb = mb);
    await _prefs?.setInt(recBufferMbKey, mb);
  }

  Future<void> _setLeadSeconds(int sec) async {
    setState(() => _leadSeconds = sec);
    await _prefs?.setInt(recLeadSecondsKey, sec);
  }

  /// Human label for a lead-in value (seconds; -1 = whole buffer).
  static String _leadLabel(int sec) {
    if (sec < 0) return 'Max (whole buffer)';
    if (sec == 0) return 'None';
    if (sec < 60) return '${sec}s';
    return '${sec ~/ 60} min';
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

  /// A compact reference so the user can size the buffer sensibly: how much a
  /// minute of MP3 costs at common bitrates, and what the current buffer holds.
  /// (A minute = kbps × 7500 bytes; MB here is MiB, matching the cap maths.)
  Widget _bufferGuide(Color muted) {
    String perMin(int kbps) => (kbps * 7500 / 1048576).toStringAsFixed(1);
    String mins(int kbps) =>
        (_bufferMb * 1048576 / (kbps * 7500)).round().toString();
    final style = TextStyle(color: muted, fontSize: 12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '1 min of MP3 ≈ ${perMin(128)} MB (128k) · '
            '${perMin(256)} MB (256k) · ${perMin(320)} MB (320k)',
            style: style,
          ),
          const SizedBox(height: 2),
          Text(
            '→ $_bufferMb MB rewinds ≈ ${mins(128)} / ${mins(256)} / ${mins(320)} '
            'min (128 / 256 / 320k)',
            style: style,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final hasDir = _dir != null && _dir!.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // Wait for prefs before building the controls — otherwise the slider paints
      // at the default and then visibly animates to the saved value on open.
      body: _prefs == null
          ? const Center(child: CircularProgressIndicator())
          : _buildSettings(muted, hasDir),
    );
  }

  /// One tappable accent swatch (selected one shows a check + ring).
  Widget _swatch(Color c) => AccentSwatch(
        color: c,
        selected: c.toARGB32() == _accent.toARGB32(),
        onTap: () => _commitAccent(c),
      );

  /// One R/G/B channel slider tinted with the live accent. [build] maps a new
  /// channel value (0..255) to the resulting color.
  Widget _channelSlider(String label, int value, Color Function(int) build) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 4),
      child: Row(
        children: [
          SizedBox(width: 14, child: Text(label)),
          Expanded(
            child: Slider(
              value: value.toDouble(),
              max: 255,
              onChanged: (v) => _previewAccent(build(v.round())),
              onChangeEnd: (v) => _commitAccent(build(v.round())),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text('$value', textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }

  Widget _buildSettings(Color muted, bool hasDir) {
    final r = _chan(_accent.r), g = _chan(_accent.g), b = _chan(_accent.b);
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        const ListTile(
          title: Text('Accent color'),
          subtitle: Text('Tints the sliders, switches, and buttons.'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [for (final c in colorPresets) _swatch(c)],
          ),
        ),
        // Fine control: any color. Channel builders rebuild from the other two.
        _channelSlider('R', r, (v) => Color.fromARGB(255, v, g, b)),
        _channelSlider('G', g, (v) => Color.fromARGB(255, r, v, b)),
        _channelSlider('B', b, (v) => Color.fromARGB(255, r, g, v)),
        const Divider(),
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
            'hit Record.',
            style: TextStyle(color: _buffering ? null : muted),
          ),
        ),
        Slider(
          value: _bufferMb.clamp(5, recBufferMbMax).toDouble(),
          min: 5,
          max: recBufferMbMax.toDouble(),
          divisions: recBufferMbMax - 5, // 1 MB steps
          label: '$_bufferMb MB',
          onChanged:
              _buffering ? (v) => setState(() => _bufferMb = v.round()) : null,
          onChangeEnd: _buffering ? (v) => _setBufferMb(v.round()) : null,
        ),
        _bufferGuide(muted),
        const Divider(),
        ListTile(
          title: const Text('Lead-in for stations without track names'),
          subtitle: Text(
            'Some stations broadcast no song titles. There, Record keeps the '
            'last ${_leadLabel(_leadSeconds)} before you tapped (then everything '
            'until you tap save). Stations that do send titles always capture '
            'the whole song from its start, regardless of this.',
            style: TextStyle(color: _buffering ? null : muted),
          ),
        ),
        Slider(
          value: recLeadOptions
              .indexOf(_leadSeconds)
              .clamp(0, recLeadOptions.length - 1)
              .toDouble(),
          min: 0,
          max: (recLeadOptions.length - 1).toDouble(),
          divisions: recLeadOptions.length - 1,
          label: _leadLabel(_leadSeconds),
          onChanged: _buffering
              ? (v) => setState(() => _leadSeconds = recLeadOptions[v.round()])
              : null,
          onChangeEnd: _buffering
              ? (v) => _setLeadSeconds(recLeadOptions[v.round()])
              : null,
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
            'Recordings do not re-encode the stream. They are saved directly at '
            'the same bitrate and audio format than what the radio station '
            'broadcasted.',
            style: TextStyle(color: muted),
          ),
        ),
      ],
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

class _RecordingsPageState extends State<_RecordingsPage>
    implements AudioModeDriver {
  final _player = AudioPlayer();
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<Duration>? _posSub;
  int _lastPushedSec = -1; // throttle lock-screen position pushes to ~1/sec
  SharedPreferences? _prefs;

  List<File> _files = [];
  int _index = -1; // currently playing file, or -1
  double _volume = 1.0; // 0.0–1.0; shares the radio's `volume` pref
  bool _isPlaying = false;
  Duration? _duration; // length of the current file (from durationStream)
  double?
      _seekDragMs; // slider position while the user is dragging the seek bar
  ProcessingState? _lastState; // to act on the transition *into* completed only
  bool _neverStops = false;
  bool _randomize = false;
  bool _radioStopped = false; // stop the radio only once, on first play

  @override
  void initState() {
    super.initState();
    _init();
    _stateSub = _player.playerStateStream.listen((s) {
      if (!mounted) return;
      final ps = s.processingState;
      // "Playing" is false once a track completes (the icon should read play).
      setState(() => _isPlaying = s.playing && ps != ProcessingState.completed);
      // Keep the media card (play/pause label, etc.) in step.
      _publishRecording();
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
    // Feed the lock-screen scrubber. positionStream ticks often, so push only
    // when the whole-second changes (best-effort, mobile-only).
    _posSub = _player.positionStream.listen((pos) {
      if (!(Platform.isAndroid || Platform.isIOS)) return;
      if (audioHandler.mode != PlaybackMode.recordings) return;
      final sec = pos.inSeconds;
      if (sec == _lastPushedSec) return;
      _lastPushedSec = sec;
      audioHandler.updateRecordingPosition(
        position: pos,
        buffered: _player.bufferedPosition,
        playing: _player.playing,
      );
    });
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final files = await listRecordings();
    final vol = prefs.getDouble(volumeKey);
    if (vol != null) await _player.setVolume(vol);
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _files = files;
      if (vol != null) _volume = vol;
      _neverStops = prefs.getBool(recNeverStopsKey) ?? false;
      _randomize = prefs.getBool(recRandomizeKey) ?? false;
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _durSub?.cancel();
    _posSub?.cancel();
    _player.dispose(); // stops playback when leaving the view
    // Leaving the view stops playback, so drop the media session too.
    audioHandler.detach(this);
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
      _lastPushedSec = -1; // new track ⇒ allow an immediate position push
      _publishRecording(); // reflect the new track in the card
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
  /// row, which also tears the media session down via [_publishRecording].
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
    _publishRecording();
  }

  /// Publish recordings-playback state to the media session: while a file is
  /// loaded it shows a rich notification (current track + Play/Pause + Skip +
  /// Stop + scrubber) and holds the process in the foreground so playback
  /// survives the screen turning off; with nothing loaded it tears the session
  /// down. No-op off mobile; best-effort.
  void _publishRecording() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    if (_index < 0 || _index >= _files.length) {
      audioHandler.detach(this);
      return;
    }
    audioHandler.attach(PlaybackMode.recordings, this);
    audioHandler.publishRecording(
      label: _label(_files[_index]),
      duration: _duration,
      playing: _isPlaying,
    );
  }

  // --- AudioModeDriver: transport from the media session / Bluetooth / car ---

  @override
  Future<void> driverPlay() async => unawaited(_player.play());

  @override
  Future<void> driverPause() async => _player.pause();

  @override
  Future<void> driverStop() => _stopPlayback();

  @override
  Future<void> driverSeek(Duration position) => _player.seek(position);

  @override
  Future<void> driverSkipNext() async => _skip();

  Future<void> _setNeverStops(bool v) async {
    setState(() => _neverStops = v);
    await _prefs?.setBool(recNeverStopsKey, v);
  }

  Future<void> _setRandomize(bool v) async {
    setState(() => _randomize = v);
    await _prefs?.setBool(recRandomizeKey, v);
  }

  Future<void> _setVolume(double v) async {
    setState(() => _volume = v);
    await _player.setVolume(v);
    await _prefs?.setDouble(volumeKey, v); // shared with the radio player
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
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const _SettingsPage(),
                ),
              );
              // The output folder may have changed — re-list, but only while
              // idle so we don't disturb the index of an in-progress playback.
              if (!mounted || _index >= 0) return;
              final files = await listRecordings();
              if (mounted) setState(() => _files = files);
            },
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
                        icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
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

  // Paged rendering: the whole CSV is parsed up front (cheap, text), but only a
  // window of rows is built into widgets at a time so a long history (the file is
  // unbounded) doesn't materialise thousands of DataRows on open. The window
  // grows as you scroll near the bottom (or tap "Show more"); it resets whenever
  // the filter/sort changes the ordering or membership.
  static const _pageSize = 200;
  int _visibleCount = _pageSize;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  // Grow the window when the user scrolls within ~300px of the bottom.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) _showMore();
  }

  void _showMore() {
    final total = _visible.length;
    if (_visibleCount >= total) return;
    setState(() => _visibleCount = (_visibleCount + _pageSize).clamp(0, total));
  }

  // Filter/sort changed the list — start the window over from the top.
  void _resetWindow() {
    _visibleCount = _pageSize;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  Future<void> _load() async {
    final file = await widget.fileResolver();
    final tracks = <SavedTrack>[];
    if (await file.exists()) {
      final content = await file.readAsString();
      // History is unbounded; parse a large CSV on a background isolate so the UI
      // thread stays responsive on open. Small files parse inline (no isolate
      // spin-up / string-copy overhead).
      final rows = content.length > 256 * 1024
          ? await compute(parseCsv, content)
          : parseCsv(content);
      // Row 0 is the header (timestamp,station,artist,title,album,raw); skip it.
      for (final r in rows.skip(1)) {
        if (r.length < 4) continue;
        tracks.add(SavedTrack(r[0], r[1], r[2], r[3]));
      }
    }
    var logging = true;
    if (widget.isHistory) {
      final prefs = await SharedPreferences.getInstance();
      logging = prefs.getBool(historyLoggingKey) ?? true;
    }
    if (!mounted) return;
    setState(() {
      _tracks = tracks;
      _loading = false;
      _logging = logging;
      _visibleCount = _pageSize;
    });
  }

  Future<void> _setLogging(bool value) async {
    setState(() => _logging = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(historyLoggingKey, value);
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
        onChanged: (v) => setState(() {
          _query = v;
          _resetWindow();
        }),
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
      _resetWindow();
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

  /// A "Showing X of Y — Show more" footer below a windowed list. Scrolling near
  /// the bottom already grows the window (`_onScroll`); this is the explicit
  /// fallback / progress indicator.
  Widget _moreFooter(int shown, int total) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: TextButton.icon(
          onPressed: _showMore,
          icon: const Icon(Icons.expand_more),
          label: Text('Show more  ·  $shown of $total'),
        ),
      ),
    );
  }

  /// Desktop layout: the sortable table. Only [rows] (the current window) are
  /// built into DataRows; [hasMore] adds a Show-more footer (of [total] matches).
  Widget _buildDataTable(List<SavedTrack> rows, bool hasMore, int total) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.vertical,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
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
          if (hasMore) _moreFooter(rows.length, total),
        ],
      ),
    );
  }

  /// Phone layout: a vertical list that never scrolls horizontally. Each row
  /// stacks "Artist — Title" over a muted "station · date" line; tapping copies
  /// "artist - title" (same as a table-row tap). Sorting is via the app-bar menu.
  /// Only [rows] (the current window) are built; a Show-more footer is appended
  /// when [hasMore] (of [total] matches).
  Widget _buildCompactList(
      BuildContext context, List<SavedTrack> rows, bool hasMore, int total) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      controller: _scrollController,
      itemCount: rows.length + (hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i >= rows.length) return _moreFooter(rows.length, total);
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
        colorSchemeSeed: accentColor.value,
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
    // Build only a window of rows so a long history stays cheap to render; the
    // window grows on scroll / "Show more" (see _onScroll / _showMore).
    final shown =
        _visibleCount < visible.length ? _visibleCount : visible.length;
    final windowed =
        shown == visible.length ? visible : visible.sublist(0, shown);
    final hasMore = shown < visible.length;
    return isDesktop
        ? _buildDataTable(windowed, hasMore, visible.length)
        : _buildCompactList(context, windowed, hasMore, visible.length);
  }
}
