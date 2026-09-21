/// LibrePili: the parts a comment list is built out of, in one place.
///
/// There are two comment lists in this app now — bilibili's and YouTube's —
/// and they are not the same code, because a bilibili reply carries emotes,
/// pictures, votes, member levels and a protobuf to hold them, while a
/// YouTube one carries a string. What they *are* the same in is everything
/// around the text: the divider under an item, the rule between a comment
/// and its replies, the row at the end that says 加载中... or 没有更多了,
/// the panel bar over 评论详情.
///
/// Every difference the YouTube list has drifted into so far has been one
/// of those. They live here so that changing one changes both, and so that
/// "the same as bilibili's" is a fact about the code rather than a claim
/// about a screenshot.
library;

import 'package:PiliPlus/common/skeleton/video_reply.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract final class CommentChrome {
  /// One comment's own padding.
  static const itemPadding = EdgeInsets.fromLTRB(12, 14, 8, 5);

  static const avatarSize = 34.0;

  /// Avatar to text.
  static const avatarGap = 12.0;

  static const nameFontSize = 13.0;
  static const timeFontSize = 11.0;
  static const bodyFontSize = 14.0;
  static const bodyHeight = 1.75;

  /// The reply-preview block, and how far it is inset from the avatar.
  static const previewIndent = 42.0;
  static const previewRadiusValue = 6.0;

  /// The row at the end of a list.
  static const footerHeight = 125.0;

  /// How many skeleton rows a list shows before its first page arrives.
  static const listSkeletons = 5;
  static const panelSkeletons = 8;

  /// Between two comments: indented past the avatar, hairline, barely there.
  static Widget itemDivider(ThemeData theme) => Divider(
    indent: 55,
    endIndent: 15,
    height: 0.3,
    color: theme.colorScheme.outline.withValues(alpha: 0.08),
  );

  /// Between a comment and the replies to it, in 评论详情.
  static Widget thickDivider(ThemeData theme) => Divider(
    height: 20,
    thickness: 6,
    color: theme.dividerColor.withValues(alpha: 0.1),
  );

  /// The bar over a comment-detail panel.
  static Widget panelHeader(ThemeData theme, {required String title}) =>
      Container(
        height: 45,
        padding: const EdgeInsets.only(left: 12, right: 2),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 1,
              color: theme.dividerColor.withValues(alpha: 0.1),
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title),
            IconButton(
              tooltip: '关闭',
              icon: const Icon(Icons.close, size: 20),
              onPressed: Get.back,
            ),
          ],
        ),
      );

  /// 「相关回复共 N 条」 and whatever sits opposite it.
  static Widget countLine(String text, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 2.5, 6, 2.5),
    child: SizedBox(
      height: 32,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(text, style: const TextStyle(fontSize: 13)),
          ?trailing,
        ],
      ),
    ),
  );

  /// The row a list ends on. It is the same height whatever it says, so the
  /// list does not jump when the last page lands.
  static Widget pagingFooter(
    ThemeData theme, {
    required bool isEnd,
    String? error,
    VoidCallback? onRetry,
    String emptyText = '没有更多了',
    EdgeInsets margin = EdgeInsets.zero,
  }) => Container(
    height: footerHeight,
    alignment: Alignment.center,
    margin: margin,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: error != null
        ? TextButton(
            onPressed: onRetry,
            child: Text('加载失败：$error', textAlign: TextAlign.center),
          )
        : Text(
            isEnd ? emptyText : '加载中...',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
          ),
  );

  static List<Widget> skeletons(int count) => [
    for (var i = 0; i < count; i++) const VideoReplySkeleton(),
  ];

  /// The corner radius a row of the reply-preview block gets for its
  /// position in that block.
  static BorderRadius? previewRadius(int index, int length) {
    const radius = Radius.circular(previewRadiusValue);
    if (length == 1) return const BorderRadius.all(radius);
    if (index == 0) return const BorderRadius.vertical(top: radius);
    if (index == length - 1) {
      return const BorderRadius.vertical(bottom: radius);
    }
    return null;
  }

  /// And its padding, which is tighter in the middle than at the ends.
  static EdgeInsets previewPadding(int index, int length) {
    if (length == 1) return const EdgeInsets.fromLTRB(8, 5, 8, 5);
    if (index == 0) return const EdgeInsets.fromLTRB(8, 8, 8, 4);
    if (index == length - 1) return const EdgeInsets.fromLTRB(8, 4, 8, 8);
    return const EdgeInsets.fromLTRB(8, 4, 8, 4);
  }
}
