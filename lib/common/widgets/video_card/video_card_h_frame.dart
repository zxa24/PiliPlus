/// LibrePili: the horizontal video card's frame — a 16:10 cover on the
/// left, the text on the right, in a row that is one tap target.
///
/// bilibili had four copies of it (the global [VideoCardH] used by search,
/// history and the related shelf; the space's 投稿 card; the 合集 card) and
/// YouTube a fifth (`YtVideoTile`, in its search, related, subscription and
/// channel lists). They agreed by care, not by construction, so they drifted.
/// All of them are this now: padding, cover size and corner, the gap to the
/// text, the title's type and the grey lines' type are one definition, and a
/// change here moves every list on both platforms.
///
/// What is *on* a card stays each card's, because it is different data:
/// bilibili's 充电专属 badge, watch progress, play / danmaku counts and
/// popup menu; YouTube's LIVE badge and its own localised view and date
/// text. Those come in through [overlays], [content] and [menu].
library;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:material_ui/material_ui.dart';

class VideoCardHFrame extends StatelessWidget {
  const VideoCardHFrame({
    super.key,
    required this.cover,
    required this.content,
    this.overlays = const [],
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.menu,
  });

  final String? cover;

  /// Badges and bars over the cover, positioned within it.
  final List<Widget> overlays;

  /// The text column. It is given the rest of the row's width and the
  /// cover's height.
  final Widget content;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  /// A small button in the bottom-right corner (bilibili's ⋮ menu).
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final card = InkWell(
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Style.safeSpace,
          vertical: 5,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: Style.aspectRatio,
              child: LayoutBuilder(
                builder: (context, box) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    NetworkImgLayer(
                      src: cover,
                      width: box.maxWidth,
                      height: box.maxHeight,
                    ),
                    ...overlays,
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: content),
          ],
        ),
      ),
    );
    final menu = this.menu;
    return Material(
      type: MaterialType.transparency,
      child: menu == null
          ? card
          : Stack(
              clipBehavior: Clip.none,
              children: [
                card,
                Positioned(
                  bottom: 0,
                  right: 12,
                  width: 29,
                  height: 29,
                  child: menu,
                ),
              ],
            ),
    );
  }

  /// The title's type: two lines of body text, a little air between them.
  static TextStyle titleStyle(
    ThemeData theme, {
    Color? color,
    FontWeight? fontWeight,
  }) => TextStyle(
    fontSize: theme.textTheme.bodyMedium!.fontSize,
    height: 1.42,
    letterSpacing: 0.3,
    color: color,
    fontWeight: fontWeight,
  );

  /// The grey lines under the title (date and author, views).
  static TextStyle lineStyle(ThemeData theme) => TextStyle(
    fontSize: 12,
    height: 1,
    color: theme.colorScheme.outline,
    overflow: TextOverflow.clip,
  );

  /// The gap between two grey lines.
  static const lineGap = SizedBox(height: 3);
}

/// The card's title: two lines, ellipsised.
class VideoCardHTitle extends StatelessWidget {
  const VideoCardHTitle(
    this.text, {
    super.key,
    this.color,
    this.fontWeight,
  });

  final String text;
  final Color? color;
  final FontWeight? fontWeight;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.start,
    style: VideoCardHFrame.titleStyle(
      Theme.of(context),
      color: color,
      fontWeight: fontWeight,
    ),
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
  );
}

/// One grey line under the title.
class VideoCardHLine extends StatelessWidget {
  const VideoCardHLine(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    style: VideoCardHFrame.lineStyle(Theme.of(context)),
  );
}
