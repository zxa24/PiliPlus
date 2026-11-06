import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;

/// LibrePili: preview sheets written next to a downloaded video, frames
/// from it at intervals in a grid, mainly for an AI to read (user
/// 2026-11-06: 截图预览、网格排列、主要给 AI 看). `base.preview.N.jpg`, 4x4
/// tiles each, and `base.preview.json`: each tile's sheet, row, column and
/// time, so a reader need not read the labels.
///
/// Sizes: a landscape sheet is 2048x1152 (tiles 512x288), which ChatGPT
/// (gpt-5.5 high: 2048 px and 2,500 patches of 32 px), Qwen3.8-27B
/// (65,536 to 16,777,216 pixels) and Claude 4.7 and later (2,576 px) all
/// take without scaling it down: some 2,300 to 3,100 tokens a sheet.
///
/// The frames come from the file on disk, by a player of its own with no
/// video output (measured 2026-11-06, `--preview-probe`): the video track
/// has to be asked for (with no video controller mpv leaves it off), and a
/// frame decoded into GPU memory cannot be read back (d3d11: "not
/// supported by libswscale"), so decoding copies it back (`auto-copy`).
/// An exact seek took 40-80 ms there and landed on the time asked; a seek
/// to keyframes landed a keyframe early (5 s → 0 s, 300 s → 295 s).
abstract final class PreviewSheet {
  static const jsonSuffix = '.preview.json';
  static const format = 'librepili-preview-1';

  /// The N-th sheet's file name (from 1).
  static String sheetName(String base, int index) =>
      '$base.preview.${index + 1}.jpg';

  /// At most this many frames (4 sheets), [minGap] s apart at the closest
  /// (user 2026-11-06, 5C 6A).
  static const maxFrames = 64;
  static const minGap = 5.0;

  /// Left out at each end: the black of an opening and the credits.
  static const edge = 0.03;

  static const columns = 4;
  static const rows = 4;
  static const perSheet = columns * rows;

  /// A landscape tile; a portrait video's tiles are turned.
  static const tileLong = 512;
  static const tileShort = 288;
  static const quality = 85;

  /// The times the frames are taken at, for a video [duration] s long:
  /// evenly over all of it but [edge] at each end, at least [minGap] apart,
  /// at most [maxFrames]. Nothing for a length not known.
  static List<double> times(double duration) {
    if (!(duration > 0)) return const [];
    final start = duration * edge;
    final span = duration * (1 - 2 * edge);
    final gap = math.max(minGap, span / (maxFrames - 1));
    // span / (span / 63) can come out a hair under 63
    final count = math.min(maxFrames, (span / gap + 1e-9).floor() + 1);
    if (count <= 1) return [_ms(duration / 2)];
    final step = span / (count - 1);
    return [for (var i = 0; i < count; i++) _ms(start + i * step)];
  }

  static double _ms(double t) => (t * 1000).round() / 1000;

