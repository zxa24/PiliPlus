/// LibrePili: a portrait cover card in a grid — bilibili's 追番 / 番剧
/// cards on an UP主's space, and YouTube's Shorts.
///
/// A rounded card, the cover at the top, two lines of title under it. It
/// was `PgcCardVMemberPgc`; a channel's Shorts tab is the same grid of the
/// same card with a 9:16 cover, so the two cannot drift in corner, padding
/// or type.
library;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:material_ui/material_ui.dart';

class PortraitCardFrame extends StatelessWidget {
  const PortraitCardFrame({
    super.key,
    required this.cover,
    required this.title,
    this.aspectRatio = 0.75,
    this.subtitle,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
  });

  final String? cover;
  final String title;

  /// Width over height: 0.75 for a bilibili 番剧 cover, 9/16 for a Short.
  final double aspectRatio;

  /// A grey line under the title (a Short's view count).
  final String? subtitle;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return Card(
      shape: const RoundedRectangleBorder(borderRadius: Style.mdRadius),
      child: InkWell(
        borderRadius: Style.mdRadius,
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onSecondaryTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: aspectRatio,
              child: LayoutBuilder(
                builder: (context, boxConstraints) {
                  return NetworkImgLayer(
                    src: cover,
                    width: boxConstraints.maxWidth,
                    height: boxConstraints.maxHeight,
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 5, 0, 3),
              child: Text(
                title,
                textAlign: TextAlign.start,
                style: const TextStyle(letterSpacing: 0.3),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 0, 3),
                child: Text(
                  subtitle,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1,
                    color: ColorScheme.of(context).outline,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The grid these cards sit in: as wide as 0.6 of a small card, the
  /// cover's ratio, and room under it for the text ([textExtent] at the
  /// default text scale).
  static SliverGridDelegateWithExtentAndRatio gridDelegate(
    BuildContext context, {
    double aspectRatio = 0.75,
    double textExtent = 52,
  }) => SliverGridDelegateWithExtentAndRatio(
    mainAxisSpacing: Style.cardSpace,
    crossAxisSpacing: Style.cardSpace,
    maxCrossAxisExtent: Grid.smallCardWidth * 0.6,
    childAspectRatio: aspectRatio,
    mainAxisExtent: MediaQuery.textScalerOf(context).scale(textExtent),
  );
}
