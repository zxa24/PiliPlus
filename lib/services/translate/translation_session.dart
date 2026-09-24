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
  /// The settled units so far; later calls return the same ones first.
  List<TranslationUnit> Function() units,

  /// Every source line so far, including those not in a unit yet.
  List<AsrCue> Function() cues,

  /// True once no more text is coming: the last unit is settled.
  bool Function() complete,
});

/// A transcript as a [TranscriptView]: units along its VAD segments.
TranscriptView transcriptView({
  required List<AsrSegmentSpan> Function() segments,
  required List<AsrCue> Function() cues,
  required bool Function() complete,
}) => (
  units: () => buildTranslationUnits(
    segments: segments(),
    cues: cues(),
    complete: complete(),
  ),
  cues: cues,
  complete: complete,
);

class TranslationSession {
  TranslationSession({
    required this.transcript,
    required this.position,
    required this.engine,
    required this.target,
    this.ownsPlayer,
    this.convert,
    this.modelFree = false,
  });

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
  }) {
    final settled = units;
    // Units are cut from the front of the cue list, so the rest is what they
    // have not taken. Not "starts after the last unit's end": that unit's
    // last cue can be held past the start of the next segment's first one,
    // which then went missing until its own unit settled.
    var taken = 0;
    for (final unit in settled) {
      taken += unit.cues.length;
    }
    return layOutTranslation(
      units: settled,
      results: results,
      trailing: transcript.cues().skip(taken).toList(),
      display: display,
      markPending: markPending,
    );
  }

  /// Where the stretch of settled units starting at [at] ends — translated
  /// or failed, either way final. [at] itself if the unit there is waiting.
  ///
  /// This, not the furthest translated unit, is what decides whether the
  /// viewer is about to run out: a hole in the middle would otherwise be
  /// invisible to the publishing gate.
  double settledFrom(double at) {
    var end = at;
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit.to < at) continue;
      if (!results.containsKey(i)) break;
      end = unit.to;
    }
    return end;
  }

  /// The next unit to translate: the first one not behind the playhead that
  /// has no result, if it starts within [translationLead].
  @visibleForTesting
  int? next() {
    final now = position();
    final horizon = now + translationLead.inMilliseconds / 1000;
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit.to < now - _behind) continue;
      if (unit.from > horizon) return null;
      if (!results.containsKey(i)) return i;
    }
    return null;
  }

  /// Whether nothing between the playhead and [within] seconds past it is
  /// still to be translated — every unit there has a result — and the text
  /// is known that far, so nothing untranslated can still turn up in it.
  /// Without [within], to the end of a finished transcript.
  ///
  /// Units behind the playhead do not count: a resume or a seek forward
  /// leaves them without a result, and the session would otherwise wait for
  /// them for as long as the page is open.
  bool nothingPendingAhead({double? within}) {
    final now = position();
    final end = within == null ? double.infinity : now + within;
    var taken = 0;
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      taken += unit.cues.length;
      if (unit.to < now - _behind) continue;
      if (unit.from > end) return true;
      if (!results.containsKey(i)) return false;
    }
    if (transcript.complete()) return true;
    // lines not in a unit yet are still to be translated; and with none
    // past [end] the recogniser has not got that far
    final rest = transcript.cues().skip(taken);
    return rest.isNotEmpty && rest.first.from > end;
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
        final i = next();
        if (i == null) {
          // an empty transcript is finished too, with nothing to translate
          final finished =
              transcript.complete() && results.length == units.length;
          if (finished) {
            _set(const TranslationState(TranslationStage.done));
            return;
          }
          if (transcript.complete() && nothingPendingAhead()) {
            // done for as far as the viewer goes: the model is let go of,
            // and a seek back to what was skipped loads it again
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
        if (modelFree) {
          _set(const TranslationState(TranslationStage.translating));
          final converter = _converter ??= await convert!();
          if (_closed) return;
          results[i] = converter(units[i].text);
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
        _set(const TranslationState(TranslationStage.translating));
        final unit = units[i];
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
          if (kDebugMode) debugPrint('translate: unit $i failed: $e');
          if (++_failures >= _giveUpAfter) {
            _set(TranslationState(TranslationStage.failed, message: '$e'));
            return;
          }
        }
        if (_closed) return;
        results[i] = text;
        revision.value++;
      }
    } catch (e) {
      _set(TranslationState(TranslationStage.failed, message: '$e'));
    } finally {
      final engine = _engine;
      _engine = null;
      await engine?.dispose();
    }
  }
}
