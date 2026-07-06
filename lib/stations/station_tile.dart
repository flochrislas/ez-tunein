import 'package:flutter/material.dart';

import '../models/station.dart';
import '../storage_paths.dart';

/// A station row with edit/remove actions. On desktop they reveal only while
/// the row is hovered; on touch they live behind a trailing overflow menu (⋮),
/// matching the recordings list — touch never hovers, so hover-only actions
/// would be unreachable.
class StationTile extends StatefulWidget {
  const StationTile({
    super.key,
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
  State<StationTile> createState() => _StationTileState();
}

class _StationTileState extends State<StationTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Optional per-station colour tags the icon + name (genre / favourite).
    final stationColor =
        widget.station.color != null ? Color(widget.station.color!) : null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ListTile(
        leading: Icon(
          widget.isCurrent ? Icons.graphic_eq : Icons.radio,
          color: stationColor ?? (widget.isCurrent ? scheme.primary : null),
        ),
        title: Text(
          widget.station.name,
          style: stationColor != null ? TextStyle(color: stationColor) : null,
        ),
        selected: widget.isCurrent,
        onTap: widget.onTap,
        trailing: isDesktop ? _hoverActions() : _overflowMenu(),
      ),
    );
  }

  /// Desktop: edit + delete buttons, shown only while the row is hovered.
  Widget? _hoverActions() {
    if (!_hovered) return null;
    return Row(
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
    );
  }

  /// Touch: an always-visible overflow menu (touch never hovers).
  Widget _overflowMenu() {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        if (v == 'edit') widget.onEdit();
        if (v == 'remove') widget.onDelete();
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text('Edit station'),
          ),
        ),
        const PopupMenuItem(
          value: 'remove',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline),
            title: Text('Remove station'),
          ),
        ),
      ],
    );
  }
}
