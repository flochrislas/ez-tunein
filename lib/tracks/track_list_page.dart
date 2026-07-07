import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_prefs.dart';
import '../csv_utils.dart';
import '../models/saved_track.dart';
import '../storage_paths.dart';
import '../track_utils.dart';
import '../type_to_search.dart';

/// A dark, sortable, searchable table of tracks read from a CSV file. Used for
/// both the saved-tracks list and the auto-recorded play history — they differ
/// only in which file they read and their labels. Tap a row to copy
/// "artist - title"; type (or tap the search icon) to filter by artist / title /
/// station; sort by any column; export or clear the whole file.
class TrackListPage extends StatefulWidget {
  const TrackListPage({
    super.key,
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
  State<TrackListPage> createState() => _TrackListPageState();
}

class _TrackListPageState extends State<TrackListPage>
    with TypeToSearch<TrackListPage> {
  List<SavedTrack> _tracks = [];
  bool _loading = true;
  int? _sortColumn;
  bool _ascending = true;

  // Type-to-search filter (query/searching/controllers/keystroke handling) comes
  // from the TypeToSearch mixin; it matches artist/title/station (see
  // _recomputeVisible), and onQueryChanged re-filters + resets the paging window.

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
    disposeSearch();
    super.dispose();
  }

  // Re-filter and reset the paging window whenever the query changes (mixin).
  @override
  void onQueryChanged() {
    _recomputeVisible();
    _resetWindow();
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
      _recomputeVisible();
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

  /// The rows actually shown (full list, or those matching the query on
  /// artist / title / station). Cached so build + every near-bottom scroll
  /// frame don't re-run the filter; recomputed only when the query or the
  /// track list/order changes (via [_recomputeVisible]).
  List<SavedTrack> _visible = [];

  void _recomputeVisible() {
    if (query.isEmpty) {
      _visible = _tracks;
      return;
    }
    final q = query.toLowerCase();
    _visible = _tracks
        .where((t) =>
            t.artistLower.contains(q) ||
            t.titleLower.contains(q) ||
            t.stationLower.contains(q))
        .toList();
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: searchController,
        focusNode: searchFocus,
        autofocus: true,
        onChanged: setQuery,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: 'Filter by artist, title or station…',
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

  void _onSort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumn = columnIndex;
      _ascending = ascending;
      _tracks.sort((a, b) {
        final int r;
        switch (columnIndex) {
          case 1:
            r = a.stationLower.compareTo(b.stationLower);
          case 2:
            r = a.artistLower.compareTo(b.artistLower);
          case 3:
            r = a.titleLower.compareTo(b.titleLower);
          default:
            r = a.timestamp.compareTo(b.timestamp);
        }
        return ascending ? r : -r;
      });
      _recomputeVisible();
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
    try {
      await revealInFileManager(file.parent.path);
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
    setState(() {
      _tracks = [];
      _recomputeVisible();
    });
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
              onPressed: _tracks.isEmpty ? null : openSearch,
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
            const SingleActivator(LogicalKeyboardKey.escape): closeSearch,
          },
          child: Focus(
            focusNode: pageFocus,
            autofocus: true,
            onKeyEvent: onPageKey,
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
        if (searching) _searchBar(),
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
          'No entries match “$query”.',
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
