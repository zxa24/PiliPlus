// Translation over a transcript in several stretches, made by several runs
// (research/chunked-transcription-design-2026-09-25.md, 4.2 and 4.6). A
// session today has one run from 0; these are synthetic inputs for what
// starting runs elsewhere will produce.
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/translate/translation_layout.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/services/translate/translation_unit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_test.dart'
    show FakeEngine, cue, pumpUntil, resultsFor, storeOf;

/// Segments of 3 s at [starts], each with one cue named after where it is.
TranscriptStore run(
  List<double> starts, {
  required double from,
  TranscriptStore? into,
  String name = 'at',
}) => storeOf(
  [for (final s in starts) (start: s, duration: 3.0)],
  [for (final s in starts) cue(s, s + 3, '$name ${s.toStringAsFixed(1)}')],
  start: from,
  into: into,
);

void main() {
  late double now;
  late FakeEngine engine;
  var complete = false;
  var resting = false;

  TranslationSession make(TranscriptStore store) => TranslationSession(
    transcript: transcriptView(
      store,
      complete: () => complete,
      resting: () => resting,
    ),
    position: () => now,
    engine: (_) async => engine = FakeEngine(),
    target: 'zh',
  );

  setUp(() {
    now = 0;
    complete = false;
    resting = false;
  });

  /// Every settled unit's result is its own: made from its text.
  void expectOwnResults(TranslationSession session) {
    for (final unit in session.units) {
      final result = session.results.of(unit);
      if (result == null) continue;
      expect(result.source, unit.text);
      expect(result.text, '译:${unit.text}');
    }
  }

  test('text put in front of translated units does not shift their '
      'translations onto others', () async {
    // two stretches: 0..~10 and 200..~210
    final store = run([0, 5, 10], from: 0);
    run([200, 205, 210], from: 200, into: store);
    for (final r in store.runs) {
      r.finish();
    }
    now = 150;
    final session = make(store)..start();
    await pumpUntil(
      () =>
          session.state.value.stage == TranslationStage.waiting &&
          session.next() == null,
    );
    final before = {
      for (final unit in session.units)
        if (session.results.settles(unit)) unit.text,
    };
    expect(before, {'at 200.0', 'at 205.0', 'at 210.0'});

    // a run from 100 lands between them: every unit after it moves up
    // three places in the list
    run([100, 105, 110], from: 100, into: store, name: 'mid');
    store.runs.singleWhere((r) => r.start == 100).finish();
    session.poke();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    session.units = session.transcript.units();
    expect(session.units.map((u) => u.text), [
      'at 0.0',
      'at 5.0',
      'at 10.0',
      'mid 100.0',
      'mid 105.0',
      'mid 110.0',
      'at 200.0',
      'at 205.0',
      'at 210.0',
    ]);
    expectOwnResults(session);
    // the late stretch keeps its translations, shown under its own lines
    final shown = session.cues(markPending: false);
    expect(
      shown.where((c) => c.from >= 200).map((c) => c.content),
      ['译:at 200.0', '译:at 205.0', '译:at 210.0'],
    );
    await session.dispose();
  });

  test('the same start with other text is untranslated, not the old '
      'translation', () async {
    final store = run([0, 5], from: 0)..runs.single.finish();
    now = 0;
    final session = make(store)..start();
    await pumpUntil(() => session.results.length == 2);
    await session.dispose();

    // the same moment, transcribed again with other words
    final again = storeOf(
      [(start: 0, duration: 3), (start: 5, duration: 3)],
      [cue(0, 3, 'other words'), cue(5, 8, 'at 5.0')],
    )..runs.single.finish();
    final redo = make(again)
      ..results.addAll(session.results)
      ..units = transcriptView(again, complete: () => true).units();
    final first = redo.units.first;
    expect(first.key, session.units.first.key);
    expect(redo.results.settles(first), isFalse);
    expect(redo.results.settles(redo.units.last), isTrue);
    expect(redo.next(), same(first));
    final shown = redo.cues();
    expect(shown.first.content, 'other words\n$translationPendingMark');
    expect(shown.map((c) => c.content), isNot(contains('译:at 0.0')));
    redo.start();
    await pumpUntil(() => redo.results.of(redo.units.first) != null);
    expect(redo.results.of(redo.units.first)!.text, '译:other words');
    await redo.dispose();
  });

  test(
    'two units starting in the same millisecond keep a result each',
    () async {
      // overlapping caption lines: one key would have each translation
      // replace the other's, for ever
      final session = TranslationSession(
        transcript: fixedTranscript([
          TranslationUnit(
            from: 1,
            to: 3,
            text: 'one',
            cues: [cue(1, 3, 'one')],
          ),
          TranslationUnit(
            from: 1,
            to: 4,
            text: 'two',
            cues: [cue(1, 4, 'two')],
          ),
        ]),
        position: () => 0,
        engine: (_) async => FakeEngine(),
        target: 'zh',
      )..start();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(session.results.keys, [1000, 1001]);
      expect(session.units.map((u) => session.results.of(u)!.text), [
        '译:one',
        '译:two',
      ]);
    },
  );

  test('units handed out are never cut again when a run lands just '
      'before them', () {
    // run A's segments are 3 s long with 2 s pauses: one unit each
    final store = run([10, 15, 20], from: 10)..runs.single.finish();
    final view = transcriptView(store, complete: () => false);
    final issued = view.units();
    expect(issued.map((u) => u.text), ['at 10.0', 'at 15.0', 'at 20.0']);

    // a run from 5 whose segment ends 0.1 s before A's first: cut as one
    // transcript, the two would be joined into one unit
    final early = store.startRun(5);
    store.addSegment(early, 6.9, 3, [cue(6.9, 9.9, 'early')]);
    early.finish();
    final after = view.units();
    expect(after.map((u) => u.text), [
      'early',
      'at 10.0',
      'at 15.0',
      'at 20.0',
    ]);
    for (final unit in issued) {
      final same = after.singleWhere((u) => u.key == unit.key);
      expect((same.from, same.to, same.text), (unit.from, unit.to, unit.text));
    }
    // the joining rule itself is unchanged within a run
    expect(
      buildTranslationUnits(
        segments: const [(start: 6.9, duration: 3), (start: 10, duration: 3)],
        cues: [cue(6.9, 9.9, 'early'), cue(10, 13, 'at 10.0')],
        complete: true,
      ).map((u) => u.text),
      ['early at 10.0'],
    );
  });

  test('lines not in a unit yet are found run by run', () {
    // each run's newest segment is still open: its cue is in no unit
    final store = run([0, 5], from: 0);
    run([100, 105], from: 100, into: store);
    final view = transcriptView(store, complete: () => false);
    expect(view.units().map((u) => u.text), ['at 0.0', 'at 100.0']);
    // not "the cues after the first two", which would be at 100.0 (in a
    // unit) and at 105.0, losing at 5.0
    expect(view.trailing().map((c) => c.content), ['at 5.0', 'at 105.0']);

    final session = make(store)..units = view.units();
    final shown = session.cues().map((c) => c.content).toList();
    expect(shown, [
      'at 0.0\n$translationPendingMark',
      'at 5.0\n$translationPendingMark',
      'at 100.0\n$translationPendingMark',
      'at 105.0\n$translationPendingMark',
    ]);
  });

  group('across a gap in the transcript', () {
    late TranscriptStore store;
    late TranslationSession session;

    setUp(() {
      // 0..~23 known, then nothing until 200..~223
      store = run([0, 10, 20], from: 0);
      run([200, 210, 220], from: 200, into: store);
      for (final r in store.runs) {
        r.finish();
      }
      session = make(store)
        ..units = transcriptView(store, complete: () => false).units();
    });

    test('next() skips what is behind and takes what is in the lead', () {
      now = 15;
      // 0 is behind; 10 and 20 are next; 200 is beyond the lead
      session.results.addAll(resultsFor(session.units, {1: 'x', 2: 'y'}));
      expect(session.next(), isNull);
      now = 150;
      // everything before the gap is behind: the stretch after it is next
      expect(session.next()!.text, 'at 200.0');
      session.results.addAll(resultsFor(session.units, {3: 'z'}));
      expect(session.next()!.text, 'at 210.0');
    });

    test('settledFrom does not run on over the gap', () {
      // everything is translated, on both sides
      session.results.addAll(
        resultsFor(session.units, {for (var i = 0; i < 6; i++) i: 't'}),
      );
      // the viewer runs out where the first stretch's text does
      expect(session.settledFrom(5), 23);
      expect(session.settledFrom(205), 223);
      // in the gap: nothing settled ahead
      expect(session.settledFrom(100), 100);
    });

    test('nothing is pending only as far as the text is known', () {
      session.results.addAll(
        resultsFor(session.units, {for (var i = 0; i < 6; i++) i: 't'}),
      );
      now = 5;
      // units at 200 lie past the lead, but the gap before them may yet
      // hold speech
      expect(session.nothingPendingAhead(within: 120), isFalse);
      now = 150;
      expect(session.nothingPendingAhead(within: 120), isFalse);
      now = 205;
      expect(session.nothingPendingAhead(within: 10), isTrue);
    });
  });

  test(
    'a paused transcript with its lead translated lets the model go',
    () async {
      // one stretch 0..~303, units at 0, 100 and 300; the lead from 0 is
      // 120 s, so 300 is not translated yet
      final store = run([0, 100, 300], from: 0);
      store.runs.single.finish();
      final session = make(store)..start();
      await pumpUntil(
        () =>
            session.results.length == 2 &&
            session.state.value.stage == TranslationStage.waiting,
      );
      // still recognising: the model is kept for what comes next
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(engine.disposed, isFalse);
      // paused (AsrStage.standby): nothing more is coming for a while
      resting = true;
      session.poke();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(engine.disposed, isTrue);
      // the viewer moves on: it loads again for the unit at 300
      now = 250;
      session.poke();
      await pumpUntil(() => session.results.length == 3);
      await session.dispose();
    },
  );
}
