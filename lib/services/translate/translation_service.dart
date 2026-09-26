/// LibrePili: one translation at a time, and the model it runs on.
///
/// A translation is of a transcript ([AsrSession]) or of a video's own
/// captions, and is tied to the page that started it. Only one runs at once
/// — a second model resident alongside the first is up to 2.8 GB of mapped
/// file the phone does not have.
///
/// A page covered by another video's keeps its translation, paused: the one
/// started over it takes the model, and the paused one takes it back when
/// its page has the player again (see [TranslationSession.park]).
library;

import 'dart:async';
import 'dart:collection' show Queue;
import 'dart:ffi' show IntPtr, sizeOf;
import 'dart:io';

import 'package:PiliPlus/models/common/translate_mode.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/services/translate/caption_source.dart';
import 'package:PiliPlus/services/translate/chinese_convert.dart';
import 'package:PiliPlus/services/translate/llama_engine.dart';
import 'package:PiliPlus/services/translate/translation_engine.dart';
import 'package:PiliPlus/services/translate/translation_models.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

class TranslationService extends GetxService {
  static TranslationService get to => Get.find<TranslationService>();

  /// Whether translation can run here at all. llama.cpp is built only for
  /// 64-bit processes — the armeabi-v7a APK carries none of it — and a
  /// 32-bit process could not map a model of 1–3 GB anyway. Everything that
  /// offers translation, or starts it by itself, checks this.
  static final bool supported = sizeOf<IntPtr>() == 8;

  /// Same store as the recogniser's models, its own directory.
  final store = AsrModelStore(
    root: Directory(path.join(appSupportDirPath, 'translate')),
  );

  TranslationSession? _current;
  AsrCancelToken? _download;

  /// Short texts waiting to be translated (see [translateText]).
  final _extras = Queue<ExtraText>();

  /// A session kept for [_extras] alone, while no transcript's session can
  /// take them (see [_serveExtras]).
  TranslationSession? _extrasSession;

  /// Translations that gave the model up for another page's and wait for
  /// their own page to have the player again. None holds a model.
  final _parked = <TranslationSession>{};

  /// Starts run one after another. Two overlapping ones would each stop the
  /// other's predecessor and then both run, the loser with a model loaded
  /// that nothing refers to any more.
  Future<void> _starting = Future.value();

  /// Sessions stopped but still releasing their model. [stop] forgets a
  /// session before it is disposed, so a start must wait for this too, or it
  /// loads a second model while the first is still resident.
  Future<void> _disposing = Future.value();

  AsrModel get model => TranslationModelCatalog.byId(Pref.translateModel);

  bool get modelReady => store.isInstalled(model);

  int get downloadSize => modelReady ? 0 : model.totalSize;

  /// Starts asked for and not yet running: queued behind [_starting], or
  /// waiting for their predecessor to let go of its model.
  var _pending = 0;

  /// Bumped by a stop of everything — memory, the background, the model
  /// being deleted — so a start asked for before it does not go on to load
  /// the model after it. [_stopReason] is what that start reports.
  var _stops = 0;
  String? _stopReason;

  bool get isBusy => _pending > 0 || (_current?.isRunning ?? false);

  /// The language translations are made into unless another is asked for:
  /// the app's.
  String get target => AsrService.appLanguage;

  /// Whether a transcript in [spoken] needs translating into [into] (the
  /// app's language by default) at all.
  bool needed(String? spoken, {String? into}) =>
      spoken != null &&
      spoken.isNotEmpty &&
      // Chinese in Traditional characters is Chinese converted
      (into == traditionalChinese ||
          !AsrService.isSameMajorLanguage(spoken, into ?? target));

  /// Traditional Chinese: made from Chinese — the model's, or the speech's
  /// or captions' own — by conversion (see [S2twpConverter]).
  static const traditionalChinese = 'zh-Hant';

  /// Whether text in [from] becomes [into] by conversion alone.
  static bool convertsOnly(String? from, String into) =>
      into == traditionalChinese &&
      from != null &&
      AsrService.isSameMajorLanguage(from, 'zh');

