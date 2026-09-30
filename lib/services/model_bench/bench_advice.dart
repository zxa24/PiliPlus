/// LibrePili: what the models page's performance test measured, and the
/// advice drawn from it.
///
/// Kept apart from the runner (model_bench.dart) so the arithmetic and the
/// thresholds can be tested with fixed numbers, without native models.
///
/// Every number the advice rests on is a phone measurement recorded in
/// research/noisy-speech-design-2026-09-26.md §17–§18.1 and
/// research/translation-bench-2026-09-23.md; each constant says which.
library;

/// Prompt tokens a media-second of speech needs translated: V8's units on a
/// Pixel 6 Pro, prompt tokens over media seconds (noisy-speech §18.1).
const benchPromptTokensPerMediaSecond = 4.0;

/// Reply tokens a media-second of speech needs (noisy-speech §18.1).
const benchReplyTokensPerMediaSecond = 3.0;

/// At or above this, translation beside transcription keeps up with room to
/// spare. 1.3× is what a Pixel 6 Pro reached once transcription had
/// finished (1.31×, noisy-speech §18.1), the pace at which no viewer wait
/// was seen after the opening (§18: the one wait came while transcription
/// was still racing ahead at 0.57×).
const benchComfortableRealTime = 1.3;

/// Below this, translation beside transcription falls behind playback: a
/// media-second takes longer than a second to translate. Between this and
/// [benchComfortableRealTime] it keeps up on average with little margin, as
/// the Pixel 6 Pro did overall (≈1.1×, §18), with a 61.6 s wait once.
const benchBorderlineRealTime = 1.0;

/// How fast, alone, the English recogniser must be to be worth switching
/// to. Beside translation SenseVoice fell from 10× to 2–3.5× on a Pixel 6
/// Pro (to 1/3–1/5, noisy-speech §18); a recogniser at 5× alone would then
/// be about 1–1.7×, still ahead of playback. Parakeet was 8× alone on a
/// Pixel 4 XL (§17), which passes.
const benchEnglishMinSpeed = 5.0;

/// Resident memory a translation model needs while it runs, in MB, beside
/// the recogniser — for the memory advice when the test itself could not
/// measure it. Gemma: VmHWM 2.5 GB on a Pixel 4 XL, mostly the mapped model
/// file (translation-bench, "Gemma 4 E2B 在手机上"). Hy-MT2: 383 MB anonymous
/// plus its 1.1 GB file mapped (same doc, 内存).
const benchTranslationResidentMb = {
  'gemma-4-e2b-it-q4_0': 2500,
  'hy-mt2-1.8b-q4_k_m': 1500,
};

/// Resident memory of the recogniser: SenseVoice peaked at 415 MB alone on
/// a Pixel 4 XL (translation-bench, 与 SenseVoice 同驻).
const benchAsrResidentMb = 400;

/// What the English recogniser adds: about 0.8 GB (1.3 GB peak with it on a
/// Pixel 4 XL, noisy-speech §17; the models page says the same).
const benchEnglishResidentMb = 800;

/// How fast a model read its prompt and wrote its reply, from
/// LlamaTranslationEngine.lastStats: reading is up to the first piece of
/// the reply, writing is the rest — the split the event log uses
/// (translation_session.dart, _logUnitStats).
class BenchTokenRates {
  const BenchTokenRates({
    required this.promptTokens,
    required this.replyTokens,
    required this.firstMs,
    required this.totalMs,
  });

  final int promptTokens;
  final int replyTokens;
  final int firstMs;
  final int totalMs;

  /// Prompt tokens a second, or null if nothing was timed.
  double? get promptPerSecond =>
      firstMs <= 0 || promptTokens <= 0 ? null : promptTokens * 1000 / firstMs;

  /// Reply tokens a second, or null when the reply was cut before any of it
  /// could be timed (the window closed while the prompt was still read).
  double? get replyPerSecond {
    final ms = totalMs - firstMs;
    return ms <= 0 || replyTokens <= 0 ? null : replyTokens * 1000 / ms;
  }

  /// Media-seconds translated per second of wall time; see
  /// [benchRealTime]. Null when the reply could not be timed.
  double? get realTime => switch ((promptPerSecond, replyPerSecond)) {
    (final p?, final r?) => benchRealTime(prompt: p, reply: r),
    _ => null,
  };

