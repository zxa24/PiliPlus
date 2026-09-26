/// LibrePili: translating a transcript while it is still being written,
/// in the order the viewer will need it.
///
/// Scheduled by the playhead, not by the recogniser. Recognition runs
/// minutes ahead of playback; chasing it means translating as fast as it
/// recognises, while staying [translationLead] ahead of the viewer needs a
/// fraction of that — the difference between needing a flagship phone and
/// leaving a mid-range one half idle (research/translation-deliberation-
/// 2026-09-22.md). It also means a viewer who leaves after two minutes did
/// not pay for translating an hour.
///
/// A unit is translated once. A seek backwards finds the units behind it
/// untranslated and shows them as waiting until they come round.
library;

import 'dart:async';

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/translate/translation_engine.dart';
import 'package:PiliPlus/services/translate/translation_layout.dart';
import 'package:PiliPlus/services/translate/translation_unit.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// How far ahead of the playhead translation runs before it waits.
const translationLead = Duration(seconds: 120);

/// A unit that ended this long before the playhead is behind the viewer
/// and not worth translating until they come back to it.
const _behind = 2.0;

/// This many failures in a row means the engine is not coming back.
const _giveUpAfter = 3;

/// A short text translated in the gaps of a session: a comment
/// (research/comment-translation-design-2026-09-25.md, E1). [tag] is who
/// asked, so what it no longer needs can be dropped.
typedef ExtraText = ({
  String text,
  String target,
  Object? tag,
  Completer<String?> done,
});

/// How long a session kept only for [ExtraText]s holds the model after the
/// last one: a screen of comments arrives as a burst, the next page's a
/// little later, and loading the model again costs seconds.
const extraLinger = Duration(seconds: 15);

enum TranslationStage {
  idle,
  loading,
  translating,
  waiting,

  /// Its page is covered by another video's: the model is let go of, what is
  /// translated is kept, and it goes on from where the viewer is once the
  /// page has the player back.
  paused,
  done,
  failed,
}

class TranslationState {
  const TranslationState(this.stage, {this.message});
  final TranslationStage stage;
  final String? message;

  bool get isBusy =>
      stage == TranslationStage.loading ||
      stage == TranslationStage.translating ||
      stage == TranslationStage.waiting;

  bool get isPaused => stage == TranslationStage.paused;
}

/// What the session reads from the text it translates: a transcript still
/// being written, or a video's own captions.
typedef TranscriptView = ({
  /// The settled units so far, in time order. A unit once returned is
  /// returned again unchanged — never cut differently — though others may
  /// come before it as well as after.
  List<TranslationUnit> Function() units,

  /// The source lines not in a unit yet, in time order.
  List<AsrCue> Function() trailing,

  /// The stretches of media whose text is known (see TranscriptStore); text
  /// can still turn up in the gaps between them.
  List<TimeSpan> Function() covered,

  /// True once no more text is coming: the last unit is settled.
  bool Function() complete,

  /// The transcript is paused, not finished: far enough ahead of the
  /// viewer for now (AsrStage.standby).
  bool Function() resting,
});

/// Text known in full from the start: captions, or nothing at all.
TranscriptView fixedTranscript(
  List<TranslationUnit> units, {
  List<AsrCue> trailing = const [],
}) {
  final keyed = withUniqueKeys(units);
  return (
    units: () => keyed,
    trailing: () => trailing,
    covered: () => const [(from: double.negativeInfinity, to: double.infinity)],
    complete: () => true,
    resting: () => false,
  );
}

