import 'package:PiliPlus/models/common/enum_with_label.dart';

/// LibrePili: which platform the app is showing.
///
/// A platform is a mode, as in NewPipe and PipePipe: it decides where the
/// home feed, the dynamics tab and search get their content. The bottom
/// navigation itself does not change.
enum PlatformMode implements EnumWithLabel {
  bilibili('B 站'),
  youtube('YouTube'),

  /// Both. Only the *subscription* feed is genuinely merged — recommendations
  /// from two platforms are not comparable and interleaving them would just
  /// be shuffling, so home shows them as separate sections and search keeps a
  /// tab per platform.
  all('全部');

  @override
  final String label;
  const PlatformMode(this.label);
}
