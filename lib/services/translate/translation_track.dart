/// LibrePili: a translation as a player page sees it — a subtitle track to
/// publish, a moment it is first worth showing, and a failure to report.
///
/// Page-independent: the bilibili page inserts the track into its list, the
/// YouTube page (which has no list) shows it directly. Both hand this a way
/// to read the playhead and a way to publish, and it decides when.
library;

import 'dart:async';

import 'package:PiliPlus/services/asr/asr_publish.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/translate/translation_layout.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// Whether to hand the player a rebuilt translation track.
///
/// A rebuild is a reload, and a reload blinks the line on screen (see
/// [shouldPublishAsr]), so it is only worth it when the viewer is about to
/// reach something the published track lacks: a stretch still marked as
/// waiting that has since been translated, or speech past its end.
///
/// [publishedSettled] and [settled] are where the translated (or failed)
/// stretch starting at the playhead ends in the published track and in the
/// current one; [publishedEnd] and [end] where each track's last line ends.
@visibleForTesting
bool shouldPublishTranslation({
  required double position,
  required double publishedSettled,
  required double settled,
  required double publishedEnd,
  required double end,
  required bool isFirst,
  required bool isFinal,
}) {
  if (isFirst || isFinal) return true;
  final lead = asrPublishLead.inMilliseconds / 1000;
  final gainsTranslation =
      publishedSettled - position < lead && settled > publishedSettled + 0.01;
  final gainsSpeech =
      publishedEnd - position < lead && end > publishedEnd + 0.01;
  return gainsTranslation || gainsSpeech;
}

class TranslationTrack {
  TranslationTrack({
    required this.position,
    required this.onPublish,
    required this.onReady,
    required this.onFailed,
  });

  /// Where playback is, in seconds.
  final double Function() position;

  /// Hands the player the track. [first] is the first time for this run.
  final void Function(String vtt, {required bool first}) onPublish;

  /// The translation has something to show, or never will: the page may
  /// stop waiting for it.
  final VoidCallback onReady;

  final ValueChanged<String> onFailed;

  final session = Rxn<TranslationSession>();

  Timer? _refresh;
  Worker? _revisionWorker;
  Worker? _stateWorker;
  StreamSubscription<void>? _cueSub;
  var _readySent = false;

  /// Never two reloads closer than this, the pace a transcript gets.
  ///
  /// Publishing on every translated unit reloaded the track eight times in
  /// the first thirteen seconds of a real run — each one a blink of the
  /// line on screen — while the transcript was still less than the lead
  /// ahead of the playhead and so every check passed.
  static const _minInterval = Duration(seconds: 5);
  DateTime? _publishedAt;

  /// A waiting line this close to the playhead is replaced at once.
  static const _urgent = 3.0;

  /// Units that had a result when the track was last published.
  Set<int> _publishedResults = {};
  double _publishedEnd = -1;
  var _published = false;

  bool get isRunning => session.value?.isRunning ?? false;

  /// Starts that have not attached their session yet.
  var _starting = 0;

  /// Bumped by every [stop], so a start that a stop overtook can tell.
  var _generation = 0;

  /// A translation exists or is on its way. [session] alone is only set
  /// after the service has stopped its predecessor and started this one, and
  /// a page asked again in between (every recogniser progress update asks)
  /// would start a second.
  bool get isActive => _starting > 0 || session.value != null;

  /// Translates a transcript as it is being written.
  Future<void> start(AsrSession asr) => _startWith(
    () => TranslationService.to.start(asr: asr, position: position),
    onAttach: (current) => _cueSub = asr.cues.listen((_) => current.poke()),
  );

  /// Translates a video's own captions.
  Future<void> startCaptions(List<AsrCue> cues) => _startWith(
    () => TranslationService.to.startCaptions(cues: cues, position: position),
  );

  Future<void> _startWith(
    Future<TranslationSession> Function() create, {
    void Function(TranslationSession current)? onAttach,
  }) async {
    _starting++;
    // taken before anything is awaited: a stop that lands while the one
    // before this is being torn down must still count
    final generation = ++_generation;
    try {
      await _detach();
      if (generation != _generation) return;
      final current = await create();
      if (generation != _generation) {
        // stopped, or started again, while this one was being set up
        await TranslationService.to.stop(only: current);
        return;
      }
      onAttach?.call(current);
      _attach(current);
    } finally {
      _starting--;
    }
  }

