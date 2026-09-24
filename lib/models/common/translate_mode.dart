import 'package:PiliPlus/models/common/enum_with_label.dart';

/// LibrePili: when to translate an on-device transcript.
///
/// Translation only ever follows transcription, and only when the speech is
/// not in the app's language — translating what the user already reads would
/// cost battery for nothing. The model is a 2.8 GB download, so nothing runs
/// until the first request asks once and this records the answer.
enum TranslateMode implements EnumWithLabel {
  /// Only from the subtitle menu, per video.
  manual('仅手动'),

  /// Whenever a transcript turns out to be in another language.
  auto('转录外语时自动翻译');

  @override
  final String label;
  const TranslateMode(this.label);
}
