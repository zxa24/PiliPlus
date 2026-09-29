/// LibrePili: no segment is longer than [SegmentCap.max].
///
/// sherpa-onnx's own maximum speech length does not cut: past it the VAD
/// only waits for 0.1 s of silence instead of a full second, and takes a
/// window for silence only below a probability of 0.75
/// (voice-activity-detector.cc: `new_min_silence_duration_s_`,
/// `new_threshold_`; silero-vad-model.cc: `neg_threshold`). Continuous
/// speech over background music stays above that: on one clip 8 of 10
/// segments ran past 20 s, the longest 46.9 s, and a line could not appear
/// until its whole segment was cut. So the transcriber cuts a segment
/// itself once it has run [SegmentCap.max] from its start (or from the last
/// such cut): in the middle of the quietest [SegmentCap.frame] of the last
/// [SegmentCap.search], so a word is cut in two as seldom as possible.
///
/// The VAD is left alone: it stays inside its segment, and when it hands
/// that over, only the part after the cut is new (SpeechPadding.cutAt).
/// Starting it over at the cut instead lost words (it needs a moment to
/// hear speech again, and cut the rest differently): on one clip 20 s of
/// 300 were never decoded, and the error against burned-in subtitles rose
/// from 7.9 to 12.2.
///
/// SenseVoice takes the end of its audio for the end of a sentence, and the
/// word at the cut suffers; [zeros] of silence added on each side of a cut,
/// in the audio decoded only, bring it back: with the rest of this rule the
/// error stayed within the variation of decoding the same clips with small
/// changes (padding, gain, dither) on all eight test clips, with the
/// longest wait for a line from 47 s to 20 s (research/noisy-speech-design-
/// 2026-09-26.md, 15).
library;

import 'dart:typed_data';

abstract final class SegmentCap {
  /// The longest a segment may be, in seconds.
  static const max = 20.0;

  /// How far back from [max] the cut may go, in seconds.
  static const search = 6.0;

  /// How long a stretch [quietest] compares, in seconds.
  static const frame = 0.2;

  /// How far apart the stretches it compares start, in seconds.
  static const hop = 0.01;

  /// How much silence is decoded on each side of a cut, in seconds; see
  /// [withZeros].
  static const zeros = 0.4;

  /// Where in [samples] the quietest [frameLength]-sample stretch is
  /// (least energy; the earliest of equals), as the index of its middle.
  /// Stretches start every [hopLength] samples. Too few samples for one
  /// stretch: the end.
  static int quietest(
    Float32List samples, {
    required int frameLength,
    required int hopLength,
  }) {
    if (samples.length < frameLength) return samples.length;
    // running sum of squares: each stretch in O(1)
    final sums = Float64List(samples.length + 1);
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      sums[i + 1] = sums[i] + s * s;
    }
    var best = 0;
    var least = double.infinity;
    for (var i = 0; i + frameLength <= samples.length; i += hopLength) {
      final e = sums[i + frameLength] - sums[i];
      if (e < least) {
        least = e;
        best = i;
      }
    }
    return best + frameLength ~/ 2;
  }

  /// The audio to decode for a segment: [audio], which begins at [from]
  /// samples into the run, with [count] zeros before it if its start is a
  /// cut ([before]) and after it if its end is one ([after]). The result's
  /// `from` is where [samples] begin as the run counts, the zeros before
  /// included: the recogniser's token times count from there.
  static ({Float32List samples, int from}) withZeros(
    Float32List audio, {
    required int from,
    required bool before,
    required bool after,
    required int count,
  }) {
    if (!before && !after) return (samples: audio, from: from);
    final lead = before ? count : 0;
    final out = Float32List(lead + audio.length + (after ? count : 0))
      ..setAll(lead, audio);
    return (samples: out, from: from - lead);
  }
}