  /// An upper bound when [realTime] is null: reading the prompt alone
  /// takes this long, whatever the reply's pace.
  double? get realTimeCeiling => switch (promptPerSecond) {
    final p? => p / benchPromptTokensPerMediaSecond,
    null => null,
  };

  Map<String, Object?> toJson() => {
    'promptTokens': promptTokens,
    'replyTokens': replyTokens,
    'firstMs': firstMs,
    'totalMs': totalMs,
  };

  static BenchTokenRates? fromJson(Object? json) => switch (json) {
    {
      'promptTokens': final int promptTokens,
      'replyTokens': final int replyTokens,
      'firstMs': final int firstMs,
      'totalMs': final int totalMs,
    } =>
      BenchTokenRates(
        promptTokens: promptTokens,
        replyTokens: replyTokens,
        firstMs: firstMs,
        totalMs: totalMs,
      ),
    _ => null,
  };
}

/// Media-seconds of speech translated per second, at [prompt] and [reply]
/// tokens a second: one media-second costs 4 prompt tokens to read and 3 to
/// write (noisy-speech §18.1), so 1 / (4/prompt + 3/reply).
///
/// Pixel 6 Pro alone (15 / 9 tok/s) gives 1.67×, which §18.1 quotes as about
/// 1.7×. Its page measurements (9.1 / 2.9 → 0.57×, 9.8 / 5.8 → 1.31×) are
/// wall time over media time and come out 0.68× and 1.08× by this formula:
/// the per-unit token counts varied around the 4 + 3 average, so the two
/// agree only roughly.
double benchRealTime({required double prompt, required double reply}) =>
    1 /
    (benchPromptTokensPerMediaSecond / prompt +
        benchReplyTokensPerMediaSecond / reply);

/// One recogniser's speed: [mediaSeconds] of the clip decoded in [wallMs].
class BenchAsrSpeed {
  const BenchAsrSpeed({
    required this.mediaSeconds,
    required this.wallMs,
    this.loadMs,
  });

  final double mediaSeconds;
  final int wallMs;

  /// How long the recogniser took to load; null beside translation, where
  /// it was already loaded.
  final int? loadMs;

  /// Times real time; null if nothing was decoded.
  double? get speed =>
      wallMs <= 0 || mediaSeconds <= 0 ? null : mediaSeconds * 1000 / wallMs;

  Map<String, Object?> toJson() => {
    'mediaSeconds': mediaSeconds,
    'wallMs': wallMs,
    'loadMs': ?loadMs,
    'speed': speed,
  };

  static BenchAsrSpeed? fromJson(Object? json) => switch (json) {
    {'mediaSeconds': final num seconds, 'wallMs': final int wallMs} =>
      BenchAsrSpeed(
        mediaSeconds: seconds.toDouble(),
        wallMs: wallMs,
        loadMs: (json as Map)['loadMs'] as int?,
      ),
    _ => null,
  };
}

/// One translation model's measurements.
class BenchTranslation {
  const BenchTranslation({
    required this.modelId,
    required this.label,
    this.loadMs,
    this.alone,
    this.concurrent,
    this.asrBeside,
    this.error,
  });

  /// The catalog id (TranslationModelCatalog), or the file name of a model
  /// given to the self-test directly.
  final String modelId;
  final String label;
  final int? loadMs;

  /// The model on its own.
  final BenchTokenRates? alone;

  /// The same line while SenseVoice decodes the clip over and over: what
  /// real use looks like while the transcript races ahead.
  final BenchTokenRates? concurrent;

  /// SenseVoice's own speed meanwhile.
  final BenchAsrSpeed? asrBeside;
  final String? error;

  /// What the advice is read from: the concurrent real-time factor, or,
  /// when the reply could not be timed, the ceiling the prompt alone sets.
  ({double value, bool ceiling})? get concurrentRealTime =>
      switch (concurrent) {
        null => null,
        final c => switch ((c.realTime, c.realTimeCeiling)) {
          (final v?, _) => (value: v, ceiling: false),
          (null, final v?) => (value: v, ceiling: true),
          _ => null,
        },
      };

  BenchRating? get rating => switch (concurrentRealTime) {
    null => null,
    (value: final v, ceiling: _) when v < benchBorderlineRealTime =>
      BenchRating.tooSlow,
    // only a ceiling: at most this fast, so not known to be comfortable
    (value: _, ceiling: true) => BenchRating.borderline,
    (value: final v, ceiling: false) when v < benchComfortableRealTime =>
      BenchRating.borderline,
    _ => BenchRating.comfortable,
  };

