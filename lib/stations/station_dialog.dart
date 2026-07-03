import 'package:flutter/material.dart';

import '../models/station.dart';
import '../settings/color_swatch.dart';

/// A minimal dialog that collects a station name + stream URL. Pass [initial]
/// to pre-fill it for editing an existing station; omit it to add a new one.
class StationDialog extends StatefulWidget {
  const StationDialog({super.key, this.initial});

  final Station? initial;

  @override
  State<StationDialog> createState() => _StationDialogState();
}

class _StationDialogState extends State<StationDialog> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _url = TextEditingController(text: widget.initial?.url ?? '');
  late Color? _color = widget.initial?.color != null
      ? Color(widget.initial!.color!)
      : null; // null ⇒ default theme colour

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
    Navigator.of(context).pop(Station(name, url, color: _color?.toARGB32()));
  }

  /// The "no custom colour" choice — an outlined chip, selected when [_color] is
  /// null, so the station shows in the normal theme colour.
  Widget _defaultChoice() {
    final scheme = Theme.of(context).colorScheme;
    final selected = _color == null;
    return Tooltip(
      message: 'Default colour',
      child: InkWell(
        onTap: () => setState(() => _color = null),
        customBorder: const CircleBorder(),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Colors.white : Colors.white24,
              width: selected ? 3 : 1,
            ),
          ),
          child: Icon(Icons.format_color_reset,
              size: 16, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return AlertDialog(
      title: Text(editing ? 'Edit station' : 'Add station'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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
            const SizedBox(height: 20),
            Text('Colour (tag by genre, favourite…)',
                style: TextStyle(color: muted, fontSize: 13)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _defaultChoice(),
                for (final c in colorPresets)
                  AccentSwatch(
                    color: c,
                    selected: _color?.toARGB32() == c.toARGB32(),
                    onTap: () => setState(() => _color = c),
                    size: 30,
                  ),
              ],
            ),
          ],
        ),
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
