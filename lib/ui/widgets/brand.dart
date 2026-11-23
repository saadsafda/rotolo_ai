import 'package:flutter/material.dart';

import '../theme.dart';

/// "Real Estate AI" logo: a house gable whose peak is a connected AI node.
/// Geometry is the design's 208-unit artboard (assets/branding/app_icon_tile.svg).
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 52, this.tile = true});
  final double size;

  /// false draws the mark alone (no rounded teal tile).
  final bool tile;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Real Estate AI',
        image: true,
        child: CustomPaint(size: Size.square(size), painter: _BrandPainter(tile)),
      );
}

class _BrandPainter extends CustomPainter {
  _BrandPainter(this.tile);
  final bool tile;

  static const _line = Color(0xFFDFF6F2);
  static const _link = Color(0xFF9FE3DC);
  static const _node = Color(0xFF5CC6BD);
  static const _nodeRing = Color(0xFF06201E);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 208, size.height / 208);
    if (tile) {
      final rect = const Rect.fromLTWH(0, 0, 208, 208);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(52)),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0E8077), Color(0xFF0A5E5A)],
          ).createShader(rect),
      );
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = _line;
    // House body and roofline running up to the peak node.
    canvas.drawPath(
        Path()
          ..moveTo(66, 148)
          ..lineTo(66, 103)
          ..lineTo(104, 72)
          ..lineTo(142, 103)
          ..lineTo(142, 148),
        stroke);
    canvas.drawPath(
        Path()
          ..moveTo(58, 109)
          ..lineTo(104, 72)
          ..lineTo(150, 109),
        stroke);
    // Doorway.
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(94, 120, 20, 28), const Radius.circular(3)),
        Paint()..color = _line);
    // Links to the satellite nodes.
    final link = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = _link;
    canvas.drawLine(const Offset(116, 64), const Offset(145, 58), link);
    canvas.drawLine(const Offset(92, 64), const Offset(63, 58), link);
    final dot = Paint()..color = _line;
    canvas.drawCircle(const Offset(150, 56), 7, dot);
    canvas.drawCircle(const Offset(58, 56), 7, dot);
    // AI node at the roof peak (r 15 with a 7-unit ring centred on the edge).
    canvas.drawCircle(const Offset(104, 72), 15, Paint()..color = _node);
    canvas.drawCircle(
        const Offset(104, 72),
        15,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..color = _nodeRing);
  }

  @override
  bool shouldRepaint(covariant _BrandPainter old) => old.tile != tile;
}

/// Horizontal lockup: mark + "Real Estate AI" wordmark + tagline.
class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.onDark = false, this.markSize = 56});
  final bool onDark;
  final double markSize;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final name = onDark ? Colors.white : t.tx;
    final ai = onDark ? NavColors.brandMark : t.ac;
    final tag = onDark ? NavColors.active : t.mu;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      BrandMark(size: markSize),
      const SizedBox(width: 16),
      Flexible(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'Real Estate'),
              TextSpan(text: ' AI', style: TextStyle(color: ai)),
            ]),
            style: TextStyle(fontSize: 28, height: 1.05, fontWeight: FontWeight.w600, letterSpacing: -.4, color: name),
          ),
          const SizedBox(height: 7),
          Text('DEALS · RENT · PAYMENTS',
              style: TextStyle(fontFamily: kMono, fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 1.7, color: tag)),
        ]),
      ),
    ]);
  }
}
