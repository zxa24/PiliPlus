import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:material_ui/material_ui.dart';

abstract base class BaseDanmakuPainter extends CustomPainter {
  final int length;
  final double fontSize;
  final int fontWeight;
  final double strokeWidth;
  final bool running;
  final int batchThreshold;

  /// The time, in milliseconds (fractional: whole ones made the steps of a
  /// 120 Hz display 8, 8 and 9 ms).
  final double tick;

  /// LibrePili: drawn where the danmaku is, to a fraction of a pixel. With
  /// the paint's default sampling (nearest) an image at x.4 was drawn at x,
  /// so one moving 1.6 px a frame stepped 2, 1, 2, 2, 1 — the stutter seen
  /// on a 120 Hz display while every frame was drawn in time (2026-10-17).
  static final Paint _paint = Paint()..filterQuality = FilterQuality.low;
  static final Paint _nearest = Paint();

  /// Self-test: the old motion (whole milliseconds, whole pixels), the
  /// control for the trace below.
  static bool debugLegacyMotion = false;

  const BaseDanmakuPainter({
    required this.length,
    required this.fontSize,
    required this.fontWeight,
    required this.strokeWidth,
    required this.running,
    required this.tick,
    this.batchThreshold = 10, // 默认值为10，可以自行调整
  });

  static void paintImg(
    Canvas canvas,
    DanmakuItem item,
    double dx,
    double dy,
  ) {
    final img = item.image!;
    final paint = debugLegacyMotion ? _nearest : _paint;
    if (img.width == item.width.ceil()) {
      canvas.drawImage(img, Offset(dx, dy), paint);
    } else {
      final src =
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
      final dst = Rect.fromLTWH(dx, dy, item.width, item.height);
      canvas.drawImageRect(img, src, dst, paint);
    }
  }

  @override
  bool shouldRepaint(covariant BaseDanmakuPainter oldDelegate) {
    return (running && length != 0) ||
        oldDelegate.length != length ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.fontWeight != fontWeight ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
