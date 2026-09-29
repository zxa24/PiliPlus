/// LibrePili: the first segment of a run is cut after half a second of
/// silence, the rest after a full second.
///
/// A second of silence before a segment ends (rather than half) recognises
/// noisy speech better (SpeechPadding), but the first segment of a run
/// then runs on through every shorter pause, and the page holds playback
/// until its first line: 14.4 s of speech instead of 1.3 s before the first
/// subtitle on one clip, 19.9 s (the 20 s cap) instead of 6.5 s on another.
/// A run starts with the video and again at every seek, so each start is a
/// viewer waiting.
///
/// sherpa-onnx fixes the minimum silence when a VAD is made, so there are
/// two, fed the same audio from the same reset: [update]'s `quick` (0.5 s)
/// and `steady` (1.0 s). Their speech model sees the same windows, so they
/// agree on every window's speech until the quick one cuts (or both cut
/// together at the 20 s cap); the quick one
/// cuts the first segment, and from then on only the steady one is used.
/// The steady one is still inside that speech — it either finds the full
/// second of silence and cuts the same segment again (dropped), or hears
/// speech first and runs on; what it cuts then is reported from where the
/// quick one heard speech again. Every later segment is the steady VAD's own
/// and identical to what it cuts alone.
///
/// Measured offline on four noisy clips (research/noisy-speech-design-
/// 2026-09-26.md, 6): the error is unchanged, and the audio needed before
/// the first cue is about 0.2 s more than with 0.5 s alone (the padding
/// after it, SpeechPadding) instead of up to 14 s more.
library;

import 'package:PiliPlus/services/asr/speech_padding.dart';

/// A cut segment, in samples from the VAD's last reset.
typedef VadCut = ({int start, int end});

/// What [FirstCut] needs of a VAD.
abstract interface class VadCuts {
  /// The segments it has cut and not handed over yet, in order, taken off it.
  List<VadCut> take();

  /// Whether it is inside a segment now.
  bool get detected;
}

enum _Stage {
  /// The quick VAD decides.
  first,

  /// The quick VAD has cut; the steady one has not cut the speech that
  /// segment began in yet.
  bridging,

  /// The steady VAD alone.
  steady,
}

class FirstCut {
  FirstCut(this.padding);

  /// Where the segments go.
  final SpeechPadding padding;

  var _stage = _Stage.first;

  /// Where the quick VAD heard speech again after its cut.
  int? _resumed;

  /// Whether a segment that will be handed to [padding] is open now.
  bool get speech => _speech;
  var _speech = false;

  /// Whether the quick VAD is still wanted: fed, and, at the end, flushed
  /// (then [flushQuick] says which one is).
  bool get quickWanted => _stage != _Stage.steady;

  /// Which VAD is flushed at the end of the audio: what it still holds is
  /// what the run has not reported. Only one, or the same speech is cut
  /// twice.
  bool get flushQuick => _stage == _Stage.first;

  /// After both VADs (while [quickWanted]) have been given the audio up to
  /// [read], samples from the run's start.
  void update({
    required VadCuts quick,
    required VadCuts steady,
    required int read,
  }) {
    switch (_stage) {
      case _Stage.first:
        final early = steady.take();
        final cuts = quick.take();
        if (early.isNotEmpty) {
          // Both cut together at the 20 s cap: past it sherpa-onnx waits
          // 0.1 s of silence in either (voice-activity-detector.cc,
          // max_utterance_length_), so they cut the same segment. (The
          // steady one alone first cannot happen: it waits longer for the
          // same silence.) One of them is used, and the quick one's part is
          // done.
          for (final c in early) {
            padding.add(c.start, c.end);
          }
          _stage = _Stage.steady;
          // what it is inside now, if anything, is a new segment
          _speech = false;
          _edge(steady.detected, read);
        } else if (cuts.isNotEmpty) {
          padding.add(cuts.first.start, cuts.first.end, eager: true);
          _stage = _Stage.bridging;
          _speech = false;
          _bridge(quick: quick, steady: steady, read: read);
        } else {
          _edge(quick.detected, read);
        }
      case _Stage.bridging:
        quick.take();
        _bridge(quick: quick, steady: steady, read: read);
      case _Stage.steady:
        for (final c in steady.take()) {
          padding.add(c.start, c.end);
        }
        _edge(steady.detected, read);
    }
  }

  void _bridge({
    required VadCuts quick,
    required VadCuts steady,
    required int read,
  }) {
    if (_resumed == null && quick.detected) {
      padding.speechStarted(read);
      _resumed = padding.speechFrom;
    }
    final cuts = steady.take();
    if (cuts.isEmpty) {
      _speech = _resumed != null && steady.detected;
      return;
    }
    // The speech the first segment began in, as the steady VAD cut it: the
    // part after the quick VAD's cut, if there was speech in it.
    final resumed = _resumed;
    final first = cuts.first;
    if (resumed != null && first.end > resumed) {
      padding.add(resumed, first.end);
    }
    for (final c in cuts.skip(1)) {
      padding.add(c.start, c.end);
    }
    _stage = _Stage.steady;
    _speech = false;
    _edge(steady.detected, read);
  }

  void _edge(bool detected, int read) {
    if (detected && !_speech) padding.speechStarted(read);
    _speech = detected;
  }
}
