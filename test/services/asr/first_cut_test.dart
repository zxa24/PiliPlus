import 'package:PiliPlus/services/asr/first_cut.dart';
import 'package:PiliPlus/services/asr/speech_padding.dart';
import 'package:flutter_test/flutter_test.dart';

/// A VAD whose cuts and state the test sets.
class _Vad implements VadCuts {
  final cuts = <VadCut>[];
  @override
  bool detected = false;
  var taken = 0;

  @override
  List<VadCut> take() {
    taken++;
    final out = [...cuts];
    cuts.clear();
    return out;
  }
}

void main() {
  // in samples: 0.4 s padding, look-back of two 512-sample windows plus
  // 0.25 s minimum speech (as the transcriber)
  const pad = 6400;
  const lookBack = 2 * 512 + 4000;

  late SpeechPadding padding;
  late FirstCut cut;
  late _Vad quick;
  late _Vad steady;
  final out = <PaddedSpan>[];

  void at(int read, {int? total}) {
    cut.update(quick: quick, steady: steady, read: read);
    out.addAll(
      padding.ready(read: read, speech: cut.speech, total: total),
    );
  }

  setUp(() {
    padding = SpeechPadding(pad: pad, lookBack: lookBack);
    cut = FirstCut(padding);
    quick = _Vad();
    steady = _Vad();
    out.clear();
  });

  test('the quick VAD cuts the first segment; the steady one, cutting the '
      'same speech after its longer silence, is not reported twice', () {
    quick.detected = steady.detected = true;
    at(10000);
    expect(cut.speech, isTrue);
    // half a second of silence after 40000: the quick one cuts
    quick
      ..detected = false
      ..cuts.add((start: 5000, end: 40000));
    at(48000);
    expect(cut.quickWanted, isTrue);
    expect(cut.flushQuick, isFalse);
    expect(cut.speech, isFalse);
    // eager: handed out once nothing can begin within one padding
    // (40000 + 6400 + lookBack = 51424), not two
    at(51200);
    expect(out, isEmpty);
    at(51712);
    expect(out, [(start: 5000, end: 40000, from: 0, to: 46400)]);
    // the steady one finds its full second and cuts the same speech
    steady
      ..detected = false
      ..cuts.add((start: 5000, end: 40000));
    at(56000);
    expect(cut.quickWanted, isFalse);
    // later segments are the steady VAD's own
    steady.detected = true;
    at(80000);
    expect(padding.speechFrom, 80000 - lookBack);
    steady
      ..detected = false
      ..cuts.add((start: 80000 - lookBack, end: 120000));
    at(140000, total: 140000);
    expect(out.map((s) => (s.start, s.end)), [
      (5000, 40000),
      (80000 - lookBack, 120000),
    ]);
  });

  test('when speech comes back before the steady VAD has its second, what '
      'it cuts is reported from where the quick one heard speech again', () {
    quick.detected = steady.detected = true;
    at(10000);
    quick
      ..detected = false
      ..cuts.add((start: 5000, end: 40000));
    at(48000);
    // speech again after 0.7 s, heard by the quick VAD
    quick.detected = true;
    at(56000);
    expect(cut.speech, isTrue);
    // known where it began: the first segment gets its padding up to the
    // middle of the gap at once, (40000 + 50976) / 2
    expect(out, [(start: 5000, end: 40000, from: 0, to: 45488)]);
    // the quick VAD's own later cuts are not used
    quick.cuts.add((start: 56000 - lookBack, end: 70000));
    at(80000);
    steady
      ..detected = false
      ..cuts.add((start: 5000, end: 100000));
    at(120000);
    expect(cut.quickWanted, isFalse);
    at(140000, total: 140000);
    expect(out.map((s) => (s.start, s.end, s.from)), [
      (5000, 40000, 0),
      // its padding before starts where the first one's decoding ended
      (56000 - lookBack, 100000, 45488),
    ]);
  });

  test('a blip the steady VAD ran on through but the quick one never took '
      'for speech is dropped', () {
    quick.detected = steady.detected = true;
    at(10000);
    quick
      ..detected = false
      ..cuts.add((start: 5000, end: 40000));
    at(48000);
    steady
      ..detected = false
      ..cuts.add((start: 5000, end: 52000));
    at(70000);
    at(90000, total: 90000);
    expect(out.map((s) => (s.start, s.end)), [(5000, 40000)]);
  });

  test('audio that ends inside the first segment: the quick VAD is the one '
      'flushed', () {
    quick.detected = steady.detected = true;
    at(10000);
    expect(cut.flushQuick, isTrue);
    quick
      ..detected = false
      ..cuts.add((start: 5000, end: 30000));
    at(30000, total: 30000);
    expect(out, [(start: 5000, end: 30000, from: 0, to: 30000)]);
  });

  test('both cut together at the 20 s cap: the segment is reported once, '
      'and the steady VAD goes on alone', () {
    quick.detected = steady.detected = true;
    at(10000);
    quick.cuts.add((start: 0, end: 320000));
    steady.cuts.add((start: 0, end: 320000));
    at(320512);
    expect(cut.quickWanted, isFalse);
    // the next segment begins at once
    at(322560);
    expect(cut.speech, isTrue);
    expect(out, [(start: 0, end: 320000, from: 0, to: 320000)]);
  });

  test('a segment cut at the length cap is handed out at once, with no '
      'padding across the cut; the VAD goes on inside its segment, and '
      'the rest of that is a new segment from the cut', () {
    quick.detected = steady.detected = true;
    at(10000);
    expect(padding.speechFrom, 10000 - lookBack);
    // the cap is reached in the first segment: neither VAD has cut
    cut.cutAt(300000, rest: 512);
    expect(cut.speech, isTrue);
    expect(cut.quickWanted, isFalse);
    expect(cut.flushQuick, isFalse);
    expect(padding.speechFrom, 300000);
    at(330000);
    expect(out, [
      (start: 10000 - lookBack, end: 300000, from: 0, to: 300000),
    ]);
    // the steady VAD, never started over, still sees one segment: it is
    // handed over whole, and only its part after the cut is new
    expect(cut.speech, isTrue);
    steady
      ..detected = false
      ..cuts.add((start: 5000, end: 400000));
    at(440000, total: 440000);
    expect(out.last, (start: 300000, end: 400000, from: 300000, to: 406400));
    expect(out, hasLength(2));
  });

  test('the cap in the middle of a later segment; the VAD segment ending '
      'right after the cut is dropped, the next one is as the VAD cut it', () {
    quick.detected = steady.detected = true;
    at(10000);
    quick
      ..detected = false
      ..cuts.add((start: 5000, end: 40000));
    at(48000);
    steady
      ..detected = false
      ..cuts.add((start: 5000, end: 40000));
    at(56000);
    steady.detected = true;
    at(80000);
    cut.cutAt(390000, rest: 512);
    // the VAD ends its segment within a window of the cut: nothing is left
    steady
      ..detected = false
      ..cuts.add((start: 75000, end: 390300));
    at(400000);
    expect(cut.speech, isFalse);
    expect(out.map((s) => (s.start, s.end)), [
      (5000, 40000),
      (80000 - lookBack, 390000),
    ]);
    expect(out.last.from, 80000 - lookBack - pad);
    expect(out.last.to, 390000);
    // new speech: where the VAD begins it, not at the cut
    steady.detected = true;
    at(420000);
    expect(padding.speechFrom, 420000 - lookBack);
    steady
      ..detected = false
      ..cuts.add((start: 415000, end: 450000));
    at(600000, total: 600000);
    expect(out.last.start, 415000);
    expect(out, hasLength(3));
  });

  test('two cuts in one VAD segment', () {
    steady.detected = quick.detected = true;
    at(10000);
    cut.cutAt(300000, rest: 512);
    at(600000);
    expect(padding.speechFrom, 300000);
    cut.cutAt(600000, rest: 512);
    at(620000);
    steady
      ..detected = false
      ..cuts.add((start: 5000, end: 700000));
    at(760000, total: 760000);
    expect(out.map((s) => (s.start, s.end, s.from, s.to)), [
      (10000 - lookBack, 300000, 0, 300000),
      (300000, 600000, 300000, 600000),
      (600000, 700000, 600000, 706400),
    ]);
  });

  test('once past the first segment the quick VAD is no longer asked', () {
    quick.detected = steady.detected = true;
    at(10000);
    quick
      ..detected = false
      ..cuts.add((start: 5000, end: 40000));
    at(48000);
    steady
      ..detected = false
      ..cuts.add((start: 5000, end: 40000));
    at(56000);
    final asked = quick.taken;
    at(60000);
    at(64000);
    expect(quick.taken, asked);
  });
}
