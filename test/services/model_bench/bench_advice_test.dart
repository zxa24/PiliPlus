import 'package:PiliPlus/services/model_bench/bench_advice.dart';
import 'package:flutter_test/flutter_test.dart';

/// Token counts giving [prompt] and [reply] tok/s over 1 s of prompt and
/// 2 s of reply.
BenchTokenRates rates(double prompt, double reply) => BenchTokenRates(
  promptTokens: prompt.round(),
  replyTokens: (reply * 2).round(),
  firstMs: 1000,
  totalMs: 3000,
);

BenchTranslation gemma({BenchTokenRates? alone, BenchTokenRates? together}) =>
    BenchTranslation(
      modelId: 'gemma-4-e2b-it-q4_0',
      label: 'Gemma 4 E2B（推荐）',
      loadMs: 3700,
      alone: alone,
      concurrent: together,
    );

BenchTranslation hy({BenchTokenRates? alone, BenchTokenRates? together}) =>
    BenchTranslation(
      modelId: 'hy-mt2-1.8b-q4_k_m',
      label: 'Hy-MT2 1.8B（体积小）',
      loadMs: 1500,
      alone: alone,
      concurrent: together,
    );

ModelBenchResult result({
  List<BenchTranslation> translations = const [],
  BenchAsrSpeed? english,
  bool englishInstalled = false,
  BenchMemory memory = const BenchMemory(),
  List<String> notInstalled = const [],
  String? interrupted,
  String? error,
}) => ModelBenchResult(
  at: DateTime(2026, 9, 29, 12),
  platform: 'android',
  cores: 8,
  asrThreads: 4,
  llamaThreads: 4,
  repacks: false,
  clipSeconds: 20,
  senseVoice: const BenchAsrSpeed(mediaSeconds: 40, wallMs: 4000, loadMs: 800),
  english: english,
  englishInstalled: englishInstalled,
  translations: translations,
  notInstalled: notInstalled,
  memory: memory,
  interrupted: interrupted,
  error: error,
);

List<String> texts(ModelBenchResult r) => [
  for (final a in benchAdvice(r)) a.text,
];