  Map<String, Object?> toJson() => {
    'modelId': modelId,
    'label': label,
    'loadMs': ?loadMs,
    'alone': ?alone?.toJson(),
    'concurrent': ?concurrent?.toJson(),
    'asrBeside': ?asrBeside?.toJson(),
    'error': ?error,
    // derived, for whoever reads the self-test's JSON
    'aloneRealTime': alone?.realTime,
    'concurrentRealTime': concurrentRealTime?.value,
    'rating': rating?.name,
  };

  static BenchTranslation? fromJson(Object? json) => switch (json) {
    {'modelId': final String id, 'label': final String label} =>
      BenchTranslation(
        modelId: id,
        label: label,
        loadMs: (json as Map)['loadMs'] as int?,
        alone: BenchTokenRates.fromJson(json['alone']),
        concurrent: BenchTokenRates.fromJson(json['concurrent']),
        asrBeside: BenchAsrSpeed.fromJson(json['asrBeside']),
        error: json['error'] as String?,
      ),
    _ => null,
  };
}

enum BenchRating { comfortable, borderline, tooSlow }

/// Memory seen during the test, in MB; any of it may be unknown on a
/// platform with no way to read it.
class BenchMemory {
  const BenchMemory({
    this.totalMb,
    this.availableAtStartMb,
    this.minAvailableMb,
    this.rssAtStartMb,
    this.peakRssMb,
    this.pressure = false,
  });

  final int? totalMb;

  /// Available before anything was loaded: what the models have to fit in.
  final int? availableAtStartMb;
  final int? minAvailableMb;
  final int? rssAtStartMb;

  /// The app's own peak while the models ran.
  final int? peakRssMb;

  /// Whether the system warned of low memory during the test (which stops
  /// it).
  final bool pressure;

  /// What the models took, as the app's resident memory grew.
  int? get grownMb => switch ((rssAtStartMb, peakRssMb)) {
    (final start?, final peak?) when peak >= start => peak - start,
    _ => null,
  };

  Map<String, Object?> toJson() => {
    'totalMb': ?totalMb,
    'availableAtStartMb': ?availableAtStartMb,
    'minAvailableMb': ?minAvailableMb,
    'rssAtStartMb': ?rssAtStartMb,
    'peakRssMb': ?peakRssMb,
    'pressure': pressure,
  };

  static BenchMemory fromJson(Object? json) => switch (json) {
    final Map map => BenchMemory(
      totalMb: map['totalMb'] as int?,
      availableAtStartMb: map['availableAtStartMb'] as int?,
      minAvailableMb: map['minAvailableMb'] as int?,
      rssAtStartMb: map['rssAtStartMb'] as int?,
      peakRssMb: map['peakRssMb'] as int?,
      pressure: map['pressure'] == true,
    ),
    _ => const BenchMemory(),
  };
}

/// Everything one run of the test found.
class ModelBenchResult {
  const ModelBenchResult({
    required this.at,
    required this.platform,
    required this.cores,
    required this.asrThreads,
    required this.llamaThreads,
    required this.repacks,
    this.clipSeconds,
    this.senseVoice,
    this.english,
    this.englishInstalled = false,
    this.asrInstalled = true,
    this.translationSupported = true,
    this.translations = const [],
    this.notInstalled = const [],
    this.memory = const BenchMemory(),
    this.interrupted,
    this.error,
  });

  final DateTime at;
  final String platform;
  final int cores;
  final int asrThreads;

  /// 0: llama.cpp picks (desktops).
  final int llamaThreads;

  /// Whether llama.cpp repacked the weights (LlamaTranslationEngine.repacks).
  final bool repacks;
  final double? clipSeconds;
  final BenchAsrSpeed? senseVoice;
  final BenchAsrSpeed? english;
  final bool englishInstalled;
  final bool asrInstalled;
  final bool translationSupported;
  final List<BenchTranslation> translations;

  /// Translation models (catalog labels) not installed, so not measured.
  final List<String> notInstalled;
  final BenchMemory memory;

  /// Why the test stopped before the end (cancelled, memory, background).
  final String? interrupted;
  final String? error;

