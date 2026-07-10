import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The idle-state "face" of the player: a vector car-stereo faceplate drawn
/// with [CustomPaint] so it scales crisply at any window size. Shown in the
/// now-playing card only while playback is *stopped* (a plain "Stopped" line
/// otherwise reads as an error); the display doubles as a hint to tap a
/// station. Everything is laid out in fractions of the canvas, so a horizontal
/// window resize just re-lays it out — no raster assets, no aspect glitches.
class AutoradioDisplay extends StatelessWidget {
  const AutoradioDisplay({super.key});

  // A DIN head-unit is roughly this wide-to-tall; height is clamped in the
  // LayoutBuilder so it stays a slim panel on very wide desktop windows.
  static const double _aspect = 3.8;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          // Scale with width but keep the panel a slim height either way.
          final h = (w / _aspect).clamp(84.0, 150.0);
          return Center(
            child: CustomPaint(
              size: Size(w, h),
              painter: _AutoradioPainter(accent: accent),
            ),
          );
        },
      ),
    );
  }
}

class _AutoradioPainter extends CustomPainter {
  _AutoradioPainter({required this.accent});

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;

    // --- Faceplate body: brushed-metal vertical gradient + soft edges. ---
    final body = RRect.fromRectAndRadius(rect, Radius.circular(h * 0.09));
    canvas.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF3A3F45), Color(0xFF17191C)],
        ).createShader(rect),
    );

    // Clip the controls to the faceplate so the (deliberately oversized) knobs
    // read as recessed into the bezel rather than spilling past its edges.
    canvas.save();
    canvas.clipRRect(body);
    _knob(canvas, Offset(w * 0.09, h * 0.5), h * 0.31);
    _knob(canvas, Offset(w * 0.91, h * 0.5), h * 0.31);
    _screen(canvas, w, h);
    _dial(canvas, w, h);
    canvas.restore();

    // Top highlight + bottom shade for a moulded look (over the clip).
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * 0.012
        ..color = Colors.white.withValues(alpha: 0.10),
    );
  }

  // A rotary knob: dished metal disc, inner cap, an accent pointer and a ring
  // of tick marks — the volume/tuning knobs flanking the display.
  void _knob(Canvas canvas, Offset c, double r) {
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.4),
          colors: [Color(0xFF565C63), Color(0xFF202327)],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.09
        ..color = Colors.black.withValues(alpha: 0.45),
    );
    canvas.drawCircle(c, r * 0.60, Paint()..color = const Color(0xFF141618));
    canvas.drawCircle(
      c,
      r * 0.60,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.05
        ..color = Colors.white.withValues(alpha: 0.08),
    );
    // Pointer notch (points up).
    canvas.drawLine(
      c + Offset(0, -r * 0.26),
      c + Offset(0, -r * 0.55),
      Paint()
        ..color = accent
        ..strokeWidth = r * 0.13
        ..strokeCap = StrokeCap.round,
    );
    // Surrounding tick ring.
    final tick = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = r * 0.05
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 12; i++) {
      final a = (i / 12) * 2 * math.pi;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * (r * 0.78), c + dir * (r * 0.92), tick);
    }
  }

  // The inset LCD-style screen: brand wordmark + a "tap a station" hint, with
  // an FM-STEREO badge and a blinking-looking standby dot.
  void _screen(Canvas canvas, double w, double h) {
    final r = Rect.fromLTRB(w * 0.235, h * 0.15, w * 0.765, h * 0.55);
    final rr = RRect.fromRectAndRadius(r, Radius.circular(h * 0.05));
    // Dark glass with a faint accent glow inside.
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.alphaBlend(
                accent.withValues(alpha: 0.16), const Color(0xFF0B0E12)),
            const Color(0xFF07090C),
          ],
        ).createShader(r),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * 0.01
        ..color = Colors.black.withValues(alpha: 0.6),
    );

    final cx = r.center.dx;
    _text(canvas, 'EZ·TuneIn', Offset(cx, r.top + r.height * 0.34), h * 0.17,
        accent,
        weight: FontWeight.w700, letterSpacing: h * 0.01);
    _text(canvas, 'TAP A STATION TO PLAY', Offset(cx, r.top + r.height * 0.70),
        h * 0.075, Colors.white.withValues(alpha: 0.55),
        weight: FontWeight.w500, letterSpacing: h * 0.012);

    // "FM STEREO" badge, top-left inside the screen.
    _text(
        canvas,
        'FM STEREO',
        Offset(r.left + r.width * 0.13, r.top + r.height * 0.16),
        h * 0.055,
        accent.withValues(alpha: 0.85),
        weight: FontWeight.w600);
    // Standby dot, top-right.
    canvas.drawCircle(
      Offset(r.right - r.width * 0.07, r.top + r.height * 0.16),
      h * 0.02,
      Paint()..color = accent.withValues(alpha: 0.9),
    );
  }

  // The tuning scale beneath the screen: a baseline, graded ticks, a few
  // frequency labels and a red tuner needle parked near the low end.
  void _dial(Canvas canvas, double w, double h) {
    final left = w * 0.235;
    final right = w * 0.765;
    final y = h * 0.72;
    canvas.drawLine(
      Offset(left, y),
      Offset(right, y),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..strokeWidth = h * 0.008,
    );
    const ticks = 21;
    final tick = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = h * 0.006;
    for (var i = 0; i < ticks; i++) {
      final x = left + (right - left) * (i / (ticks - 1));
      final major = i % 5 == 0;
      canvas.drawLine(
          Offset(x, y), Offset(x, y - h * (major ? 0.10 : 0.05)), tick);
    }
    // A couple of labels so it reads as an FM scale.
    final lbl = Colors.white.withValues(alpha: 0.4);
    _text(canvas, '88', Offset(left, y + h * 0.10), h * 0.055, lbl);
    _text(
        canvas, '98', Offset((left + right) / 2, y + h * 0.10), h * 0.055, lbl);
    _text(canvas, '108', Offset(right, y + h * 0.10), h * 0.055, lbl);
    // Tuner needle parked at ~91 MHz (off to the low side, "not tuned").
    final nx = left + (right - left) * 0.18;
    canvas.drawLine(
      Offset(nx, y - h * 0.14),
      Offset(nx, y + h * 0.05),
      Paint()
        ..color = const Color(0xFFE23B3B)
        ..strokeWidth = h * 0.012
        ..strokeCap = StrokeCap.round,
    );
  }

  void _text(
      Canvas canvas, String s, Offset center, double fontSize, Color color,
      {FontWeight weight = FontWeight.w600, double letterSpacing = 0}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: weight,
          letterSpacing: letterSpacing,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_AutoradioPainter old) => old.accent != accent;
}
