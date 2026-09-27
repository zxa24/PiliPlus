import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/services/subtitle_cache/translation_cache.dart';
import 'package:PiliPlus/services/translate/translation_engine.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

AsrCue cue(double from, double to, String content) =>
    AsrCue(from: from, to: to, content: content);

const recogniser = 'sense-voice-2024-07-17+silero-vad';

/// A transcript of two runs that met at a seam, one segment of the first
/// run replaced by the second's, and silence known past the last segment.
TranscriptStore sampleStore() {
  final store = TranscriptStore();
  final first = store.startRun(0);
  store
    ..addSegment(
      first,
      0.5,
      3,
      [cue(0.5, 2, 'Hello there.'), cue(2, 3.5, 'How are you?')],
      language: 'en',
      weight: 25,
    )
    ..addSegment(first, 5, 1, const [], language: 'en', weight: 1)
    ..addSegment(
      first,
      8,
      2,
      [cue(8, 10.4, '你好')],
      language: 'zh',
      weight: 3,
    )
    ..advance(first, 12);
  first.finish();
  final second = store.startRun(40);
  store
    ..addSegment(
      second,
      40.2,
      4,
      [cue(40.2, 42, 'A second run.'), cue(42, 44.2, 'It goes on.')],
      language: 'en',
      weight: 27,
    )
    ..addSegment(
      second,
      46,
      2.5,
      [cue(46, 48.5, 'Replaced soon.')],
      language: 'en',
      weight: 15,
    )
    ..replace(
      second,
      [
        (
          start: 45.9,
          duration: 3,
          cues: [cue(45.9, 48.9, 'The seam kept this.')],
          language: 'en',
          weight: 20,
        ),
      ],
      (s) => s.start == 46,
    )
    ..advance(second, 50.25);
  return store;
}

class CountingEngine implements TranslationEngine {
  final prompts = <String>[];

  @override
  Future<String> complete(String prompt) async {
    prompts.add(prompt);
    return '译:${prompt.split('\n\n').last}';
  }

  @override
  void cancel() {}

  @override
  Future<void> dispose() async {}
}

Future<void> pumpUntil(bool Function() done, {int tries = 400}) async {
  for (var i = 0; i < tries && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'condition not reached');
}

