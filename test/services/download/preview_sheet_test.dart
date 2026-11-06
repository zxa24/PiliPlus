import 'package:PiliPlus/services/download/preview_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreviewSheet.times (user 2026-11-06, 5C 6A: every 5 s at the '
      'closest, 64 frames at most)', () {
    test('a short video: one every 5 s or so, from 3% to 97%', () {
      final t = PreviewSheet.times(180);
      expect(t.first, closeTo(5.4, 0.001));
      expect(t.last, closeTo(174.6, 0.001));
      expect(t, hasLength(34));
      for (var i = 1; i < t.length; i++) {
        expect(t[i] - t[i - 1], greaterThanOrEqualTo(PreviewSheet.minGap));
      }
    });

    test('a long one: 64 frames, evenly', () {
      for (final d in [1800.0, 7200.0, 36000.0]) {
        final t = PreviewSheet.times(d);
        expect(t, hasLength(PreviewSheet.maxFrames), reason: '$d s');
        expect(t.first, closeTo(d * PreviewSheet.edge, 0.001));
        expect(t.last, closeTo(d * (1 - PreviewSheet.edge), 0.001));
      }
    });

    test('shorter than the gap: one frame, in the middle', () {
      expect(PreviewSheet.times(4), [2.0]);
    });

    test('a length not known: none', () {
      expect(PreviewSheet.times(0), isEmpty);
      expect(PreviewSheet.times(double.nan), isEmpty);
      expect(PreviewSheet.times(-3), isEmpty);
    });

    test('rising, never past the end', () {
      for (final d in [10.0, 61.0, 333.3, 5000.0]) {
        final t = PreviewSheet.times(d);
        for (var i = 1; i < t.length; i++) {
          expect(t[i], greaterThan(t[i - 1]));
        }
        expect(t.last, lessThan(d));
      }
    });
  });

  test('PreviewSheet.label', () {
    expect(PreviewSheet.label(5.9), '0:05');
    expect(PreviewSheet.label(599), '9:59');
    expect(PreviewSheet.label(3725.2), '1:02:05');
  });

  test('PreviewSheet.sheetName counts from 1', () {
    expect(PreviewSheet.sheetName('v', 0), 'v.preview.1.jpg');
    expect(PreviewSheet.sheetName('v', 3), 'v.preview.4.jpg');
  });
}
