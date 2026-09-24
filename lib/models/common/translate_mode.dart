import 'package:PiliPlus/models/common/enum_with_label.dart';

/// LibrePili: when to translate a video's own captions or an on-device
/// transcript.
///
/// Only text that is not in the app's language is translated — translating
/// what the user already reads would cost battery for nothing. The model is
/// a 2.8 GB download, so nothing runs until the first request asks once and
/// this records the answer.
enum TranslateMode implements EnumWithLabel {
  /// Only from the subtitle menu, per video.
  manual('仅手动'),

  /// Whenever a video's captions, or its transcript, turn out to be in
  /// another language. The page waits for the first translated lines.
  auto('外语字幕或转录时自动翻译');

  @override
  final String label;
  const TranslateMode(this.label);
}