  /// The time on a tile: `m:ss`, `h:mm:ss` from an hour.
  static String label(double seconds) {
    final s = seconds.floor();
    final h = s ~/ 3600, m = s % 3600 ~/ 60, r = s % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(r)}' : '$m:${two(r)}';
  }

  /// Writes the sheets and their index for [video] into [folder]; returns
  /// what was written, or null when the video gave no frame. [cancelled]
  /// is asked between frames; [progress] is told frames done of all.
  static Future<Map<String, Object?>?> write({
    required String video,
    required String folder,
    required String base,
    bool Function()? cancelled,
    void Function(int done, int total)? progress,
  }) async {
    final watch = Stopwatch()..start();
    final player = await Player.create(
      configuration: const PlayerConfiguration(
        vo: 'null',
        options: {
          'mute': 'yes',
          'ao': 'null',
          'aid': 'no',
          'sid': 'no',
          'vid': 'auto',
          'hwdec': 'auto-copy',
        },
      ),
    ).timeout(const Duration(seconds: 10));
    final tiles = <({double asked, double at, ui.Image image})>[];
    double? duration;
    int? width, height;
    var missed = 0;
    try {
      await player
          .open(Media(video), play: false)
          .timeout(const Duration(seconds: 15));
      for (var i = 0; i < 100; i++) {
        width = int.tryParse(player.getProperty('dwidth'));
        height = int.tryParse(player.getProperty('dheight'));
        if (player.state.duration > Duration.zero &&
            (width ?? 0) > 0 &&
            (height ?? 0) > 0) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
      duration = player.state.duration.inMilliseconds / 1000;
      if (duration <= 0 || (width ?? 0) <= 0 || (height ?? 0) <= 0) {
        return null;
      }
      final portrait = height! > width!;
      final tileW = portrait ? tileShort : tileLong;
      final tileH = portrait ? tileLong : tileShort;
      final asked = times(duration);
      for (final (i, t) in asked.indexed) {
        if (cancelled?.call() ?? false) return null;
        await player
            .command(['seek', '$t', 'absolute+exact'])
            .timeout(const Duration(seconds: 10));
        double? at;
        for (var k = 0; k < 500; k++) {
          await Future.delayed(const Duration(milliseconds: 10));
          at = double.tryParse(player.getProperty('time-pos'));
          if (player.getProperty('seeking') == 'no' &&
              at != null &&
              (at - t).abs() < 0.25) {
            break;
          }
        }
        final frame = await player.screenshot();
        if (frame == null || at == null) {
          missed++;
        } else {
          tiles.add((
            asked: t,
            at: _ms(at),
            image: await _tile(frame, tileW, tileH, label(at)),
          ));
          frame.dispose();
        }
        progress?.call(i + 1, asked.length);
      }
      if (tiles.isEmpty) return null;
      final sheets = <Map<String, Object?>>[];
      for (var s = 0; s * perSheet < tiles.length; s++) {
        final part = tiles.skip(s * perSheet).take(perSheet).toList();
        final name = sheetName(base, s);
        await _sheet(part, tileW, tileH, path.join(folder, name));
        sheets.add({
          'file': name,
          'frames': [
            for (final (j, f) in part.indexed)
              {
                't': f.at,
                'row': j ~/ columns,
                'col': j % columns,
              },
          ],
        });
      }
      await File(path.join(folder, '$base$jsonSuffix')).writeAsString(
        const JsonEncoder.withIndent(' ').convert({
          'format': format,
          'video': path.basename(video),
          'duration': _ms(duration),
          'width': width,
          'height': height,
          'tile': [tileW, tileH],
          'grid': [columns, rows],
          'sheets': sheets,
        }),
      );
      return {
        'frames': tiles.length,
        'missed': missed,
        'sheets': [for (final s in sheets) s['file']],
        'ms': watch.elapsedMilliseconds,
      };
    } finally {
      for (final t in tiles) {
        t.image.dispose();
      }
      try {
        await player.dispose().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  /// [frame] fitted into a [w]x[h] tile (black bars where it does not
  /// fill it), its time in the bottom right corner.
  static Future<ui.Image> _tile(
    ui.Image frame,
    int w,
    int h,
    String text,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawRect(
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Paint()..color = const ui.Color(0xFF000000),
      );
    final scale = math.min(w / frame.width, h / frame.height);
    final dw = frame.width * scale, dh = frame.height * scale;
    canvas.drawImageRect(
      frame,
      ui.Rect.fromLTWH(0, 0, frame.width.toDouble(), frame.height.toDouble()),
      ui.Rect.fromLTWH((w - dw) / 2, (h - dh) / 2, dw, dh),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final paragraph =
        (ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 20))
              ..pushStyle(
                ui.TextStyle(
                  color: const ui.Color(0xFFFFFFFF),
                  fontWeight: ui.FontWeight.w600,
                ),
              )
              ..addText(text))
            .build()
          ..layout(const ui.ParagraphConstraints(width: 200));
    final boxW = paragraph.maxIntrinsicWidth + 10;
    final boxH = paragraph.height + 4;
    final box = ui.Rect.fromLTWH(w - boxW - 4, h - boxH - 4, boxW, boxH);
    canvas
      ..drawRect(box, ui.Paint()..color = const ui.Color(0xB0000000))
      ..drawParagraph(paragraph, ui.Offset(box.left + 5, box.top + 2));
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(w, h);
    } finally {
      picture.dispose();
    }
  }

  /// [part]'s tiles in rows of [columns] (the last sheet only as high as
  /// its rows), as a JPEG at [file].
  static Future<void> _sheet(
    List<({double asked, double at, ui.Image image})> part,
    int tileW,
    int tileH,
    String file,
  ) async {
    final used = (part.length / columns).ceil();
    final width = columns * tileW, height = used * tileH;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawRect(
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..color = const ui.Color(0xFF000000),
      );
    for (final (j, f) in part.indexed) {
      canvas.drawImage(
        f.image,
        ui.Offset(
          (j % columns * tileW).toDouble(),
          (j ~/ columns * tileH).toDouble(),
        ),
        ui.Paint(),
      );
    }
    final picture = recorder.endRecording();
    final ui.Image sheet;
    try {
      sheet = await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
    final rgba = await sheet.toByteData();
    sheet.dispose();
    if (rgba == null) throw StateError('no pixels for $file');
    final bytes = rgba.buffer.asUint8List();
    // the encoder in Dart: off the UI isolate
    final jpeg = await Isolate.run(
      () => img.encodeJpg(
        img.Image.fromBytes(
          width: width,
          height: height,
          bytes: bytes.buffer,
          numChannels: 4,
        ),
        quality: quality,
      ),
    );
    final out = File('$file.part');
    await out.writeAsBytes(jpeg, flush: true);
    await out.rename(file);
  }
}