void main() {
  group('real-time factor', () {
    test('is 1 / (4/prompt + 3/reply)', () {
      expect(benchRealTime(prompt: 4, reply: 3), closeTo(0.5, 1e-9));
      expect(benchRealTime(prompt: 8, reply: 6), closeTo(1.0, 1e-9));
      // Pixel 6 Pro alone (noisy-speech §18.1): about 1.7×
      expect(benchRealTime(prompt: 15, reply: 9), closeTo(1.667, 0.001));
      // beside transcription: 9.1 / 2.9
      expect(benchRealTime(prompt: 9.1, reply: 2.9), closeTo(0.68, 0.005));
    });

    test('rates split at the first piece of the reply', () {
      const r = BenchTokenRates(
        promptTokens: 45,
        replyTokens: 29,
        firstMs: 5000,
        totalMs: 15000,
      );
      expect(r.promptPerSecond, closeTo(9.0, 1e-9));
      expect(r.replyPerSecond, closeTo(2.9, 1e-9));
      expect(r.realTime, closeTo(benchRealTime(prompt: 9, reply: 2.9), 1e-9));
    });

    test('a reply cut before it began leaves only a ceiling', () {
      const r = BenchTokenRates(
        promptTokens: 45,
        replyTokens: 0,
        firstMs: 12000,
        totalMs: 12000,
      );
      expect(r.replyPerSecond, isNull);
      expect(r.realTime, isNull);
      // 3.75 tok/s reading: at most 0.94× whatever the reply does
      expect(r.realTimeCeiling, closeTo(0.9375, 1e-9));
      final t = gemma(together: r);
      expect(t.concurrentRealTime, (value: 0.9375, ceiling: true));
      expect(t.rating, BenchRating.tooSlow);
    });

    test('a ceiling above 1× is not called comfortable', () {
      const r = BenchTokenRates(
        promptTokens: 80,
        replyTokens: 0,
        firstMs: 4000,
        totalMs: 4000,
      );
      expect(gemma(together: r).rating, BenchRating.borderline);
    });

    test('thresholds', () {
      // 1 / (4/16 + 3/12) = 2.0
      expect(gemma(together: rates(16, 12)).rating, BenchRating.comfortable);
      // either side of 1.3: p = r = 7 × factor
      expect(gemma(together: rates(10, 10)).rating, BenchRating.comfortable);
      expect(gemma(together: rates(9, 9)).rating, BenchRating.borderline);
      // 1.0–1.3
      expect(gemma(together: rates(8, 6)).rating, BenchRating.borderline);
      // Pixel 6 Pro beside transcription: 0.68×
      expect(gemma(together: rates(9.1, 2.9)).rating, BenchRating.tooSlow);
      expect(gemma().rating, isNull);
    });

    test('ASR speed', () {
      const s = BenchAsrSpeed(mediaSeconds: 40, wallMs: 4000);
      expect(s.speed, 10);
      expect(const BenchAsrSpeed(mediaSeconds: 0, wallMs: 10).speed, isNull);
    });
  });

  group('advice', () {
    test('Gemma when it keeps up', () {
      final lines = texts(
        result(
          translations: [
            gemma(alone: rates(16, 12), together: rates(16, 12)),
            hy(alone: rates(30, 20), together: rates(30, 20)),
          ],
        ),
      );
      expect(lines.first, startsWith('翻译：用 Gemma 4 E2B（推荐）'));
      expect(lines.first, contains('约 2.0 倍实时'));
      expect(lines.any((l) => l.startsWith('注意')), isFalse);
    });

    test('Hy-MT2 when only it keeps up', () {
      final lines = texts(
        result(
          translations: [
            gemma(together: rates(9.1, 2.9)),
            hy(together: rates(16, 12)),
          ],
        ),
      );
      expect(lines.first, startsWith('翻译：用 Hy-MT2 1.8B（体积小）'));
      expect(lines.first, contains('Gemma 约 0.7 倍实时'));
    });

    test('Hy-MT2 alone says Gemma was not tested', () {
      final lines = texts(
        result(
          translations: [hy(together: rates(16, 12))],
          notInstalled: ['Gemma 4 E2B（推荐）'],
        ),
      );
      expect(lines.first, contains('Gemma（推荐）未下载，未测'));
    });

    test('borderline', () {
      final lines = texts(result(translations: [gemma(together: rates(8, 6))]));
      expect(lines.first, startsWith('翻译：可以用 Gemma 4 E2B（推荐），但余量小'));
      // Hy-MT2 not installed: named to try, with no number for it
      expect(lines.first, endsWith('也可下载 Hy-MT2（体积小）后再测。'));
    });

    test('too slow: transcribe only, and the keep-up note', () {
      final lines = texts(
        result(
          translations: [
            gemma(alone: rates(15, 9), together: rates(9.1, 2.9)),
          ],
        ),
      );
      expect(lines.first, startsWith('翻译：本机太慢'));
      expect(lines.first, contains('建议只转录不翻译'));
      expect(
        lines.last,
        allOf(startsWith('注意：转录进行时翻译跟不上播放'), contains('单独约 1.7 倍实时')),
      );
    });

    test('no translation model installed', () {
      expect(
        texts(result()).first,
        '翻译：没有已下载的翻译模型，无法测试。下载后可再测。',
      );
    });

    test('English model: worth it, slow, or costly beside translation', () {
      const fast = BenchAsrSpeed(mediaSeconds: 160, wallMs: 20000); // 8×
      const slow = BenchAsrSpeed(mediaSeconds: 60, wallMs: 20000); // 3×
      String english(ModelBenchResult r) =>
          texts(r).firstWhere((l) => l.startsWith('英语'));
      expect(
        english(
          result(
            english: fast,
            englishInstalled: true,
            translations: [gemma(together: rates(16, 12))],
          ),
        ),
        startsWith('英语模型：值得用'),
      );
      expect(
        english(result(english: slow, englishInstalled: true)),
        startsWith('英语模型：本机偏慢'),
      );
      expect(
        english(
          result(
            english: fast,
            englishInstalled: true,
            translations: [gemma(together: rates(8, 6))],
          ),
        ),
        contains('会让翻译更慢'),
      );
      expect(english(result()), '英语识别模型未下载，未测试。');
    });

    test('memory too small for both models', () {
      final lines = texts(
        result(
          translations: [gemma(together: rates(16, 12))],
          // a Pixel 4 XL: about 2 GB available (translation-bench)
          memory: const BenchMemory(availableAtStartMb: 2000, totalMb: 5600),
        ),
      );
      expect(lines.last, startsWith('内存：测试前可用约 2.0 GB'));
      // 0.4 GB recogniser + 2.5 GB Gemma
      expect(lines.last, contains('约需 2.8 GB'));
    });

    test('a measured growth larger than the estimate is used', () {
      final lines = texts(
        result(
          translations: [hy(together: rates(16, 12))],
          memory: const BenchMemory(
            availableAtStartMb: 2500,
            rssAtStartMb: 300,
            peakRssMb: 3400,
          ),
        ),
      );
      expect(lines.last, contains('约需 3.0 GB'));
    });

    test('memory enough: no line', () {
      final lines = texts(
        result(
          translations: [gemma(together: rates(16, 12))],
          memory: const BenchMemory(availableAtStartMb: 6000),
        ),
      );
      expect(lines.any((l) => l.startsWith('内存')), isFalse);
    });

    test('memory pressure during the test', () {
      final lines = texts(
        result(
          translations: [gemma(alone: rates(16, 12))],
          memory: const BenchMemory(pressure: true),
          interrupted: '系统报告内存不足',
        ),
      );
      expect(lines.first, '测试未完成：系统报告内存不足');
      expect(lines.last, startsWith('内存：测试中系统报告内存不足'));
    });

    test('no recogniser: nothing else can be timed', () {
      final r = ModelBenchResult(
        at: DateTime(2026, 9, 29),
        platform: 'windows',
        cores: 20,
        asrThreads: 8,
        llamaThreads: 0,
        repacks: true,
        asrInstalled: false,
      );
      expect(texts(r), [
        '语音转录模型未下载，无法测试；翻译要和转录一起测，也需要先下载它。',
      ]);
    });

    test('an error is the only line', () {
      expect(texts(result(error: '正在转录，请先停止')), ['正在转录，请先停止']);
    });
  });

  test('a result survives JSON', () {
    final r = result(
      translations: [
        gemma(alone: rates(15, 9), together: rates(9.1, 2.9)),
        const BenchTranslation(modelId: 'x', label: 'x', error: 'boom'),
      ],
      english: const BenchAsrSpeed(
        mediaSeconds: 80,
        wallMs: 10000,
        loadMs: 4200,
      ),
      englishInstalled: true,
      memory: const BenchMemory(
        totalMb: 11000,
        availableAtStartMb: 5000,
        minAvailableMb: 1800,
        rssAtStartMb: 400,
        peakRssMb: 4300,
      ),
      notInstalled: ['Hy-MT2 1.8B（体积小）'],
    );
    final back = ModelBenchResult.fromJson(r.toJson())!;
    expect(back.toJson(), r.toJson());
    expect(benchAdvice(back), benchAdvice(r));
    expect(benchDetails(back), benchDetails(r));
    expect(ModelBenchResult.fromJson({'at': 'nonsense'}), isNull);
    expect(ModelBenchResult.fromJson('x'), isNull);
  });
}