  void _attach(TranslationSession current) {
    session.value = current;
    _revisionWorker = ever(current.revision, (_) {
      // Ready once there is a stretch ahead to watch, not at the first line:
      // released at one unit, a real run reached the next one — still
      // waiting — within seconds (2 s of "正在翻译" on screen in English,
      // 7 s in Japanese). Published at that moment; after it the timer
      // paces the reloads.
      if (!_readySent && _hasLead(current)) {
        _ready();
        publish();
      } else if (_readySent) {
        // a line the viewer is about to reach may have just been translated
        publish();
      }
    });
    void onState(TranslationState state) {
      switch (state.stage) {
        case TranslationStage.done:
          // a short or silent video can finish below the lead, or with
          // nothing to show at all
          _ready();
          publish(isFinal: true);
        case TranslationStage.failed:
          _ready();
          onFailed(state.message ?? '');
        case _:
          break;
      }
    }

    _stateWorker = ever(current.state, onState);
    // an empty transcript is done before the service even hands the session
    // over, and a worker only hears later changes
    onState(current.state.value);
    // the playhead moves without telling anyone; check on a timer too
    final started = DateTime.now();
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) {
      // a phone too slow to build the lead in time shows what it has, when
      // the page would have stopped waiting anyway
      if (!_readySent && DateTime.now().difference(started) >= _readyCap) {
        _ready();
      }
      if (_readySent) publish();
    });
  }

  /// How much translated speech must lie ahead before the page stops
  /// waiting: enough that the next units are done by the time it is watched.
  static const _readyLead = 10.0;

  /// The page's own cap on waiting (its loading gate).
  static const _readyCap = Duration(seconds: 30);

  bool _hasLead(TranslationSession current) {
    final now = position();
    if (current.settledFrom(now) - now >= _readyLead) return true;
    // a short video can be settled end to end below the lead
    return current.state.value.stage == TranslationStage.done ||
        (current.units.isNotEmpty &&
            current.results.length == current.units.length &&
            current.transcript.complete());
  }

  void _ready() {
    if (_readySent) return;
    _readySent = true;
    onReady();
  }

  /// Rebuilds and hands over the track if the viewer would gain from it.
  void publish({bool isFinal = false}) {
    final current = session.value;
    if (current == null) return;
    final cues = current.cues(
      display: Pref.translateDual
          ? TranslationDisplay.dual
          : TranslationDisplay.translated,
    );
    if (cues.isEmpty) return;
    final now = position();
    final at = _publishedAt;
    final publishedSettled = _settledIn(current, _publishedResults, now);
    final settled = current.settledFrom(now);
    // the published track shows a waiting line within moments, and it has
    // been translated since: one blink beats reading the untranslated line
    final urgent =
        publishedSettled - now < _urgent && settled > publishedSettled + 0.01;
    if (!isFinal &&
        !urgent &&
        at != null &&
        DateTime.now().difference(at) < _minInterval) {
      return;
    }
    if (!shouldPublishTranslation(
      position: now,
      publishedSettled: publishedSettled,
      settled: settled,
      publishedEnd: _publishedEnd,
      end: cues.last.to,
      isFirst: !_published,
      isFinal: isFinal,
    )) {
      return;
    }
    final first = !_published;
    _published = true;
    _publishedAt = DateTime.now();
    _publishedResults = current.results.keys.toSet();
    _publishedEnd = cues.last.to;
    onPublish(cues.toVtt(), first: first);
  }

  /// [TranslationSession.settledFrom] as it stood for [results].
  static double _settledIn(
    TranslationSession current,
    Set<int> results,
    double at,
  ) {
    var end = at;
    for (var i = 0; i < current.units.length; i++) {
      final unit = current.units[i];
      if (unit.to < at) continue;
      if (!results.contains(i)) break;
      end = unit.to;
    }
    return end;
  }

  Future<void> stop() async {
    _generation++;
    await _detach();
  }

  Future<void> _detach() async {
    _refresh?.cancel();
    _refresh = null;
    _revisionWorker?.dispose();
    _revisionWorker = null;
    _stateWorker?.dispose();
    _stateWorker = null;
    await _cueSub?.cancel();
    _cueSub = null;
    _readySent = false;
    _published = false;
    _publishedResults = {};
    _publishedEnd = -1;
    _publishedAt = null;
    final had = session.value;
    session.value = null;
    // only this track's own: the service may be running another page's by now
    if (had != null && Get.isRegistered<TranslationService>()) {
      await TranslationService.to.stop(only: had);
    }
  }
}
