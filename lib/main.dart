import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop platforms have a resizable OS window to manage; mobile does not.
final _isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
const _winWidthKey = 'win_w';
const _winHeightKey = 'win_h';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Register the libmpv-based backend for desktop. On Android/iOS this is a
  // no-op — just_audio uses ExoPlayer/AVPlayer there.
  JustAudioMediaKit.ensureInitialized(
    linux: true,
    windows: true,
    macOS: true,
  );

  // On desktop, restore the saved window size before showing the window.
  if (_isDesktop) {
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
const _defaultStations = <Station>[
  Station('SomaFM — Groove Salad', 'https://ice1.somafm.com/groovesalad-128-mp3'),
  Station('SomaFM — Drone Zone', 'https://ice1.somafm.com/dronezone-128-mp3'),
  Station('SomaFM — Secret Agent', 'https://ice1.somafm.com/secretagent-128-mp3'),
  Station('SomaFM — Lush', 'https://ice1.somafm.com/lush-128-mp3'),
  // Direct relay from swissgroove.ch's listen.php M3U (relay2 is a fallback).
  Station('SwissGroove', 'http://relay1.swissgroove.ch:80'),
  // Nightride FM (synthwave) — Icecast mount, 320 kbps MP3.
  Station('Nightride FM', 'https://stream.nightride.fm/nightride.mp3'),
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

  static const _volumeKey = 'volume';
  static const _stationsKey = 'stations';

  SharedPreferences? _prefs;
  List<Station> _stations = List.of(_defaultStations);
  Station? _current;
  bool _loading = false;
  String _nowPlaying = ''; // raw "Artist - Title" string from the stream
  double _volume = 1.0; // 0.0–1.0

  @override
  void initState() {
    super.initState();
    if (_isDesktop) windowManager.addListener(this);
    _icy.onTitle = (title) {
      if (!mounted) return;
      setState(() => _nowPlaying = title);
    };
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
    });
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
    for (final r in _parseCsv(content)) {
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
      csv.writeln('${_csvField(s.name)},${_csvField(s.url)}');
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
        bytes: _isDesktop ? null : bytes,
      );
    } catch (e) {
      _snack('Export failed: $e');
      return;
    }
    if (path == null) return; // user cancelled

    try {
      if (_isDesktop) await File(path).writeAsString(csv.toString());
      _snack('Exported ${_stations.length} station(s).');
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  @override
  void dispose() {
    _resizeDebounce?.cancel();
    if (_isDesktop) windowManager.removeListener(this);
    _player.dispose();
    _icy.stop();
    super.dispose();
  }

  Future<void> _play(Station station) async {
    setState(() {
      _current = station;
      _loading = true;
      _nowPlaying = '';
    });
    try {
      await _player.setUrl(station.url);
      // Don't await play(): for an endless radio stream just_audio's play()
      // Future never completes (it only resolves when playback ends/stops), so
      // awaiting it would block here forever — leaving "Connecting…" stuck and
      // the metadata reader below unreached. (The media_kit desktop backend
      // returned promptly, so this only surfaced on Android/ExoPlayer.)
      unawaited(_player.play());
    } catch (e) {
      _snack('Could not play ${station.name}: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    // Metadata is best-effort, on a separate connection — fire-and-forget.
    _icy.start(station.url);
  }

  Future<void> _setVolume(double value) async {
    setState(() => _volume = value);
    await _player.setVolume(value);
    await _prefs?.setDouble(_volumeKey, value);
  }

  Future<void> _stop() async {
    await _player.stop();
    await _icy.stop();
    setState(() {
      _current = null;
      _nowPlaying = '';
    });
  }

  Future<void> _saveCurrentTrack() async {
    if (_current == null || _nowPlaying.isEmpty) {
      _snack('Nothing playing yet — no track to save.');
      return;
    }

    // ICY only gives us "Artist - Title". Album is rarely present, so it stays
    // empty unless you later add a per-station metadata source.
    var artist = '';
    var title = _nowPlaying;
    final sep = _nowPlaying.indexOf(' - ');
    if (sep > 0) {
      artist = _nowPlaying.substring(0, sep).trim();
      title = _nowPlaying.substring(sep + 3).trim();
    }

    final row = [
      DateTime.now().toIso8601String(),
      _current!.name,
      artist,
      title,
      '', // album (not available from ICY)
      _nowPlaying, // raw, as a fallback
    ].map(_csvField).join(',');

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
    final muted = Theme.of(context)
        .colorScheme
        .onSurfaceVariant
        .withValues(alpha: 0.55);
    return ListTile(
      leading: Icon(icon, color: muted),
      title: Text(
        label,
        style: TextStyle(color: muted, fontStyle: FontStyle.italic),
      ),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final playing = _current != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('EZ-TuneIn Radio'),
        actions: [
          IconButton(
            icon: const Icon(Icons.queue_music),
            tooltip: 'Saved tracks',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SavedTracksPage()),
            ),
          ),
        ],
      ),
      body: Padding(
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
                      : (_volume < 0.5 ? Icons.volume_down : Icons.volume_up),
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
            // Now playing
            Card(
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
                          : (_nowPlaying.isEmpty
                              ? (playing ? 'Waiting for track info…' : '—')
                              : _nowPlaying),
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
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
                if (playing) const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saveCurrentTrack,
                    icon: const Icon(Icons.bookmark_add),
                    label: const Text('Save current track'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            Expanded(
              child: ListView.builder(
                // Three trailing action rows after the stations: add, import,
                // export.
                itemCount: _stations.length + 3,
                itemBuilder: (context, i) {
                  switch (i - _stations.length) {
                    case 0:
                      return _actionTile(
                          Icons.add, 'Add a new radio station…', _addStation);
                    case 1:
                      return _actionTile(Icons.file_download_outlined,
                          'Import stations from CSV…', _importStations);
                    case 2:
                      return _actionTile(Icons.file_upload_outlined,
                          'Export stations to CSV…', _exportStations);
                  }
                  final s = _stations[i];
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

/// The CSV file where saved tracks are appended. Shared by the player (writes)
/// and the saved-tracks view (reads / clears).
Future<File> savedTracksFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/radio_saved_tracks.csv');
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

/// A dark, sortable table of saved tracks. Tap a row to copy "artist - title".
class SavedTracksPage extends StatefulWidget {
  const SavedTracksPage({super.key});

  @override
  State<SavedTracksPage> createState() => _SavedTracksPageState();
}

class _SavedTracksPageState extends State<SavedTracksPage> {
  List<SavedTrack> _tracks = [];
  bool _loading = true;
  int? _sortColumn;
  bool _ascending = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final file = await savedTracksFile();
    final tracks = <SavedTrack>[];
    if (await file.exists()) {
      final rows = _parseCsv(await file.readAsString());
      // Row 0 is the header (timestamp,station,artist,title,album,raw); skip it.
      for (final r in rows.skip(1)) {
        if (r.length < 4) continue;
        tracks.add(SavedTrack(r[0], r[1], r[2], r[3]));
      }
    }
    if (!mounted) return;
    setState(() {
      _tracks = tracks;
      _loading = false;
    });
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

  /// Get the saved-tracks CSV off the device. On mobile this hands the file to
  /// the OS share sheet (email, Quick Share, Drive, Save to Files…). On desktop
  /// the file already lives in the user's Documents folder, so instead we point
  /// them at it: copy the path and offer to open the containing folder.
  Future<void> _export() async {
    final file = await savedTracksFile();
    if (_tracks.isEmpty || !await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
            const SnackBar(content: Text('No saved tracks to export yet.')));
      return;
    }
    if (_isDesktop) {
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
        subject: 'EZ-TuneIn saved tracks',
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
        title: const Text('Clear all saved tracks?'),
        content: const Text('This permanently deletes every saved entry.'),
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
    final file = await savedTracksFile();
    if (await file.exists()) {
      await file.writeAsString('timestamp,station,artist,title,album,raw\n');
    }
    if (!mounted) return;
    setState(() => _tracks = []);
  }

  /// Desktop layout: the full sortable table (a wide window can scroll if it
  /// ever needs to).
  Widget _buildDataTable() {
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          sortColumnIndex: _sortColumn,
          sortAscending: _ascending,
          showCheckboxColumn: false,
          columns: [
            DataColumn(label: const Text('Saved at'), onSort: _onSort),
            DataColumn(label: const Text('Radio station'), onSort: _onSort),
            DataColumn(label: const Text('Artist'), onSort: _onSort),
            DataColumn(label: const Text('Title'), onSort: _onSort),
          ],
          rows: [
            for (final t in _tracks)
              DataRow(
                onSelectChanged: (_) => _copy(t),
                cells: [
                  DataCell(Text(_fmtDateTime(t.timestamp))),
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
  Widget _buildCompactList(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      itemCount: _tracks.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = _tracks[i];
        final headline =
            t.artist.isEmpty ? t.title : '${t.artist} — ${t.title}';
        return ListTile(
          title: Text(
            headline.isEmpty ? '(untitled)' : headline,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${t.station} · ${_fmtDateTime(t.timestamp)}',
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
          title: const Text('Saved tracks'),
          actions: [
            // The compact phone list has no column headers, so sorting moves
            // here. (record = (columnIndex, ascending) — see _onSort.)
            if (!_isDesktop)
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
              icon: Icon(_isDesktop ? Icons.folder_open : Icons.share),
              tooltip: _isDesktop ? 'Show file location' : 'Share',
              onPressed: _tracks.isEmpty ? null : _export,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear all',
              onPressed: _tracks.isEmpty ? null : _clearAll,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _tracks.isEmpty
                ? const Center(child: Text('No saved tracks yet.'))
                : _isDesktop
                    ? _buildDataTable()
                    : _buildCompactList(context),
      ),
    );
  }
}

/// Formats an ISO-8601 timestamp as "YYYY-MM-DD HH:MM"; returns it unchanged
/// if it can't be parsed.
String _fmtDateTime(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

/// Minimal RFC 4180 CSV parser: handles quoted fields, escaped quotes (""),
/// and embedded commas/newlines. Returns rows of string fields.
List<List<String>> _parseCsv(String input) {
  final rows = <List<String>>[];
  var row = <String>[];
  var field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      row.add(field.toString());
      field = StringBuffer();
    } else if (c == '\n') {
      row.add(field.toString());
      field = StringBuffer();
      rows.add(row);
      row = <String>[];
    } else if (c != '\r') {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

/// Escapes a single CSV field per RFC 4180 (quote if it contains a comma,
/// quote, or newline; double any embedded quotes).
String _csvField(String value) {
  if (value.contains(RegExp(r'[",\n\r]'))) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

/// Reads ICY (Shoutcast/Icecast) inline metadata from a stream URL and reports
/// each `StreamTitle` via [onTitle].
///
/// This is intentionally independent of the audio backend: it opens its own
/// HTTP connection with the `Icy-MetaData: 1` header and parses the metadata
/// blocks the server interleaves into the audio. Because of that it behaves
/// identically on Windows, Linux, and Android — unlike just_audio's
/// icyMetadataStream, which is only populated on mobile/macOS.
///
/// Trade-off: this downloads the stream a second time (audio bytes are read and
/// discarded to reach the metadata). At ~128 kbps that is negligible.
class IcyReader {
  HttpClient? _client;
  StreamSubscription<List<int>>? _sub;

  /// Called with the raw "Artist - Title" string each time it changes.
  void Function(String title)? onTitle;

  Future<void> start(String url) async {
    await stop();
    final client = HttpClient();
    _client = client;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Icy-MetaData', '1');
      req.headers.set('User-Agent', 'radio-app');
      final resp = await req.close();

      final metaInt =
          int.tryParse(resp.headers.value('icy-metaint') ?? '') ?? 0;
      if (metaInt <= 0) {
        // Server isn't sending interleaved metadata; nothing to read.
        return;
      }
      _parseStream(resp, metaInt);
    } catch (_) {
      // Metadata is best-effort; playback continues regardless.
      await stop();
    }
  }

  void _parseStream(Stream<List<int>> stream, int metaInt) {
    // Byte-level state machine: skip `metaInt` audio bytes, read 1 length byte
    // (× 16 = metadata block size), read that many metadata bytes, repeat.
    var bytesUntilMeta = metaInt;
    var metaRemaining = 0;
    final metaBuf = <int>[];
    var inMeta = false;
    var readingLen = false;

    _sub = stream.listen(
      (chunk) {
        for (final b in chunk) {
          if (readingLen) {
            metaRemaining = b * 16;
            readingLen = false;
            if (metaRemaining == 0) {
              bytesUntilMeta = metaInt;
            } else {
              metaBuf.clear();
              inMeta = true;
            }
          } else if (inMeta) {
            metaBuf.add(b);
            metaRemaining--;
            if (metaRemaining == 0) {
              _emit(metaBuf);
              inMeta = false;
              bytesUntilMeta = metaInt;
            }
          } else {
            bytesUntilMeta--;
            if (bytesUntilMeta == 0) {
              readingLen = true;
            }
          }
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _emit(List<int> bytes) {
    // Strip the null/space padding the server appends after the fields.
    final text = utf8.decode(bytes, allowMalformed: true).replaceAll('\x00', '');
    // Prefer anchoring the end on the next field (StreamUrl=) so a title that
    // itself contains "';" isn't cut short; fall back to a plain match.
    final match = RegExp("StreamTitle='(.*?)';StreamUrl=").firstMatch(text) ??
        RegExp("StreamTitle='(.*?)';").firstMatch(text);
    final title = match?.group(1)?.trim() ?? '';
    if (title.isNotEmpty) onTitle?.call(title);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _client?.close(force: true);
    _client = null;
  }
}