void main() {
  late Directory root;
  late Directory dir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('subtitle_cache_test');
    dir = Directory(path.join(root.path, SubtitleCache.dirName));
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  List<String> files() => dir.existsSync()
      ? [for (final f in dir.listSync()) path.basename(f.path)]
      : const [];

  group('keys', () {
    test('a part is its platform and id; a file its location and size', () {
      expect(SubtitleCacheKey.bilibili(123).id, 'bili:123');
      expect(SubtitleCacheKey.youtube('abc_-1').id, 'yt:abc_-1');
      expect(SubtitleCacheKey.bilibili(123), SubtitleCacheKey.bilibili(123));
      expect(
        SubtitleCacheKey.bilibili(123) == SubtitleCacheKey.youtube('123'),
        isFalse,
      );
      final file = File(path.join(root.path, 'a.m4a'))
        ..writeAsBytesSync(List.filled(10, 1));
      expect(SubtitleCacheKey.local(file.path).id, endsWith('a.m4a#10'));
      expect(
        SubtitleCacheKey.local('content://x/y', size: 5).id,
        'file:content://x/y#5',
      );
    });

    test('another recogniser, or a forced language, is another entry', () {
      final key = SubtitleCacheKey.bilibili(1);
      final forced = subtitleRecogniserId(
        model: 'sense-voice-2024-07-17',
        vad: 'silero-vad',
        language: 'ja',
      );
      expect(forced, '$recogniser@ja');
      final names = {
        subtitleCacheFileName(key, recogniser),
        subtitleCacheFileName(key, forced),
        subtitleCacheFileName(key, 'other-model+silero-vad'),
        subtitleCacheFileName(SubtitleCacheKey.bilibili(2), recogniser),
      };
      expect(names, hasLength(4));
      expect(
        subtitleTranslationKey('zh', 'gemma'),
        isNot(subtitleTranslationKey('zh', 'hy')),
      );
      expect(
        subtitleTranslationKey('zh', 'gemma'),
        isNot(subtitleTranslationKey('zh-Hant', 'gemma')),
      );
    });

    test(
      'a changed model misses: the text of another is never shown',
      () async {
        final cache = SubtitleCache(dir, limitBytes: () => 1 << 29);
        final key = SubtitleCacheKey.youtube('v');
        final entry = await cache.open(key, recogniser);
        entry.captureTranscript(sampleStore(), mediaEnd: 60);
        await cache.save(entry);
        // a new run of the app: nothing in memory
        final later = SubtitleCache(dir, limitBytes: () => 1 << 29);
        expect((await later.open(key, recogniser)).runs, isNotEmpty);
        expect((await later.open(key, '$recogniser@en')).runs, isEmpty);
        expect((await later.open(key, 'other+silero-vad')).runs, isEmpty);
        expect(
          (await later.open(SubtitleCacheKey.youtube('w'), recogniser)).runs,
          isEmpty,
        );
      },
    );
  });

  group('the transcript', () {
    test('comes back with the same stretches, segments, cues and units', () {
      final store = sampleStore();
      final entry = SubtitleCacheEntry(SubtitleCacheKey.bilibili(9), recogniser)
        ..captureTranscript(store, mediaEnd: 61.5);
      // through the file format, as it is written and read
      final back = SubtitleCacheEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())),
      )!;
      expect(back.mediaEnd, 61.5);
      final restored = TranscriptStore()..restore(back.runs);
      expect(restored.covered, store.covered);
      expect(restored.covered, [
        (from: 0.0, to: 12.0),
        (from: 40.0, to: 50.25),
      ]);
      expect(restored.cues.toList(), store.cues.toList());
      expect(
        [for (final s in restored.segments) (s.start, s.duration, s.language)],
        [for (final s in store.segments) (s.start, s.duration, s.language)],
      );
      expect(
        [
          for (final r in restored.runs)
            (r.start, r.from, r.end, r.cueCounts.join(',')),
        ],
        [
          for (final r in store.runs)
            (r.start, r.from, r.end, r.cueCounts.join(',')),
        ],
      );
      expect(restored.runs.every((r) => r.finished), isTrue);
      expect(
        [for (final r in restored.runs) r.segments],
        [for (final r in store.runs) r.segments],
      );
      // translation cuts the same units from it, under the same keys
      List<(int, String, String)> units(TranscriptStore s) => [
        for (final u in transcriptView(s, complete: () => true).units())
          (u.key, u.text, u.language),
      ];
      expect(units(restored), units(store));
      expect(units(restored), isNotEmpty);
      expect(restored.cues.toSrt(), store.cues.toSrt());
    });

    test('restoring changes the cue list once', () async {
      final entry = SubtitleCacheEntry(SubtitleCacheKey.bilibili(9), recogniser)
        ..captureTranscript(sampleStore());
      final restored = TranscriptStore();
      var changes = 0;
      restored.cues.listen((_) => changes++);
      restored.restore(entry.runs);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
    });

    test('a run later added to a restored store goes in beside it', () {
      final entry = SubtitleCacheEntry(SubtitleCacheKey.bilibili(9), recogniser)
        ..captureTranscript(sampleStore());
      final store = TranscriptStore()..restore(entry.runs);
      final run = store.startRun(12);
      store.addSegment(run, 13, 2, [cue(13, 15, 'gap filled')]);
      expect(run.id, 2);
      expect(store.covered, [(from: 0.0, to: 15.0), (from: 40.0, to: 50.25)]);
      expect(store.cues.map((c) => c.content).toList()[3], 'gap filled');
    });
  });

  group('the file', () {
    test('is written whole: scratch then rename, over the old one', () async {
      final cache = SubtitleCache(dir, limitBytes: () => 1 << 29);
      final key = SubtitleCacheKey.bilibili(5);
      final entry = await cache.open(key, recogniser);
      entry.captureTranscript(sampleStore());
      await cache.save(entry);
      final name = subtitleCacheFileName(key, recogniser);
      expect(files(), [name]);
      // and again over it: rename replaces the file
      entry.translations['zh|m'] = {
        500: (source: 'Hello there. How are you?', text: '你好', passed: false),
      };
      await cache.save(entry);
      expect(files(), [name]);
      final json = jsonDecode(
        File(path.join(dir.path, name)).readAsStringSync(),
      );
      expect(json['format'], SubtitleCache.format);
      expect((json['translations'] as Map)['zh|m'], isNotNull);
      expect(cache.usage, File(path.join(dir.path, name)).lengthSync());
    });

    test('an old format or an unreadable one is ignored and deleted', () async {
      final key = SubtitleCacheKey.bilibili(6);
      final name = subtitleCacheFileName(key, recogniser);
      final entry = SubtitleCacheEntry(key, recogniser)
        ..captureTranscript(sampleStore());
      dir.createSync(recursive: true);
      final file = File(path.join(dir.path, name))
        ..writeAsStringSync(
          jsonEncode({...entry.toJson(), 'format': SubtitleCache.format - 1}),
        );
      final opened = await SubtitleCache(
        dir,
        limitBytes: () => 1 << 29,
      ).open(key, recogniser);
      expect(opened.runs, isEmpty);
      expect(file.existsSync(), isFalse);

      file.writeAsStringSync('{"format": 1, "runs": [tru');
      expect(
        (await SubtitleCache(
          dir,
          limitBytes: () => 1 << 29,
        ).open(key, recogniser)).runs,
        isEmpty,
      );
      expect(file.existsSync(), isFalse);

      file.writeAsStringSync(jsonEncode(entry.toJson()));
      expect(
        (await SubtitleCache(
          dir,
          limitBytes: () => 1 << 29,
        ).open(key, recogniser)).runs,
        isNotEmpty,
      );
    });

    test('a scratch file left by a write cut short goes at the scan', () async {
      dir.createSync(recursive: true);
      final old = File(path.join(dir.path, 'x.json.1_0.tmp'))
        ..writeAsStringSync('half')
        ..setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 1)),
        );
      final fresh = File(path.join(dir.path, 'y.json.1_1.tmp'))
        ..writeAsStringSync('being written');
      expect(await SubtitleCache(dir, limitBytes: () => 1 << 29).measure(), 0);
      expect(old.existsSync(), isFalse);
      // another instance may be writing this one now
      expect(fresh.existsSync(), isTrue);
    });

    test('nothing is written for a transcript with nothing in it', () async {
      final cache = SubtitleCache(dir, limitBytes: () => 1 << 29);
      final entry = await cache.open(SubtitleCacheKey.bilibili(7), recogniser);
      entry.captureTranscript(TranscriptStore());
      await cache.save(entry);
      expect(files(), isEmpty);
    });
  });

  group('the limit', () {
    test('the least recently used go first, until the rest fit', () async {
      // each entry is the same size; room for three
      final probe = SubtitleCacheEntry(SubtitleCacheKey.bilibili(0), recogniser)
        ..captureTranscript(sampleStore());
      final size = utf8.encode(jsonEncode(probe.toJson())).length;
      var limit = size * 3 + size ~/ 2;
      final cache = SubtitleCache(dir, limitBytes: () => limit);
      final base = DateTime.now().subtract(const Duration(days: 1));
      final names = <int, String>{};
      for (var cid = 1; cid <= 3; cid++) {
        final key = SubtitleCacheKey.bilibili(cid);
        final entry = await cache.open(key, recogniser);
        entry.captureTranscript(sampleStore());
        await cache.save(entry);
        names[cid] = subtitleCacheFileName(key, recogniser);
        // written in order, an hour apart
        File(
          path.join(dir.path, names[cid]),
        ).setLastModifiedSync(base.add(Duration(hours: cid)));
      }
      // a later run of the app reads the times from the disk
      final later = SubtitleCache(dir, limitBytes: () => limit);
      // 1 is watched again: now the most recently used
      expect(
        (await later.open(SubtitleCacheKey.bilibili(1), recogniser)).runs,
        isNotEmpty,
      );
      final four = await later.open(SubtitleCacheKey.bilibili(4), recogniser);
      four.captureTranscript(sampleStore());
      await later.save(four);
      names[4] = subtitleCacheFileName(
        SubtitleCacheKey.bilibili(4),
        recogniser,
      );
      // 2 was used longest ago
      expect(files()..sort(), [names[1], names[3], names[4]]..sort());
      expect(later.usage, lessThanOrEqualTo(limit));

      // a lower limit applies at once
      limit = size + size ~/ 2;
      await later.evict();
      expect(files(), [names[4]]);
      expect(later.usage, lessThanOrEqualTo(limit));
    });

    test('clearing takes everything', () async {
      final cache = SubtitleCache(dir, limitBytes: () => 1 << 29);
      final entry = await cache.open(SubtitleCacheKey.bilibili(1), recogniser);
      entry.captureTranscript(sampleStore());
      await cache.save(entry);
      expect(await cache.measure(), greaterThan(0));
      await cache.clear();
      expect(files(), isEmpty);
      expect(cache.usage, 0);
      expect(
        (await cache.open(SubtitleCacheKey.bilibili(1), recogniser)).runs,
        isEmpty,
      );
    });
  });

  group('translations', () {
    TranslationSession sessionFor(
      TranscriptStore store,
      CountingEngine engine,
    ) => TranslationSession(
      transcript: transcriptView(store, complete: () => true),
      position: () => 0,
      engine: (_) async => engine,
      target: 'zh',
      routeOf: (language) => TranslationService.routeFor(language, 'zh'),
    );

    TranscriptStore english() {
      final store = TranscriptStore();
      final run = store.startRun(0);
      store
        ..addSegment(
          run,
          1,
          2,
          [cue(1, 3, 'First line here.')],
          language: 'en',
          weight: 17,
        )
        ..addSegment(
          run,
          10,
          2,
          [cue(10, 12, 'Second line here.')],
          language: 'en',
          weight: 18,
        );
      run.finish();
      return store;
    }

    test('are taken only where the text is the same', () async {
      final entry = SubtitleCacheEntry(
        SubtitleCacheKey.bilibili(1),
        recogniser,
      );
      final key = subtitleTranslationKey('zh', 'gemma');
      entry.translations[key] = {
        // made from the same text: taken
        1000: (source: 'First line here.', text: '第一行', passed: false),
        // the same moment, other text (transcribed again differently): not
        10000: (source: 'Second line, old.', text: '旧的第二行', passed: false),
      };
      final engine = CountingEngine();
      final session = sessionFor(english(), engine);
      final link = TranslationCacheLink(session, entry, key: key);
      expect(link.preloaded, 2);
      session.start();
      await pumpUntil(() => session.translatedAll);
      expect(engine.prompts, hasLength(1));
      expect(engine.prompts.single, endsWith('Second line here.'));
      expect(session.modelLoads, 1);
      final track = session.cues(markPending: false);
      expect(track.map((c) => c.content), ['第一行', '译:Second line here.']);
      link.close();
      // what is kept now: the one taken, and the new one in place of the
      // stale one
      expect(entry.translations[key], {
        1000: (source: 'First line here.', text: '第一行', passed: false),
        10000: (
          source: 'Second line here.',
          text: '译:Second line here.',
          passed: false,
        ),
      });
      await session.dispose();
    });

    test('all kept: the model is never loaded', () async {
      final entry = SubtitleCacheEntry(
        SubtitleCacheKey.bilibili(1),
        recogniser,
      );
      final key = subtitleTranslationKey('zh', 'gemma');
      entry.translations[key] = {
        1000: (source: 'First line here.', text: '第一行', passed: false),
        10000: (source: 'Second line here.', text: '第二行', passed: false),
      };
      final engine = CountingEngine();
      final session = sessionFor(english(), engine);
      TranslationCacheLink(session, entry, key: key);
      session.start();
      await pumpUntil(() => session.state.value.stage == TranslationStage.done);
      expect(engine.prompts, isEmpty);
      expect(session.modelLoads, 0);
      await session.dispose();
    });

    test('another language or model takes nothing', () {
      final entry = SubtitleCacheEntry(
        SubtitleCacheKey.bilibili(1),
        recogniser,
      );
      entry.translations[subtitleTranslationKey('zh', 'gemma')] = {
        1000: (source: 'First line here.', text: '第一行', passed: false),
      };
      final engine = CountingEngine();
      final session = sessionFor(english(), engine);
      final link = TranslationCacheLink(
        session,
        entry,
        key: subtitleTranslationKey('zh', 'hy'),
      );
      expect(link.preloaded, 0);
      expect(session.results, isEmpty);
    });

    test('a failure is not kept', () {
      final entry = SubtitleCacheEntry(SubtitleCacheKey.bilibili(1), recogniser)
        ..captureTranslations(
          'zh|m',
          {
            1: (source: 'a', text: null, passed: false),
            2: (source: 'b', text: 'B', passed: false),
            3: (source: 'c', text: 'c', passed: true),
          },
          {1: 'a', 2: 'b', 3: 'c'},
        );
      expect(entry.translations['zh|m']!.keys, [2, 3]);
      final back = SubtitleCacheEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())),
      )!;
      expect(back.translations['zh|m'], entry.translations['zh|m']);
    });
  });
}