  /// Whether the user chose automatic translation and it can run now.
  bool get shouldAutoTranslate =>
      supported &&
      Pref.translateAsked &&
      Pref.translateMode == TranslateMode.auto &&
      modelReady;

  /// Whether [spoken] should be translated without being asked.
  bool shouldAutoStart(String? spoken) => shouldAutoTranslate && needed(spoken);

  /// Starts translating [asr], replacing whatever was running.
  ///
  /// [position] is where playback is, in seconds: translation follows the
  /// viewer, not the recogniser.
  ///
  /// [ownsPlayer] tells whether the page asking still has the player (see
  /// [TranslationSession.ownsPlayer]).
  ///
  /// [into] is the language to translate into, the app's by default.
  Future<TranslationSession> start({
    required AsrSession asr,
    required double Function() position,
    bool Function()? ownsPlayer,
    String? into,
  }) => _start(
    transcriptView(
      segments: () => asr.segments,
      cues: () => asr.cues,
      complete: () => asr.state.value.stage == AsrStage.done,
    ),
    position,
    ownsPlayer,
    into ?? target,
    from: asr.state.value.language,
  );

  /// Starts translating a video's own captions, all known up front.
  ///
  /// [from] is the captions' language, when known.
  Future<TranslationSession> startCaptions({
    required List<AsrCue> cues,
    required double Function() position,
    bool Function()? ownsPlayer,
    String? into,
    String? from,
  }) {
    final units = buildCaptionUnits(cues);
    return _start(
      (units: () => units, cues: () => cues, complete: () => true),
      position,
      ownsPlayer,
      into ?? target,
      from: from,
    );
  }

  Future<TranslationSession> _start(
    TranscriptView transcript,
    double Function() position,
    bool Function()? ownsPlayer,
    String into, {
    String? from,
  }) {
    final stops = _stops;
    _pending++;
    final started = _starting.then(
      (_) => _startNow(transcript, position, ownsPlayer, into, from, stops),
    );
    _starting = started.then((_) {}, onError: (_) {});
    return started;
  }

  Future<TranslationSession> _startNow(
    TranscriptView transcript,
    double Function() position,
    bool Function()? ownsPlayer,
    String into,
    String? from,
    int stops,
  ) async {
    try {
      // the one this replaces belongs to a page this one's covers: it waits
      // for that page to be back rather than being stopped. A page starting
      // again stops its own first (see TranslationTrack).
      await _park();
      await _endExtrasSession();
      await _disposing;
      return _create(
        transcript,
        position,
        ownsPlayer,
        into,
        from: from,
        stopped: stops != _stops,
      );
    } finally {
      _pending--;
    }
  }

  /// Translates [text] into [into] (the app's language by default) with the
  /// same model as the subtitles, and without taking it from them: a
  /// translation of a transcript or captions under way does these in its
  /// gaps, with the viewer's lines first; with none under way a session is
  /// kept for them alone. Null when it failed.
  ///
  /// [tag] names who asked, for [dropTexts].
  Future<String?> translateText(String text, {String? into, Object? tag}) {
    into ??= target;
    final traditional = into == traditionalChinese;
    final done = Completer<String?>();
    _extras.add((
      text: text,
      // the model writes Chinese, and the conversion does the rest
      target: traditional ? 'zh' : into,
      tag: tag,
      done: done,
    ));
    _serveExtras();
    if (!traditional) return done.future;
    return done.future.then((result) async {
      if (result == null) return null;
      return (await S2twpConverter.load()).convert(result);
    });
  }

  /// Drops the texts [tag] asked for that are not translated yet: each one
  /// comes back null.
  void dropTexts(Object tag) {
    final dropped = _extras.where((e) => e.tag == tag).toList();
    _extras.removeWhere((e) => e.tag == tag);
    for (final extra in dropped) {
      if (!extra.done.isCompleted) extra.done.complete(null);
    }
  }