  bool get complete => interrupted == null && error == null;

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'platform': platform,
    'cores': cores,
    'asrThreads': asrThreads,
    'llamaThreads': llamaThreads,
    'repacks': repacks,
    'clipSeconds': ?clipSeconds,
    'senseVoice': ?senseVoice?.toJson(),
    'english': ?english?.toJson(),
    'englishInstalled': englishInstalled,
    'asrInstalled': asrInstalled,
    'translationSupported': translationSupported,
    'translations': [for (final t in translations) t.toJson()],
    'notInstalled': notInstalled,
    'memory': memory.toJson(),
    'interrupted': ?interrupted,
    'error': ?error,
  };

  static ModelBenchResult? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    if (at == null) return null;
    try {
      return ModelBenchResult(
        at: at,
        platform: json['platform'] as String? ?? '',
        cores: json['cores'] as int? ?? 0,
        asrThreads: json['asrThreads'] as int? ?? 0,
        llamaThreads: json['llamaThreads'] as int? ?? 0,
        repacks: json['repacks'] == true,
        clipSeconds: (json['clipSeconds'] as num?)?.toDouble(),
        senseVoice: BenchAsrSpeed.fromJson(json['senseVoice']),
        english: BenchAsrSpeed.fromJson(json['english']),
        englishInstalled: json['englishInstalled'] == true,
        asrInstalled: json['asrInstalled'] != false,
        translationSupported: json['translationSupported'] != false,
        translations: [
          for (final t in json['translations'] as List? ?? const [])
            ?BenchTranslation.fromJson(t),
        ],
        notInstalled: [
          for (final n in json['notInstalled'] as List? ?? const [])
            if (n is String) n,
        ],
        memory: BenchMemory.fromJson(json['memory']),
        interrupted: json['interrupted'] as String?,
        error: json['error'] as String?,
      );
    } catch (_) {
      // a result stored by another version, in a shape this one does not
      // read: as if there were none
      return null;
    }
  }
}

enum BenchAdviceLevel { good, warn, bad, info }

typedef BenchAdvice = ({BenchAdviceLevel level, String text});

String _x(double v) => '${v.toStringAsFixed(v < 10 ? 1 : 0)} 倍';

/// The catalog ids, repeated here so this file needs nothing native.
const _gemmaId = 'gemma-4-e2b-it-q4_0';
const _hyId = 'hy-mt2-1.8b-q4_k_m';

