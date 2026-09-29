import 'package:PiliPlus/services/asr/speech_padding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // in samples, as the transcriber uses it: 0.4 s padding, the VAD's
  // look-back of two 512-sample windows plus 0.25 s minimum speech
  const pad = 6400;
  const lookBack = 2 * 512 + 4000;
  SpeechPadding padding() => SpeechPadding(pad: pad, lookBack: lookBack);

  test('a whole file: full padding where there is room, clipped at the '
      'middle of a short gap, stopped at both ends of the audio', () {
    final p = padding()
      ..add(1000, 50000)
      // a gap of 4000: each side gets half
      ..add(54000, 100000)
      // a long gap: the full padding both ways
      ..add(200000, 250000);
    expect(p.ready(read: 260000, speech: false, total: 255000), [
      (start: 1000, end: 50000, from: 0, to: 52000),
      (start: 54000, end: 100000, from: 52000, to: 106400),
      (start: 200000, end: 250000, from: 193600, to: 255000),
    ]);
    expect(p.isEmpty, isTrue);
  });

  test('waits until no segment can begin within twice the padding', () {
    final p = padding()..add(20000, 50000);
    // the VAD hands a segment over once a minimum silence (1 s) has passed
    expect(p.ready(read: 66000, speech: false), isEmpty);
    expect(p.firstWaiting, 20000);
    // 50000 + 2 * pad + lookBack = 67824
    expect(p.ready(read: 67584, speech: false), isEmpty);
    expect(p.ready(read: 68096, speech: false), [
      (start: 20000, end: 50000, from: 13600, to: 56400),
    ]);
    expect(p.firstWaiting, isNull);
  });

  test('after a cut at the length cap, the next segment begins at once: '
      'where it began decides, before it is over', () {
    final p = padding()..add(0, 320000);
    // speech again right away: the VAD opens the next segment at
    // read - lookBack, never before the end of the last one
    expect(p.ready(read: 322048, speech: false), isEmpty);
    p.speechStarted(326144);
    // (320000 + 321120) / 2
    expect(p.ready(read: 326144, speech: true), [
      (start: 0, end: 320000, from: 0, to: 320560),
    ]);
    // the next one, once over, starts its padding at the same middle
    p.add(321120, 400000);
    expect(p.ready(read: 500000, speech: false), [
      (start: 321120, end: 400000, from: 320560, to: 406400),
    ]);
  });

  test('a segment begun right after the last one cannot start before it '
      'ended', () {
    final p = padding()
      ..add(0, 320000)
      ..speechStarted(321000);
    expect(p.ready(read: 321000, speech: true).single.to, 320000);
  });

  test('an eager segment waits only until none can begin within one '
      'padding; the next one is not decoded over it', () {
    final p = padding()..add(20000, 50000, eager: true);
    // 50000 + pad + lookBack = 61424
    expect(p.ready(read: 61184, speech: false), isEmpty);
    expect(p.ready(read: 61696, speech: false), [
      (start: 20000, end: 50000, from: 13600, to: 56400),
    ]);
    // begun where the look-back allows, 57000: the middle of the gap
    // (53500) was already decoded with the first
    p.add(57000, 90000);
    expect(p.ready(read: 120000, speech: false), [
      (start: 57000, end: 90000, from: 56400, to: 96400),
    ]);
  });

  test('inside speech, with no start seen, it keeps waiting', () {
    final p = padding()..add(0, 30000);
    expect(p.ready(read: 90000, speech: true), isEmpty);
  });

  test('reset forgets the last run', () {
    final p = padding()
      ..add(10000, 20000)
      ..reset()
      ..add(3000, 20000);
    expect(p.ready(read: 0, speech: false, total: 21000), [
      (start: 3000, end: 20000, from: 0, to: 21000),
    ]);
  });
}
