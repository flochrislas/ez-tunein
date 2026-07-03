import 'package:flutter/material.dart';

import '../models/station.dart';

/// A station row that reveals a delete button only while hovered.
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