/// A transcript as a [TranscriptView]: units along its VAD segments, cut
/// within each run and never across two (research/chunked-transcription-
/// design-2026-09-25.md, 4.6). A run's newest segment settles when the run
/// is finished or [complete] says the transcript is.
TranscriptView transcriptView(
  TranscriptStore store, {
  required bool Function() complete,
  bool Function()? resting,
}) {
  ({List<TranslationUnit> units, List<AsrCue> trailing}) cut() {
    final units = <TranslationUnit>[];
    final trailing = <AsrCue>[];
    final done = complete();
    for (final run in store.runs) {
      final made = buildTranslationUnits(
        segments: run.segments,
        cues: run.cues,
        complete: done || run.finished,
      );
      units.addAll(made);
      // units are cut from the front of the run's cues, so the rest of
      // them is what the units have not taken. Not "starts after the last
      // unit's end": that unit's last cue can be held past the start of
      // the next segment's first one, which then went missing until its
      // own unit settled.
      var taken = 0;
      for (final unit in made) {
        taken += unit.cues.length;
      }
      trailing.addAll(run.cues.skip(taken));
    }
    // runs are in time order and do not overlap, so this is only a guard
    mergeSort(units, compare: (a, b) => a.from.compareTo(b.from));
    mergeSort(trailing, compare: (a, b) => a.from.compareTo(b.from));
    return (units: withUniqueKeys(units), trailing: trailing);
  }

  return (
    units: () => cut().units,
    trailing: () => cut().trailing,
    covered: () => store.covered,
    complete: complete,
    resting: resting ?? () => false,
  );
}

class TranslationSession {
  TranslationSession({
    required this.transcript,
    required this.position,
    required this.engine,
    required this.target,
    this.ownsPlayer,
    this.convert,
    this.modelFree = false,
    this.extrasOnly = false,
    this.linger = extraLinger,
  });

  /// How long a session [extrasOnly] holds the model after its last text.
  final Duration linger;

  /// A session with no transcript, kept for [ExtraText]s alone.
  final bool extrasOnly;

  /// Where [ExtraText]s come from (the service's queue): whether one is
  /// waiting, the next one, and one handed back unfinished.
  bool Function()? hasExtra;
  ExtraText? Function()? takeExtra;
  void Function(ExtraText extra)? giveBack;
  DateTime _lastExtra = DateTime.now();

  final TranscriptView transcript;

  /// Where playback is, in seconds.
  final double Function() position;

  /// Loads the model — downloading it first if need be — reporting what it
  /// is doing through the callback. Called once, when there is first
  /// something to do.
  final Future<TranslationEngine> Function(ValueChanged<String> report) engine;

  /// The language to translate into, e.g. `zh`.
  final String target;

  /// Applied to each translation before it is kept: Traditional Chinese is
  /// the model's Chinese, converted (see S2twpConverter). Loaded when first
  /// needed.
  final Future<String Function(String)> Function()? convert;
  String Function(String)? _converter;

  /// No model at all: each unit is only [convert]ed — Chinese speech or
  /// captions shown in Traditional Chinese.
  final bool modelFree;

  /// Whether the page this translates for still has the player, set by the
  /// page's track. The player is one for the whole app: while another video
  /// plays on it, [position] reads that video's playhead, and the model is
  /// not loaded to translate this one's speech against it — least of all by
  /// a session done for as far as the viewer went, re-armed by that other
  /// video's playhead sitting before what was skipped.
  bool Function()? ownsPlayer;

  /// Asked before the model is loaded, by the service running one
  /// translation at a time: whether this one may load it now. A session
  /// paused under another page's gets its turn back here.
  Future<bool> Function(TranslationSession session)? claim;

  final state = const TranslationState(TranslationStage.idle).obs;

  /// Bumped whenever [results] changes, for whoever republishes the track.
  final revision = 0.obs;

  final TranslationResults results = {};
  List<TranslationUnit> units = const [];

  TranslationEngine? _engine;
  Completer<void>? _wake;
  var _closed = false;
  var _failures = 0;
  Future<void>? _loop;
  Completer<void>? _parking;

  bool get isRunning => state.value.isBusy;

  /// Whether this session can take [ExtraText]s: its loop is alive (it
  /// naps, not ends, when done for as far as the viewer goes) and it is not
  /// paused under another page's.
  bool get servesExtras =>
      !modelFree &&
      _loop != null &&
      !_closed &&
      !_ended &&
      !state.value.isPaused;
  var _ended = false;

  /// Running, or paused to go on later.
  bool get isActive => isRunning || state.value.isPaused;

  void start() => _loop ??= _run();

