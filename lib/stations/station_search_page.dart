import 'package:flutter/material.dart';

import '../models/station.dart';
import '../radio_browser.dart';
import 'station_dialog.dart';

/// Online station search backed by the Radio Browser API. Lets the user type a
/// keyword, tick one or several results, and add them at once — pops a
/// `List<Station>` back to the caller (which merges/dedups).
/// The app-bar pencil opens the classic manual [StationDialog] and pops its
/// single result through the same path. [existingUrls] marks stations already
/// in the list as "Added" so they can't be re-picked.
class StationSearchPage extends StatefulWidget {
  const StationSearchPage({super.key, required this.existingUrls});

  final Set<String> existingUrls;

  @override
  State<StationSearchPage> createState() => _StationSearchPageState();
}

class _StationSearchPageState extends State<StationSearchPage> {
  final _query = TextEditingController();
  List<RadioBrowserStation> _results = [];
  final _selected = <String>{}; // by streamUrl
  bool _loading = false;
  bool _searched = false; // has a search run yet (to show the empty message)?
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
    });
    try {
      final results = await searchRadioBrowser(q);
      if (!mounted) return;
      setState(() {
        _results = results;
        // Drop selections no longer in the new result set.
        _selected.removeWhere((u) => !results.any((r) => r.streamUrl == u));
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "Couldn't reach the station directory. "
            'Check your connection and try again.';
      });
    }
  }

  /// The classic manual add form — pops the search page with its single result
  /// so it flows through the same merge/dedup/save path.
  Future<void> _addManually() async {
    final station = await showDialog<Station>(
      context: context,
      builder: (_) => const StationDialog(),
    );
    if (station == null || !mounted) return;
    Navigator.of(context).pop(<Station>[station]);
  }

  void _submitSelection() {
    final chosen = _results
        .where((r) => _selected.contains(r.streamUrl))
        .map((r) => Station(r.name, r.streamUrl))
        .toList();
    Navigator.of(context).pop(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add station'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Add manually',
            onPressed: _addManually,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      labelText: 'Search online (name, genre, city…)',
                      hintText: 'e.g. jazz',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loading ? null : _search,
                  child: const Text('Search'),
                ),
              ],
            ),
          ),
          Expanded(child: _resultsArea(scheme)),
          if (_selected.isNotEmpty)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: Text('Add ${_selected.length} station'
                        '${_selected.length == 1 ? '' : 's'}'),
                    onPressed: _submitSelection,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _resultsArea(ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _centeredHint(_error!, scheme, icon: Icons.wifi_off);
    }
    if (!_searched) {
      return _centeredHint(
        'Search the worldwide station directory,\n'
        'or use the pencil to add one manually.',
        scheme,
        icon: Icons.travel_explore,
      );
    }
    if (_results.isEmpty) {
      return _centeredHint(
        'No stations found — try other keywords.',
        scheme,
        icon: Icons.search_off,
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (_, i) => _resultTile(_results[i], scheme),
    );
  }

  Widget _resultTile(RadioBrowserStation r, ColorScheme scheme) {
    final already = widget.existingUrls.contains(r.streamUrl);
    final selected = _selected.contains(r.streamUrl);
    return ListTile(
      enabled: !already,
      leading: _favicon(r, scheme),
      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        already ? 'Already in your list' : r.subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: already
          ? Icon(Icons.check_circle, color: scheme.primary)
          : Checkbox(
              value: selected,
              onChanged: (_) => _toggle(r),
            ),
      onTap: already ? null : () => _toggle(r),
    );
  }

  void _toggle(RadioBrowserStation r) {
    setState(() {
      if (!_selected.add(r.streamUrl)) _selected.remove(r.streamUrl);
    });
  }

  /// The station's favicon, falling back to a radio glyph while loading or if
  /// the image is missing/broken (many stations have no usable favicon).
  Widget _favicon(RadioBrowserStation r, ColorScheme scheme) {
    final fallback = Icon(Icons.radio, color: scheme.onSurfaceVariant);
    Widget box(Widget child) => SizedBox(width: 40, height: 40, child: child);
    if (r.favicon.isEmpty) return box(fallback);
    return box(ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        r.favicon,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : fallback,
      ),
    ));
  }

  Widget _centeredHint(String text, ColorScheme scheme,
      {required IconData icon}) {
    final muted = scheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: muted.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
