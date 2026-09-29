/// LibrePili: a little of the audio either side of each speech segment.
///
/// The VAD cuts close: a segment starts about 0.3 s before the speech it
/// heard and ends where the silence it waited for began, so a word that
/// fades in or out is clipped, and SenseVoice marks the cut as if it were a
/// sentence end (言いま？した). Decoding 0.4 s more on each side — never past
/// the middle of the silence to the next segment, so no audio is decoded
/// twice — took the error against burned-in subtitles on four noisy clips
/// from 47.6 to 42.9 (English WER) and from 18.0 to 12.8 (Japanese CER),
/// together with a 1 s minimum silence (research/noisy-speech-design-
/// 2026-09-26.md, 6).
///
/// The padding after a segment is clipped at the middle of the silence to
/// the *next* segment, which a stream has not seen yet when the VAD hands
/// the segment over. It waits until it knows: the next segment has begun
/// (and where), or the audio has gone far enough without speech that no
/// segment can begin within twice the padding. After a pause the VAD
/// reports a segment once a full minimum silence has passed, so that is a
/// few windows more; after the 20 s cap cut a speaker off, the next segment
/// begins at once and is seen within a window or so.
///
/// The first segment of a run is [SpeechPadding.add]ed `eager`: the viewer
/// is waiting for it (see FirstCut), so it waits only until no segment can
/// begin within its own padding, not twice that — about 0.4 s less. Its
/// padding after is then the full 0.4 s, and the padding before the next
/// segment stops where it ended instead of at the middle of the gap.
library;

import 'dart:math' as math;

/// A segment as the VAD cut it ([start], [end]) and as it is decoded
/// ([from], [to]), in samples from the start of the run.
typedef PaddedSpan = ({int start, int end, int from, int to});

class SpeechPadding {
  SpeechPadding({required this.pad, required this.lookBack});

  /// At most this many samples are added on each side.
  final int pad;

  /// How far before the VAD's read position a segment it has not begun yet
  /// can still start: the VAD opens a segment two windows plus the minimum
  /// speech length before the window that confirmed the speech
  /// (sherpa-onnx voice-activity-detector.cc: `start_ = tail - 2 * window -
  /// min_speech`).
  final int lookBack;

  final _waiting = <({int start, int end, bool eager})>[];

  /// Where the last span handed out ended, as the VAD cut it: the padding
  /// before the next one stops half way to it.
  int? _previousEnd;

  /// Where the audio decoded for the last span handed out ended: the next
  /// one never starts before it, so no audio is decoded twice.
  var _previousTo = 0;

  /// Where the last segment the VAD handed over ended; the VAD cannot open
  /// the next one before it.
  var _lastCut = 0;

  /// Where the segment the VAD is inside now began, once it is known.
  int? get speechFrom => _speechFrom;
  int? _speechFrom;

  /// Whether anything is waiting to be handed out.
  bool get isEmpty => _waiting.isEmpty;

  /// Where the first segment still waiting starts, or null.
  int? get firstWaiting => _waiting.isEmpty ? null : _waiting.first.start;

  void reset() {
    _waiting.clear();
    _previousEnd = null;
    _previousTo = 0;
    _lastCut = 0;
    _speechFrom = null;
  }

  /// A segment the VAD handed over, in order. An [eager] one is handed out
  /// as soon as no segment can begin within [pad] of its end.
  void add(int start, int end, {bool eager = false}) {
    _waiting.add((start: start, end: end, eager: eager));
    if (end > _lastCut) _lastCut = end;
    _speechFrom = null;
  }

  /// The VAD has just begun a segment, having read [read] samples: where it
  /// began follows from how the VAD opens one (see [lookBack]).
  void speechStarted(int read) {
    _speechFrom = math.max(read - lookBack, _lastCut);
  }

  /// The segments whose padding is decided, in order, taken off the queue.
  ///
  /// [read] is how many samples the VAD has been given, [speech] whether it
  /// is inside a segment now. [total], once the audio has ended and the VAD
  /// is flushed, is how many real samples there are: nothing more is coming,
  /// and the padding stops there.
  List<PaddedSpan> ready({
    required int read,
    required bool speech,
    int? total,
  }) {
    final out = <PaddedSpan>[];
    while (_waiting.isNotEmpty) {
      final s = _waiting.first;
      final next = _waiting.length > 1 ? _waiting[1].start : _speechFrom;
      final int to;
      if (next != null) {
        to = math.min(s.end + pad, (s.end + next) ~/ 2);
      } else if (total != null) {
        to = math.max(s.start, math.min(s.end + pad, total));
      } else if (!speech &&
          read - lookBack >= s.end + (s.eager ? pad : 2 * pad)) {
        // no segment can begin before s.end + 2 * pad any more, or, for an
        // eager one, before s.end + pad
        to = s.end + pad;
      } else {
        break;
      }
      final previous = _previousEnd;
      final from = math.max(
        _previousTo,
        previous == null
            ? s.start - pad
            : math.max(s.start - pad, (previous + s.start) ~/ 2),
      );
      out.add((start: s.start, end: s.end, from: from, to: to));
      _previousEnd = s.end;
      _previousTo = to;
      _waiting.removeAt(0);
    }
    return out;
  }
}