  bool _hasExtra() => _extras.isNotEmpty;

  ExtraText? _takeExtra() => _extras.isEmpty ? null : _extras.removeFirst();

  void _giveBack(ExtraText extra) {
    _extras.addFirst(extra);
    _serveExtras();
  }

  /// Gets [_extras] done: by the transcript's session when it has the model
  /// or will load it, otherwise by a session of their own. Never a second
  /// model: a session of their own starts only while no other can hold one,
  /// and a transcript's session taking the model back ends it first (see
  /// [_claim] and [_startNow]).
  void _serveExtras() {
    if (!supported || _extras.isEmpty) return;
    final current = _current;
    if (current != null && current.servesExtras) {
      current.poke();
      return;
    }
    // alive, not busy: one just started has not said so yet, and asking
    // "is it running" there started a second one — and a second model —
    // for the second text of a burst
    final own = _extrasSession;
    if (own != null && own.servesExtras) {
      own.poke();
      return;
    }
    // nothing about to start either: a start takes them over
    if (_pending > 0) return;
    final session = _extrasSession = TranslationSession(
      transcript: (
        units: () => const [],
        cues: () => const [],
        complete: () => true,
      ),
      position: () => 0,
      engine: debugEngine ?? _loader(),
      target: target,
      extrasOnly: true,
      linger: debugExtraLinger ?? extraLinger,
    );
    _wireExtras(session);
    session.start();
  }

  void _wireExtras(TranslationSession session) {
    if (session.modelFree) return;
    session
      ..hasExtra = _hasExtra
      ..takeExtra = _takeExtra
      ..giveBack = _giveBack;
  }

  /// Ends the session kept for texts alone, before another loads the model;
  /// what it had not done goes back in the queue for that one.
  Future<void> _endExtrasSession() async {
    final session = _extrasSession;
    _extrasSession = null;
    if (session == null) return;
    await _dispose(session);
  }

  /// Moves the current translation aside, once it has let go of the model.
  Future<void> _park() async {
    final session = _current;
    if (session == null) return;
    _current = null;
    _parked.add(session);
    _download?.cancel();
    _download = null;
    await session.park();
  }

  /// See [TranslationSession.claim]: a paused session gets the model back
  /// while no other is at work with it — the current one paused, finished or
  /// failed, and no start on its way.
  Future<bool> _claim(TranslationSession session) async {
    if (identical(_current, session)) {
      // about to load the model: a session kept for texts alone may hold
      // one — it ends, and this one takes its texts over. Only that one is
      // waited for, not [_disposing]: a stop of this session awaits its loop,
      // which is here, and waiting on the stop from inside it never ended
      await _endExtrasSession();
      return identical(_current, session);
    }
    if (!_parked.contains(session) || _pending > 0) return false;
    final holder = _current;
    if (holder != null) {
      final stage = holder.state.value.stage;
      final resting =
          stage == TranslationStage.paused ||
          stage == TranslationStage.done ||
          stage == TranslationStage.failed;
      if (!resting) return false;
      await _park();
      // another claim or start may have got in while that one let go
      if (_current != null || _pending > 0 || !_parked.contains(session)) {
        return false;
      }
    }
    _parked.remove(session);
    _current = session;
    await _endExtrasSession();
    await _disposing;
    return identical(_current, session);
  }

  TranslationSession _create(
    TranscriptView transcript,
    double Function() position,
    bool Function()? ownsPlayer,
    String into, {
    String? from,
    required bool stopped,
  }) {
    final traditional = into == traditionalChinese;
    final session = TranslationSession(
      transcript: transcript,
      position: position,
      engine: debugEngine ?? _loader(),
      // the model writes Chinese, and the conversion does the rest
      target: traditional ? 'zh' : into,
      convert: traditional
          ? () async => (await S2twpConverter.load()).convert
          : null,
      modelFree: convertsOnly(from, into),
      ownsPlayer: ownsPlayer,
    )..claim = _claim;
    _wireExtras(session);
    if (stopped) {
      // stopped before it began: nothing is loaded, and its page hears why
      // as it would have had it been running
      session.fail(_stopReason ?? '');
      return session;
    }
    _current = session;
    session.start();
    // a modelFree one cannot do them: they need a session of their own
    if (session.modelFree) _serveExtras();
    return session;
  }

