import 'package:flutter/material.dart';

// Quick-pick colour swatches, shared by the accent picker and the per-station
// colour picker (the accent picker's RGB sliders cover everything else). Ordered
// around the hue wheel (warm → green → cyan/blue → violet → pink) then neutrals;
// where a hue would repeat, a lighter/darker variant keeps neighbours distinct.
const colorPresets = <Color>[
  Color(0xFFF44336), // red
  Color(0xFFFF7043), // coral
  Color(0xFFFF9800), // orange
  Color(0xFFFFC107), // amber
  Color(0xFFFFEB3B), // yellow
  Color(0xFFCDDC39), // lime
  Color(0xFF8BC34A), // light green
  Color(0xFF43A047), // green
  Color(0xFF1B5E20), // dark green
  Color(0xFF009688), // teal (the default accent)
  Color(0xFF00BCD4), // cyan
  Color(0xFF29B6F6), // light blue
  Color(0xFF1E88E5), // blue
  Color(0xFF0D47A1), // navy
  Color(0xFF5C6BC0), // indigo
  Color(0xFF7E57C2), // deep purple
  Color(0xFF9C27B0), // purple
  Color(0xFFE91E63), // pink
  Color(0xFF880E4F), // dark rose
  Color(0xFF795548), // brown
  Color(0xFF607D8B), // blue grey
  Color(0xFF9E9E9E), // grey
  Color(0xFFFFFFFF), // white
];

/// A round, tappable colour chip (with a check + ring when selected). Shared by
/// the accent picker and the per-station colour picker.
class AccentSwatch extends StatelessWidget {
  const AccentSwatch({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
    this.size = 34,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? Icon(Icons.check, size: size * 0.5, color: Colors.white)
            : null,
      ),
    );
  }
}
