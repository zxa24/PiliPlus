import 'package:PiliPlus/plugin/pl_player/smoothness_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// What is logged as 不流畅 or 卡住, and what is not.
void main() {
  final t0 = DateTime(2026, 10, 1, 12);
  late List<String> lines;
  late SmoothnessMonitor m;

  setUp(() {
    lines = [];
    m = SmoothnessMonitor(log: lines.add, context: () => '1920x1080 h264');
  });

  /// Second [s] of playback: the playhead one second further on unless
  /// [position] says otherwise, with mpv's running totals.
  void second(
    int s, {
    double? position,
    int decoder = 0,
    int output = 0,
    int delayed = 0,
    int mistimed = 0,
    double avsync = 0,
    bool playing = true,
    bool buffering = false,
    bool quiet = false,
  }) => m.add(
    SmoothSample(
      at: t0.add(Duration(seconds: s)),
      position: position ?? s.toDouble(),
      playing: playing,
      buffering: buffering,
      decoderDrops: decoder,
      outputDrops: output,
      delayed: delayed,
      mistimed: mistimed,
      avsync: avsync,
      quiet: quiet,
    ),
  );

  test('smooth playback logs nothing', () {
    for (var s = 0; s < 20; s++) {
      second(s);
    }
    expect(lines, isEmpty);
  });

  test('a single lost frame is not one seen', () {
    second(0);
    second(1, output: 1);
    second(2, output: 2);
    second(3, output: 3);
    expect(lines, isEmpty);
  });

  test('bad seconds in a row are one line, by layer, when they end', () {
    second(0);
    second(1, decoder: 4);
    second(2, decoder: 10, output: 3);
    second(3, decoder: 10, output: 3);
    expect(lines, hasLength(1));
    expect(lines.single, contains('不流畅 2.0 s @0s: 13 帧'));
    expect(lines.single, contains('解码丢 10 · 输出丢 3'));
    expect(lines.single, contains('1920x1080 h264'));
  });

  test('the picture out of step with the sound is a bad second too', () {
    second(0);
    second(1, avsync: 0.12);
    second(2);
    expect(lines.single, contains('声画差 120 ms'));
  });

  test('a long stretch is logged every 10 s, not once at its end', () {
    second(0);
    for (var s = 1; s <= 12; s++) {
      second(s, output: s * 3);
    }
    expect(lines, hasLength(1));
    expect(lines.single, startsWith('不流畅 10.0 s'));
  });

  test('frames lost on an open or a seek are not counted', () {
    second(0);
    second(1, decoder: 30, quiet: true);
    second(2, decoder: 30);
    expect(lines, isEmpty);
  });

  test('a new source starts its counters at 0', () {
    second(0, decoder: 500);
    second(1, decoder: 0);
    second(2, decoder: 0);
    expect(lines, isEmpty);
  });

  test('a pause or a buffering ends the stretch and counts nothing', () {
    second(0);
    second(1, output: 5);
    second(2, output: 5, playing: false);
    expect(lines, hasLength(1));
    second(3, output: 50, buffering: true);
    second(4, output: 50);
    expect(lines, hasLength(1));
  });

  test('Flutter drawing a video frame late is counted as 界面漏', () {
    second(0);
    // 30 fps: 33 ms apart; a 133 ms gap misses three
    m.addUiGaps([33, 33, 133, 33], videoFps: 30);
    second(1);
    second(2);
    expect(lines.single, contains('界面漏 3'));
    expect(lines.single, contains('最长间隔 133 ms'));
  });

  test('24 fps on a 60 Hz screen is as smooth as it gets', () {
    second(0);
    m.addUiGaps([33, 50, 33, 50, 33, 50], videoFps: 24);
    second(1);
    second(2);
    expect(lines, isEmpty);
  });

  test('a playhead that does not move, playing and not buffering', () {
    second(0, position: 960);
    second(1, position: 960);
    second(2, position: 960);
    expect(lines, isEmpty);
    second(3, position: 960);
    expect(lines.single, startsWith('卡住: 播放中、未缓冲，画面 3 s 未动 @960.0s'));
    second(4, position: 960);
    second(5, position: 961);
    expect(lines, hasLength(2));
    expect(lines.last, startsWith('卡住结束: 4s 后 位置 961.0s'));
  });

  test('paused, buffering or at the end is not stuck', () {
    for (var s = 0; s < 6; s++) {
      second(s, position: 10, playing: false);
    }
    for (var s = 6; s < 12; s++) {
      second(s, position: 10, buffering: true);
    }
    for (var s = 12; s < 18; s++) {
      m.add(
        SmoothSample(
          at: t0.add(Duration(seconds: s)),
          position: 599.5,
          playing: true,
          buffering: false,
          atEnd: true,
        ),
      );
    }
    expect(lines, isEmpty);
  });
}
