import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../app_prefs.dart';
import '../csv_export.dart';
import '../csv_utils.dart';
import '../log.dart';
import '../models/station.dart';
import '../radio_session.dart';
import '../recordings/recordings_page.dart';
import '../settings/settings_page.dart';
import '../stations/default_stations.dart';
import '../stations/station_dialog.dart';
import '../stations/station_merge.dart';
import '../stations/station_search_page.dart';
import '../stations/station_tile.dart';
import '../storage_paths.dart';
import '../tracks/track_list_page.dart';
import '../type_to_search.dart';
import '../url_utils.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// The radio player screen. The audio/metadata/recording work lives in
/// [RadioSession]; this State owns only the UI — the station list, the
/// type-to-search filter, window handling, snackbars, and the build.
class _PlayerPageState extends State<PlayerPage>
    with WindowListener, TypeToSearch<PlayerPage> {
  // The audio session (player + ICY metadata + recorder). Rebuilds this widget
  // via _onSessionChanged; user-facing messages come back through onMessage.
  final _session = RadioSession();

  Timer? _resizeDebounce;
  SharedPreferences? _prefs;
  List<Station> _stations = List.of(defaultStations);
  // Type-to-search filter (query/searching/controllers/keystroke handling) comes
  // from the TypeToSearch mixin; matching is case-insensitive on the name.

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
    _session.onMessage = _snack;
    _session.addListener(_onSessionChanged);
    unawaited(_session.init());
    _restoreStations();
  }

  // Rebuild whenever the session's state changes.
  void _onSessionChanged() {
    if (mounted) setState(() {});
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

  Future<void> _restoreStations() async {
    final prefs = await SharedPreferences.getInstance();
    List<Station>? loaded;
    final saved = prefs.getString(stationsKey);
    if (saved != null) {
      try {
        loaded = (jsonDecode(saved) as List)
            .map((e) => Station.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        loaded = null; // corrupt — fall back to defaults
        logSwallowed('_restoreStations decode', e);
      }
    }
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      if (loaded != null) _stations = loaded;
    });
  }

  Future<void> _saveStations() async {
    await _prefs?.setString(
      stationsKey,
      jsonEncode(_stations.map((s) => s.toJson()).toList()),
    );
  }

  /// Opens the online station search (with a manual-add fallback inside) and
  /// merges whatever the user picked, with the same dedup as [_importStations].
  Future<void> _addStation() async {
    final picked = await Navigator.of(context).push<List<Station>>(
      MaterialPageRoute(
        builder: (_) => StationSearchPage(
          existingUrls: _stations.map((s) => s.url).toSet(),
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    final merged = mergeStations(_stations, picked);
    if (merged.added.isEmpty) {
      _snack('Already in your list.');
      return;
    }
    setState(() => _stations.addAll(merged.added));
    await _saveStations();
    _snack('Added ${merged.added.length} station(s).');
  }

  /// Plays a random station from the list. Avoids repeating the one already
  /// playing (unless it's the only station) so each tap actually changes it.
  void _pickRandom() {
    if (_stations.isEmpty) {
      _snack('No stations to pick from.');
      return;
    }
    var pool = _stations;
    final current = _session.current;
    if (current != null && _stations.length > 1) {
      pool = _stations.where((s) => s.url != current.url).toList();
    }
    final station = pool[Random().nextInt(pool.length)];
    _session.play(station);
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
    setState(() => _stations[i] = updated);
    // Keep the now-playing highlight/title in sync if we edited the current
    // station (playback keeps running on the old connection until re-tapped).
    if (_session.current?.url == old.url) _session.renameCurrent(updated);
    await _saveStations();
  }

  Future<void> _removeStation(Station station) async {
    if (_session.current?.url == station.url) await _session.stop();
    setState(() => _stations.removeWhere((s) => s.url == station.url));
    await _saveStations();
  }

  /// Import stations from a user-picked CSV (`name,url` per row, optional
  /// header). Merges into the current list, skipping URLs already present.
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

    final parsed = <Station>[];
    var invalid = 0; // rows dropped for a non-http(s) URL (S2)
    for (final r in parseCsv(content)) {
      if (r.length < 2) continue;
      final name = r[0].trim();
      final url = r[1].trim();
      if (name.isEmpty || url.isEmpty) continue;
      // Tolerate a header row written by our own export (or by hand).
      if (name.toLowerCase() == 'name' && url.toLowerCase() == 'url') continue;
      // Reject anything that isn't an http(s) stream URL (file://, etc.).
      if (!isValidStreamUrl(url)) {
        invalid++;
        continue;
      }
      parsed.add(Station(name, url));
    }
    // Shared dedup with the online-search path (skips URLs already present or
    // duplicated within the file).
    final merged = mergeStations(_stations, parsed);
    final toAdd = merged.added;
    final skipped = merged.skipped;
    final playlist = toAdd.where((s) => isPlaylistUrl(s.url)).length;

    if (toAdd.isEmpty) {
      final reasons = <String>[
        if (skipped > 0) '$skipped already present',
        if (invalid > 0) '$invalid skipped — not http/https',
      ];
      _snack(reasons.isNotEmpty
          ? 'Nothing to import — ${reasons.join(', ')}.'
          : 'No stations found in that file.');
      return;
    }
    setState(() => _stations.addAll(toAdd));
    await _saveStations();
    final notes = <String>[
      if (skipped > 0) '$skipped already present',
      if (invalid > 0) '$invalid skipped — not http/https',
    ];
    var msg = 'Imported ${toAdd.length} station(s)'
        '${notes.isEmpty ? '' : ' (${notes.join(', ')})'}.';
    if (playlist > 0) {
      msg += ' $playlist may be playlist links — use direct stream URLs if '
          'they don\'t play.';
    }
    _snack(msg);
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
    try {
      final outcome = await saveCsvViaPicker(
        csv: csv.toString(),
        fileName: 'ez_tunein_stations.csv',
        dialogTitle: 'Export radio stations',
      );
      if (outcome == CsvSaveOutcome.cancelled) return;
      _snack('Exported ${_stations.length} station(s).');
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  bool _closing = false; // guards onWindowClose against re-entry

  // Desktop window-close handler (WindowListener). setPreventClose(true) routes
  // the close here first. Closing while media_kit is playing races its native
  // shutdown and segfaults, so we finalize any in-progress recording via the
  // session then hard-exit, skipping the racy engine/plugin teardown. exit()
  // also covers the recordings library's separate AudioPlayer.
  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      await _session.stop(); // finalize any in-progress recording
      // exit(0) skips State.dispose, so drop the recorder's private temp dir
      // here rather than leaking it on every desktop close (S3/C6).
      await _session.shutdown();
    } catch (_) {}
    exit(0);
  }

  @override
  void dispose() {
    _resizeDebounce?.cancel();
    if (isDesktop) windowManager.removeListener(this);
    disposeSearch();
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    super.dispose();
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

  /// A prominent "surprise me" row at the top of the list — each tap tunes to a
  /// random station (distinct from the current one). Uses the accent colour so
  /// it reads as a primary action, unlike the dimmed [_actionTile] rows.
  Widget _pickRandomTile() {
    final accent = Theme.of(context).colorScheme.primary;
    return ListTile(
      leading: Icon(Icons.shuffle, color: accent),
      title: Text(
        'Pick a random station',
        style: TextStyle(color: accent, fontWeight: FontWeight.w600),
      ),
      onTap: _pickRandom,
    );
  }

  /// The live filter field, shown above the station list while [searching].
  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TextField(
        controller: searchController,
        focusNode: searchFocus,
        autofocus: true,
        onChanged: setQuery,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: 'Filter stations…',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Clear search',
            onPressed: closeSearch,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playing = _session.isPlaying;
    // Case-insensitive substring match on the station name (hoist the query's
    // toLowerCase out of the per-station closure — P11).
    final q = query.toLowerCase();
    final visible = query.isEmpty
        ? _stations
        : _stations.where((s) => s.name.toLowerCase().contains(q)).toList();
    final streamInfo = playing ? _session.streamInfoLine : null;
    final recording = _session.recording;
    final muted = _session.muted;
    final volume = _session.volume;
    return Scaffold(
      appBar: AppBar(
        // Phones are width-constrained, so drop "Radio" from the app-bar name
        // on Android; desktop keeps the full title.
        title: Text(Platform.isAndroid ? 'EZ-TuneIn' : 'EZ-TuneIn Radio'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Filter stations',
            onPressed: openSearch,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const TrackListPage(
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
                builder: (_) => const TrackListPage(
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
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RecordingsPage(stopRadio: _session.stop),
                ),
              );
              // The recordings view shares the `volume` pref; pick up a change
              // made there so the radio slider/player aren't left stale.
              await _session.reloadVolume();
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsPage(),
                ),
              );
              await _session.applyRecordingPrefs(); // pick up any changes
            },
          ),
        ],
      ),
      // Esc dismisses the filter from anywhere (incl. while the field is
      // focused); the page-level Focus catches the first keystroke to open it.
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): closeSearch,
        },
        child: Focus(
          focusNode: pageFocus,
          autofocus: true,
          onKeyEvent: onPageKey,
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
                      onPressed: _session.toggleMute,
                      tooltip: muted ? 'Unmute' : 'Mute',
                      icon: Icon(
                        muted || volume == 0
                            ? Icons.volume_off
                            : (volume < 0.5
                                ? Icons.volume_down
                                : Icons.volume_up),
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: volume,
                        onChanged: muted ? null : _session.setVolume,
                        onChangeEnd: muted ? null : _session.persistVolume,
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
                          recording ? Colors.red.shade500 : Colors.transparent,
                      width: 1.5,
                    ),
                    boxShadow: recording
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
                            playing ? _session.current!.name : 'Stopped',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _session.nowPlayingText,
                            style: Theme.of(context).textTheme.headlineSmall,
                            textAlign: TextAlign.center,
                          ),
                          if (streamInfo != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              streamInfo,
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
                          onPressed: _session.stop,
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop'),
                        ),
                      ),
                    // Mute keeps the station connected — a quick silence toggle.
                    if (playing) const SizedBox(width: 12),
                    if (playing)
                      IconButton.filledTonal(
                        onPressed: _session.toggleMute,
                        isSelected: muted,
                        tooltip: muted ? 'Unmute' : 'Mute',
                        icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
                      ),
                    // "Save title" needs a *fresh* live title (not a stale one
                    // left over after the metadata feed dropped).
                    if (playing && _session.trackInfoFresh)
                      const SizedBox(width: 12),
                    if (playing && _session.trackInfoFresh)
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _session.saveCurrentTrack,
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
                if (playing && (recording || _session.canRecord)) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: recording
                        ? FilledButton.icon(
                            onPressed: _session.toggleRecord,
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.red.shade700,
                              foregroundColor: Colors.white,
                            ),
                            icon: const Icon(Icons.stop_circle),
                            label: Text(_session.manualRecording
                                ? 'Recording… tap to save'
                                : 'Recording… tap to cancel'),
                          )
                        : FilledButton.tonalIcon(
                            onPressed: _session.toggleRecord,
                            icon: Icon(Icons.fiber_manual_record,
                                color: Colors.red.shade400),
                            label: Text(_session.trackInfoFresh
                                ? 'Record this song'
                                : 'Record'),
                          ),
                  ),
                ],
                const SizedBox(height: 16),
                const Divider(),
                if (searching) _searchBar(),
                Expanded(
                  child: (query.isNotEmpty && visible.isEmpty)
                      ? Center(
                          child: Text(
                            'No stations match “$query”.',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        )
                      : ListView.builder(
                          // A leading "Pick random" row and trailing
                          // add/import/export rows, only when not filtering, so
                          // a query shows just the matching stations.
                          itemCount: visible.length + (query.isEmpty ? 4 : 0),
                          itemBuilder: (context, i) {
                            // Leading action row (index 0 when unfiltered).
                            final lead = query.isEmpty ? 1 : 0;
                            if (query.isEmpty && i == 0) {
                              return _pickRandomTile();
                            }
                            final si = i - lead; // index into the station list
                            if (query.isEmpty) {
                              switch (si - visible.length) {
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
                            final s = visible[si];
                            return StationTile(
                              station: s,
                              isCurrent: _session.current?.url == s.url,
                              onTap: () => _session.play(s),
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