  /// Something changed: new cues, a seek. The loop re-checks now rather than
  /// at its next poll.
  void poke() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Lets go of the model for another page's translation, keeping what is
  /// translated. Done once the model is released; the session loads it
  /// again through [claim] when its page has the player.
  Future<void> park() async {
    final loop = _loop;
    if (loop == null || _closed) return;
    final parking = _parking ??= Completer<void>();
    // the unit being generated is not worth holding the other page up for
    _engine?.cancel();
    poke();
    await Future.any([parking.future, loop]);
  }

  Future<void> dispose() async {
    _closed = true;
    poke();
    // a stop for memory or the background must not wait for the unit being
    // generated to finish with the model still loaded
    _engine?.cancel();
    await _loop;
  }

  /// The track as it stands. See [layOutTranslation] for [markPending].
  List<AsrCue> cues({
    TranslationDisplay display = TranslationDisplay.translated,
    bool markPending = true,
    String Function(String line)? showTranslated,
    String Function(String line)? showSource,
  }) {
    return layOutTranslation(
      units: units,
      results: results,
      trailing: _outsideUnits(),
      display: display,
      markPending: markPending,
      showTranslated: showTranslated,
      showSource: showSource,
      // a model still coming down is not a translation under way
      pendingMark: isDownloading
          ? translationDownloadingMark
          : translationPendingMark,
    );
  }

  /// The model is being downloaded (or checked after it), not loaded or
  /// translating.
  bool get isDownloading => _downloading(state.value);

  static bool _downloading(TranslationState state) {
    final message = state.message ?? '';
    return state.stage == TranslationStage.loading &&
        (message.startsWith('下载') || message.startsWith('校验'));
  }

  /// Where the stretch of settled units starting at [at] ends — translated
  /// or failed, either way final. [at] itself if the unit there is waiting.
  ///
  /// This, not the furthest translated unit, is what decides whether the
  /// viewer is about to run out: a hole in the middle would otherwise be
  /// invisible to the publishing gate.
  ///
  /// Nor does the stretch run on over a gap in the transcript: past it the
  /// text is not known, whatever is settled beyond.
  ///
  /// [asOf] reads the results as they were when a track was handed over:
  /// the source text each key then had a result for.
  double settledFrom(double at, {Map<int, String>? asOf}) {
    bool settled(TranslationUnit unit) =>
        asOf == null ? results.settles(unit) : asOf[unit.key] == unit.text;
    final known = coveredEndOf(transcript.covered(), at);
    var end = at;
    for (final unit in units) {
      if (unit.to < at) continue;
      if (unit.from > known || !settled(unit)) break;
      end = unit.to;
    }
    return end;
  }

  /// The results as they stand, to hand [settledFrom] later as `asOf`.
  Map<int, String> resultsSnapshot() => {
    for (final entry in results.entries) entry.key: entry.value.source,
  };

  /// Whether every unit so far is settled.
  bool get allSettled => units.every(results.settles);

  /// The next unit to translate: the first one not behind the playhead that
  /// has no result, if it starts within [translationLead].
  ///
  /// While a save waits for the whole translation ([requestFullCoverage]),
  /// one past the lead or behind the playhead too: the viewer's first, the
  /// rest from the start.
  @visibleForTesting
  TranslationUnit? next() {
    final now = position();
    final horizon = now + translationLead.inMilliseconds / 1000;
    for (final unit in units) {
      if (unit.to < now - _behind) continue;
      if (unit.from > horizon) break;
      if (!results.settles(unit)) return unit;
    }
    if (_fullCoverage == 0) return null;
    for (final unit in units) {
      if (!results.settles(unit)) return unit;
    }
    return null;
  }

  /// How many saves are waiting for the whole translation.
  var _fullCoverage = 0;

  /// A save wants the whole translation (design 13): until
  /// [endFullCoverage], every unit is translated, not only those within the
  /// lead. One call of [endFullCoverage] for each call of this.
  void requestFullCoverage() {
    _fullCoverage++;
    poke();
  }

  void endFullCoverage() {
    if (_fullCoverage > 0) _fullCoverage--;
  }

  /// Every line of a finished transcript is translated (or failed, which is
  /// as final): nothing more will come.
  bool get translatedAll {
    if (!transcript.complete()) return false;
    final all = transcript.units();
    return all.every(results.settles) && transcript.trailing().isEmpty;
  }