  /// Loads the model chosen now, downloading it first if need be.
  Future<TranslationEngine> Function(ValueChanged<String> report) _loader() {
    // read once: a change of model in settings mid-start must not load one
    // file while checking and downloading another
    final model = this.model;
    final file = store.fileOf(model, model.files.first).path;
    return (report) async {
      if (!store.isInstalled(model)) {
        final token = _download = AsrCancelToken();
        await store.ensure(
          model,
          token: token,
          onProgress: (p) => report(
            p.verifying
                ? '校验模型'
                : '下载模型 ${p.total == 0 ? '' : '${(p.received * 100 ~/ p.total)}%'}',
          ),
        );
        _download = null;
      }
      report('加载模型');
      return LlamaTranslationEngine.load(file);
    };
  }

  /// Ends the current translation. With a [reason] it is marked failed first,
  /// so the page hears why (see [AsrService.stop]).
  ///
  /// With [only], nothing happens unless that is the current translation or
  /// a paused one: a page stopping its own must not stop another page's that
  /// replaced it.
  ///
  /// Without [only] it reaches starts not yet running as well, and waits
  /// until every stopped session has let go of the model file. Paused ones
  /// hold no model and are left to go on, unless [paused] — for the model
  /// being deleted, which they would load again.
  Future<void> stop({
    String? reason,
    TranslationSession? only,
    bool paused = false,
  }) async {
    if (only == null) {
      _stops++;
      _stopReason = reason;
    }
    if (only != null && _parked.remove(only)) {
      await _dispose(only);
      return;
    }
    if (only == null && paused) {
      final parked = _parked.toList();
      _parked.clear();
      for (final session in parked) {
        if (reason != null && session.isActive) session.fail(reason);
        _dispose(session);
      }
    }
    await _stop(reason: reason, only: only);
    if (only == null) {
      // memory, the background, the model deleted: the texts waiting stop
      // too, as failed
      await _endExtrasSession();
      final waiting = _extras.toList();
      _extras.clear();
      for (final extra in waiting) {
        if (!extra.done.isCompleted) extra.done.complete(null);
      }
    }
    // one replaced earlier may still have the file mapped, and the model
    // being deleted is one of the reasons to stop everything
    if (only == null) await _disposing;
  }

  Future<void> _stop({String? reason, TranslationSession? only}) async {
    final session = _current;
    if (only != null && session != only) return;
    _current = null;
    _download?.cancel();
    _download = null;
    if (session == null) return;
    if (reason != null && session.isActive) session.fail(reason);
    await _dispose(session);
  }

  Future<void> _dispose(TranslationSession session) {
    final disposed = session.dispose();
    final before = _disposing;
    _disposing = Future.wait([before, disposed]).then((_) {}, onError: (_) {});
    return disposed;
  }

  /// For the self-test (`--translate-model`): translations load [path]
  /// instead of the installed model — a phone test build has none of its
  /// own. Nothing else calls it.
  void useModelFile(String path) => debugEngine = (report) {
    report('加载模型');
    return LlamaTranslationEngine.load(path);
  };

  /// Stands in for loading the model, in tests.
  @visibleForTesting
  Future<TranslationEngine> Function(ValueChanged<String> report)? debugEngine;

  @visibleForTesting
  bool debugIsParked(TranslationSession session) => _parked.contains(session);

  @visibleForTesting
  TranslationSession? get debugCurrent => _current;

  @visibleForTesting
  TranslationSession? get debugExtrasSession => _extrasSession;

  @visibleForTesting
  Duration? debugExtraLinger;

  @visibleForTesting
  void debugAdopt(TranslationSession session) => _current = session;
}