/// The advice lines, in the order shown: which translation model, whether
/// the English model is worth it, whether translation keeps up while
/// transcribing, and memory. Nothing here changes a setting.
List<BenchAdvice> benchAdvice(ModelBenchResult r) {
  final out = <BenchAdvice>[];
  if (r.error case final error?) {
    out.add((level: BenchAdviceLevel.bad, text: error));
    return out;
  }
  if (r.interrupted case final why?) {
    out.add((level: BenchAdviceLevel.info, text: '测试未完成：$why'));
  }
  if (!r.asrInstalled) {
    // translation is timed beside transcription, so without the recogniser
    // there is nothing to measure it against
    out.add((
      level: BenchAdviceLevel.info,
      text: '语音转录模型未下载，无法测试；翻译要和转录一起测，也需要先下载它。',
    ));
    return out;
  }

  // --- which translation model
  final measured = [
    for (final t in r.translations)
      if (t.rating != null) t,
  ];
  BenchTranslation? byId(String id) =>
      measured.where((t) => t.modelId == id).firstOrNull;
  final gemma = byId(_gemmaId);
  final hy = byId(_hyId);
  // Gemma first when it keeps up: it scored best (translation-bench,
  // decision 1C); Hy-MT2 when only it does; otherwise the faster one
  final comfortable = [
    ?gemma,
    ?hy,
    ...measured.where((t) => t != gemma && t != hy),
  ].where((t) => t.rating == BenchRating.comfortable).firstOrNull;
  final fastest = measured.isEmpty
      ? null
      : measured.reduce(
          (a, b) => a.concurrentRealTime!.value >= b.concurrentRealTime!.value
              ? a
              : b,
        );
  String rt(BenchTranslation t) {
    final v = t.concurrentRealTime!;
    return '${v.ceiling ? '至多' : '约 '}${_x(v.value)}实时';
  }

  if (!r.translationSupported) {
    out.add((
      level: BenchAdviceLevel.info,
      text: '翻译：本机（32 位）不支持在设备上翻译。',
    ));
  } else if (measured.isEmpty) {
    if (r.translations.isEmpty && r.interrupted == null) {
      out.add((
        level: BenchAdviceLevel.info,
        text: '翻译：没有已下载的翻译模型，无法测试。下载后可再测。',
      ));
    }
  } else if (comfortable != null) {
    final other = comfortable == gemma ? null : gemma;
    out.add((
      level: BenchAdviceLevel.good,
      text: other == null
          ? '翻译：用 ${comfortable.label}。边转录边翻译${rt(comfortable)}，跟得上。'
                '${comfortable.modelId == _hyId && !r.translations.any((t) => t.modelId == _gemmaId) ? 'Gemma（推荐）未下载，未测。' : ''}'
          : '翻译：用 ${comfortable.label}。边转录边翻译${rt(comfortable)}；'
                'Gemma ${rt(other)}，偏慢。',
    ));
  } else if (fastest!.rating == BenchRating.borderline) {
    out.add((
      level: BenchAdviceLevel.warn,
      text:
          '翻译：可以用 ${fastest.label}，但余量小（${rt(fastest)}），'
          '偶尔要等译文。${_tryHy(r, fastest)}',
    ));
  } else {
    out.add((
      level: BenchAdviceLevel.bad,
      text:
          '翻译：本机太慢（${fastest.label} ${rt(fastest)}），'
          '建议只转录不翻译。${_tryHy(r, fastest)}',
    ));
  }

  // --- the English model
  final englishSpeed = r.english?.speed;
  if (!r.englishInstalled) {
    out.add((level: BenchAdviceLevel.info, text: '英语识别模型未下载，未测试。'));
  } else if (englishSpeed == null) {
    // installed but not measured: interrupted, or it failed to load
  } else if (englishSpeed < benchEnglishMinSpeed) {
    out.add((
      level: BenchAdviceLevel.warn,
      text:
          '英语模型：本机偏慢（约 ${_x(englishSpeed)}实时），边看边转录可能跟不上，'
          '可在设置中关闭「英语使用专用模型」。',
    ));
  } else if (fastest != null && fastest.rating != BenchRating.comfortable) {
    // translation beside SenseVoice is already short of room; the English
    // model computes 2–3× as much (the models page's own figure)
    out.add((
      level: BenchAdviceLevel.warn,
      text:
          '英语模型：识别够快（约 ${_x(englishSpeed)}实时），但计算量约为默认模型的 '
          '2–3 倍，会让翻译更慢；英语视频要翻译时，可关闭「英语使用专用模型」。',
    ));
  } else {
    out.add((
      level: BenchAdviceLevel.good,
      text: '英语模型：值得用，本机约 ${_x(englishSpeed)}实时，英语视频识别更准确。',
    ));
  }

  // --- keeping up while transcribing
  if (fastest != null && fastest.rating == BenchRating.tooSlow) {
    final alone = fastest.alone?.realTime;
    out.add((
      level: BenchAdviceLevel.warn,
      text: alone != null && alone >= benchBorderlineRealTime
          ? '注意：转录进行时翻译跟不上播放；转录跑完后会快一些'
                '（单独约 ${_x(alone)}实时），开头可能要等译文。'
          : '注意：转录进行时翻译跟不上播放，要等译文。',
    ));
  }

  // --- memory
  if (_memoryShort(r) case (need: final need, have: final have)?) {
    // a phone's low-memory killer takes background apps, then this one
    // (model_guard.dart; seen on a 6 GB Pixel 4 XL, translation-bench); a
    // desktop pages to disk instead and slows down
    final phone = r.platform == 'android' || r.platform == 'ios';
    out.add((
      level: phone ? BenchAdviceLevel.bad : BenchAdviceLevel.warn,
      text:
          '内存：测试前可用约 ${_gb(have)}，同时运行转录和翻译约需 ${_gb(need)}，'
          '${phone ? '可能导致其他后台应用被关闭，甚至本应用被系统结束。' : '系统可能要用硬盘换页，明显变慢；可先关闭占内存的程序。'}',
    ));
  } else if (r.memory.pressure) {
    out.add((
      level: BenchAdviceLevel.bad,
      text: '内存：测试中系统报告内存不足，同时运行转录和翻译可能不稳定。',
    ));
  }
  return out;
}

String _gb(int mb) => '${(mb / 1024).toStringAsFixed(1)} GB';