  /// The share of the transcript's units settled so far, 0..1.
  double get settledShare {
    final all = transcript.units();
    if (all.isEmpty) return transcript.complete() ? 1 : 0;
    return all.where(results.settles).length / all.length;
  }

  /// The source lines not in one of [units]: those in no unit yet, and those
  /// in units settled since [units] was last read.
  List<AsrCue> _outsideUnits() {
    final trailing = transcript.trailing();
    final known = {for (final unit in units) unit.key};
    final newer = [
      for (final unit in transcript.units())
        if (!known.contains(unit.key)) ...unit.cues,
    ];
    if (newer.isEmpty) return trailing;
    final out = [...newer, ...trailing];
    mergeSort(out, compare: (a, b) => a.from.compareTo(b.from));
    return out;
  }

  /// Whether nothing between the playhead and [within] seconds past it is
  /// still to be translated — every unit there has a result — and the text
  /// is known that far, so nothing untranslated can still turn up in it.
  /// Without [within], to the end of a finished transcript.
  ///
  /// Units behind the playhead do not count: a resume or a seek forward
  /// leaves them without a result, and the session would otherwise wait for
  /// them for as long as the page is open.
  ///
  /// Text past [within] proves the text up to it known only when no gap in
  /// the transcript lies between: a gap may yet fill with speech.
  bool nothingPendingAhead({double? within}) {
    final now = position();
    final end = within == null ? double.infinity : now + within;
    final complete = transcript.complete();
    final covered = transcript.covered();
    // the stretch of known text the playhead is in
    final known = complete
        ? (from: double.negativeInfinity, to: double.infinity)
        : coveredSpanOf(covered, now);
    for (final unit in units) {
      if (unit.to < now - _behind) continue;
      if (unit.from > end) return unit.from <= known.to;
      if (!results.settles(unit)) return false;
    }
    if (complete) return true;
    // lines not in a unit yet are still to be translated; and with none
    // past [end] the recogniser has not got that far. Only this stretch's:
    // another's are no sign of how far this one has got.
    final rest = _outsideUnits().where((c) => c.from >= known.from);
    return rest.isNotEmpty &&
        rest.first.from > end &&
        rest.first.from <= known.to;
  }

  void _refreshUnits() => units = transcript.units();

  /// Marks the session failed with [reason], for a stop the page must hear
  /// about (see TranslationService.stop).
  void fail(String reason) =>
      _set(TranslationState(TranslationStage.failed, message: reason));

  void _set(TranslationState value) {
    if (!_closed) state.value = value;
  }

  /// Until something changes (see [poke]), or a second has passed.
  Future<void> _nap() {
    final wake = _wake = Completer<void>();
    return Future.any([
      wake.future,
      Future<void>.delayed(const Duration(seconds: 1)),
    ]);
  }

  /// One [ExtraText], with the model loaded. Taken only now, so one that
  /// has to wait for the model is not held by a session that may yet be
  /// parked; one cut short by a park or a stop is handed back.
  Future<void> _translateExtra() async {
    final extra = takeExtra?.call();
    if (extra == null) return;
    _lastExtra = DateTime.now();
    if (extrasOnly) _set(const TranslationState(TranslationStage.translating));
    try {
      final reply = await _engine!.complete(
        translationPrompt(extra.text, target: extra.target),
      );
      if (!extra.done.isCompleted) {
        extra.done.complete(cleanTranslation(reply, source: extra.text));
      }
    } catch (e) {
      if (_closed || _parking != null || ownsPlayer?.call() == false) {
        giveBack?.call(extra);
        return;
      }
      if (kDebugMode) debugPrint('translate: text failed: $e');
      if (!extra.done.isCompleted) extra.done.complete(null);
    }
    _lastExtra = DateTime.now();
  }

