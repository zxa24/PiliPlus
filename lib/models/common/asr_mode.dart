import 'package:PiliPlus/models/common/enum_with_label.dart';

/// LibrePili: when to transcribe a video's audio on the device.
///
/// Transcription costs CPU and battery and, over the network, re-fetches the
/// audio stream, so it is never on by default — the first video without
/// subtitles asks once, and this records the answer.
enum AsrMode implements EnumWithLabel {
  /// Only from the subtitle menu, per video.
  manual('仅手动'),

  /// Start by itself when the video has no subtitles **and** what is being
  /// spoken is not the language the app is in — the case where the user
  /// cannot follow along without help.
  foreign('外语视频自动转录'),

  /// Start by itself whenever a video has no subtitles.
  always('无字幕时自动转录');

  @override
  final String label;
  const AsrMode(this.label);
}