/// Hy-MT2 as something to try, when it was not measured: no number, since
/// none was measured here (see ModelBench on why there is no estimate).
String _tryHy(ModelBenchResult r, BenchTranslation fastest) =>
    fastest.modelId == _gemmaId &&
        !r.translations.any((t) => t.modelId == _hyId)
    ? '也可下载 Hy-MT2（体积小）后再测。'
    : '';

/// Whether what the test loaded — or would load — does not fit in what was
/// available before it started: need and have, in MB, or null if it fits
/// or is not known. What it measured is used when it has it (the app's
/// resident memory grew by that much); otherwise the resident sizes on
/// record for the largest translation model tested.
({int need, int have})? _memoryShort(ModelBenchResult r) {
  final have = r.memory.availableAtStartMb;
  if (have == null || r.translations.isEmpty) return null;
  final estimate =
      benchAsrResidentMb +
      (r.englishInstalled ? benchEnglishResidentMb : 0) +
      r.translations
          .map((t) => benchTranslationResidentMb[t.modelId] ?? 0)
          .fold<int>(0, (a, b) => a > b ? a : b);
  // the measured growth undercounts a model file's pages the run did not
  // touch, so the larger of the two
  final grown = r.memory.grownMb ?? 0;
  final need = grown > estimate ? grown : estimate;
  return need > have ? (need: need, have: have) : null;
}

String _tok(double? v) => v == null ? '–' : v.toStringAsFixed(1);

String _rates(BenchTokenRates? r) {
  if (r == null) return '未测';
  final real = r.realTime;
  final ceiling = r.realTimeCeiling;
  final tail = real != null
      ? ' → 约 ${_x(real)}实时'
      : ceiling != null
      ? ' → 至多 ${_x(ceiling)}实时（未测到生成）'
      : '';
  return '读入 ${_tok(r.promptPerSecond)} · 生成 ${_tok(r.replyPerSecond)} '
      'tok/s$tail';
}

String _seconds(int? ms) => ms == null ? '–' : (ms / 1000).toStringAsFixed(1);

String _asr(BenchAsrSpeed? s) => switch (s?.speed) {
  final v? =>
    '${_x(v)}实时${s!.loadMs == null ? '' : '（载入 ${_seconds(s.loadMs)} s）'}',
  null => '未测',
};

/// The measured numbers, as label and value, for the 详细数据 section.
List<(String, String)> benchDetails(ModelBenchResult r) {
  final m = r.memory;
  String mb(int? v) => v == null ? '–' : _gb(v);
  return [
    (
      '设备',
      '${r.platform} · ${r.cores} 核 · 转录 ${r.asrThreads} 线程 · 翻译 '
          '${r.llamaThreads == 0 ? '自动' : '${r.llamaThreads} '}线程'
          '${r.repacks ? ' · 权重重排' : ''}',
    ),
    if (r.clipSeconds case final s?) ('语音样本', '${s.toStringAsFixed(1)} s 英语朗读'),
    ('语音转录（SenseVoice）', r.asrInstalled ? _asr(r.senseVoice) : '未下载'),
    ('英语识别（Parakeet）', r.englishInstalled ? _asr(r.english) : '未下载'),
    for (final t in r.translations) ...[
      (
        t.label,
        t.error != null ? '出错：${t.error}' : '载入 ${_seconds(t.loadMs)} s',
      ),
      ('　单独', _rates(t.alone)),
      ('　同时转录', _rates(t.concurrent)),
      if (t.asrBeside != null) ('　此时转录', _asr(t.asrBeside)),
    ],
    for (final n in r.notInstalled) (n, '未下载，未测'),
    (
      '内存',
      '共 ${mb(m.totalMb)} · 测试前可用 ${mb(m.availableAtStartMb)} · '
          '最低可用 ${mb(m.minAvailableMb)} · 本应用峰值 ${mb(m.peakRssMb)}',
    ),
    (
      '算法',
      '每秒语音翻译约需读入 ${benchPromptTokensPerMediaSecond.toInt()} 个、'
          '生成 ${benchReplyTokensPerMediaSecond.toInt()} 个 token；'
          '同时转录时 ≥$benchComfortableRealTime 倍实时为宽裕，'
          '$benchBorderlineRealTime–$benchComfortableRealTime 倍为勉强，'
          '更低为跟不上',
    ),
  ];
}