  Future<void> _run() async {
    try {
      while (!_closed) {
        final parking = _parking;
        final covered = ownsPlayer?.call() == false;
        if (parking != null || covered) {
          // another video has the player, or another page's translation the
          // model: [position] reads a playhead that is not this video's
          final loaded = _engine;
          _engine = null;
          await loaded?.dispose();
          if (_closed) return;
          if (state.value.isBusy) {
            _set(const TranslationState(TranslationStage.paused));
          }
          _parking = null;
          parking?.complete();
          if (covered) {
            await _nap();
            continue;
          }
        }
        _refreshUnits();
        final due = next();
        // nothing of the transcript due: short texts go in the gap. The
        // transcript has the player's clock to keep; they do not.
        final extraDue = due == null && (hasExtra?.call() ?? false);
        if (due == null && !extraDue && extrasOnly) {
          // held a little for the next burst, then let go
          if (DateTime.now().difference(_lastExtra) > linger) {
            _set(const TranslationState(TranslationStage.done));
            return;
          }
          if (_engine != null) {
            _set(const TranslationState(TranslationStage.waiting));
          }
          await _nap();
          continue;
        }
        if (due == null && !extraDue) {
          // an empty transcript is finished too, with nothing to translate
          final finished = transcript.complete() && allSettled;
          if (finished) {
            _set(const TranslationState(TranslationStage.done));
            return;
          }
          // Done for as far as the viewer goes: the model is let go of, and
          // a seek back to what was skipped loads it again. A transcript
          // paused ahead of the viewer counts once the lead is translated:
          // otherwise the model (1-3 GB) would stay loaded all through the
          // pause (research/chunked-transcription-design-2026-09-25.md,
          // 4.5).
          if ((transcript.complete() && nothingPendingAhead()) ||
              (transcript.resting() &&
                  nothingPendingAhead(
                    within: translationLead.inMilliseconds / 1000,
                  ))) {
            final loaded = _engine;
            _engine = null;
            await loaded?.dispose();
            if (_closed) return;
            _set(const TranslationState(TranslationStage.done));
            await _nap();
            continue;
          }
          // paused under another page's translation until it has its turn
          if (!state.value.isPaused || (await claim?.call(this) ?? true)) {
            if (_closed) return;
            _set(const TranslationState(TranslationStage.waiting));
          }
          await _nap();
          continue;
        }
        if (modelFree && due != null) {
          _set(const TranslationState(TranslationStage.translating));
          final converter = _converter ??= await convert!();
          if (_closed) return;
          results.record(due, converter(due.text));
          revision.value++;
          continue;
        }
        if (_engine == null) {
          if (!(await claim?.call(this) ?? true)) {
            // another page's translation has the model and is at work
            await _nap();
            continue;
          }
          if (_closed) return;
          if (_parking != null || ownsPlayer?.call() == false) continue;
          _set(const TranslationState(TranslationStage.loading));
          try {
            _engine = await engine(
              (message) => _set(
                TranslationState(TranslationStage.loading, message: message),
              ),
            );
          } catch (_) {
            // a download cancelled to hand over to another page is not a
            // failure of this one
            if (_closed) return;
            if (_parking != null || ownsPlayer?.call() == false) continue;
            rethrow;
          }
          if (_closed) return;
          if (_parking != null) continue;
        }
        if (due == null) {
          await _translateExtra();
          continue;
        }
        _set(const TranslationState(TranslationStage.translating));
        final unit = due;
        String? text;
        try {
          final reply = await _engine!.complete(
            translationPrompt(unit.text, target: target),
          );
          text = cleanTranslation(reply, source: unit.text);
          if (text != null && convert != null) {
            text = (_converter ??= await convert!())(text);
          }
          _failures = 0;
        } catch (e) {
          if (_closed) return;
          // cancelled to let go of the model: the unit is translated later
          if (_parking != null || ownsPlayer?.call() == false) continue;
          if (kDebugMode) debugPrint('translate: unit ${unit.from} failed: $e');
          if (++_failures >= _giveUpAfter) {
            _set(TranslationState(TranslationStage.failed, message: '$e'));
            return;
          }
        }
        if (_closed) return;
        results.record(unit, text);
        revision.value++;
      }
    } catch (e) {
      _set(TranslationState(TranslationStage.failed, message: '$e'));
    } finally {
      _ended = true;
      final engine = _engine;
      _engine = null;
      await engine?.dispose();
    }
  }
}
