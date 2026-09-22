/// LibrePili: the type sizes of a video's intro block, in one place.
///
/// These were bilibili's, written as literals inside
/// `pages/video/introduction/ugc/view.dart`. The YouTube page did not copy
/// them — it reached for `theme.textTheme` instead, which is a different
/// set of numbers that merely looks similar, and for a couple of hand-picked
/// sizes that were not from anywhere at all. That is why the two pages kept
/// almost matching.
///
/// A theme entry is the wrong tool here. `bodyMedium` means "body text",
/// and an owner's name is not body text; using it says nothing about what
/// the number should be, so it drifts silently the moment either side is
/// touched. A named constant says what it is for, and both pages read the
/// same one.
library;

abstract final class IntroMetrics {
  /// The uploader's avatar and the gap to their name.
  static const avatarSize = 35.0;
  static const avatarGap = 10.0;

  /// The uploader's name.
  static const ownerName = 13.0;

  /// Whatever sits under it: 粉丝数 on bilibili, 订阅数 here.
  static const ownerSecondary = 12.0;

  /// The follow / subscribe button's label.
  static const followButton = 13.0;

  /// The video's title.
  static const title = 16.0;

  /// The line of numbers under the title: views, date, and on bilibili the
  /// danmaku count.
  static const stat = 12.0;

  /// The description body, and how loosely it is set.
  static const description = 14.0;
  static const descriptionHeight = 1.4;
}
