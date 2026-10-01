/// LibrePili: the frame of a post in a feed — bilibili's 动态 and a YouTube
/// channel's 帖子.
///
/// An 8px band under each card, the whole card one tap target, the author
/// row at the top (40px avatar, name in titleSmall, time in labelSmall
/// grey, 10 apart), the content, then the row of count buttons. That frame
/// was bilibili's `DynamicPanel` / `AuthorPanel` / `ActionPanel`; the YouTube
/// post card is built from the same pieces here, so the two feeds cannot
/// drift apart in spacing or type.
///
/// The content is not shared, on purpose. A bilibili dynamic is rich nodes —
/// emotes, topics, @-mentions, votes, a forwarded dynamic inside it — and a
/// YouTube post is runs of text with links and one attachment. Forcing them
/// through one widget would tie bilibili's mature renderer to a platform it
/// knows nothing about (the same call as the comment lists, DEV_LOG
/// 2026-09-21).
library;

import 'package:material_ui/material_ui.dart';

class DynCardFrame extends StatelessWidget {
  const DynCardFrame({
    super.key,
    required this.author,
    required this.children,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.band = true,
  });

  /// [DynAuthorRow], or a platform's richer version of it.
  final Widget author;

  /// The content, then the action row.
  final List<Widget> children;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  /// The 8px band under the card. Off where the card is the page itself
  /// (a detail page in a side-by-side layout, a saved image).
  final bool band;

  @override
  Widget build(BuildContext context) {
    final child = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onSecondaryTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: author,
            ),
            ...children,
          ],
        ),
      ),
    );
    if (!band) return child;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: 8,
            color: Theme.of(context).dividerColor.withValues(alpha: 0.05),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: child,
      ),
    );
  }
}

/// The author row's geometry and type.
abstract final class DynAuthor {
  static const double avatarSize = 40;
  static const double spacing = 10;

  static TextStyle nameStyle(ThemeData theme, {Color? color}) => TextStyle(
    color: color ?? theme.colorScheme.onSurface,
    fontSize: theme.textTheme.titleSmall!.fontSize,
  );

  static TextStyle timeStyle(ThemeData theme, {Color? color}) => TextStyle(
    color: color ?? theme.colorScheme.outline,
    fontSize: theme.textTheme.labelSmall!.fontSize,
  );

  /// Avatar, then the name over the time. A list, because bilibili lays it
  /// out in a row that widens its hit area and YouTube in a plain one.
  static List<Widget> children({
    required Widget avatar,
    required Widget name,
    Widget? time,
  }) => [
    avatar,
    Flexible(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [name, ?time],
      ),
    ),
  ];
}

/// A plain author row: [DynAuthor.children] in a row, then whatever sits at
/// the right.
class DynAuthorRow extends StatelessWidget {
  const DynAuthorRow({
    super.key,
    required this.avatar,
    required this.name,
    this.time,
    this.onTap,
    this.trailing,
  });

  final Widget avatar;
  final String name;
  final String? time;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row = Row(
      spacing: DynAuthor.spacing,
      children: DynAuthor.children(
        avatar: avatar,
        name: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DynAuthor.nameStyle(theme),
        ),
        time: time == null
            ? null
            : Text(time!, style: DynAuthor.timeStyle(theme)),
      ),
    );
    if (onTap != null) {
      row = GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: row,
      );
    }
    final trailing = this.trailing;
    if (trailing == null) return row;
    return Row(
      children: [
        Expanded(child: row),
        trailing,
      ],
    );
  }
}

/// The count buttons under a post (转发 / 评论 / 点赞).
abstract final class DynAction {
  static const double iconSize = 16;

  static ButtonStyle buttonStyle(ColorScheme scheme) => TextButton.styleFrom(
    tapTargetSize: .padded,
    padding: const EdgeInsets.symmetric(horizontal: 15),
    foregroundColor: scheme.outline,
  );
}
