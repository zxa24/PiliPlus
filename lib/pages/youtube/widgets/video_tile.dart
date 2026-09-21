/// LibrePili: one YouTube video in a list — search results, the related
/// shelf, a channel's uploads and the subscription feed all show the same
/// thing, so they share this.
///
/// Shaped like bilibili's [VideoCardH], because it sits in the same lists:
/// a 16:10 cover with the duration in the corner, two lines of title, then
/// who made it and how it has done. What YouTube does not report — a
/// danmaku count, a watch-progress bar — is absent rather than faked.
library;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models/common/badge_type.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:material_ui/material_ui.dart';

class YtVideoTile extends StatelessWidget {
  const YtVideoTile({super.key, required this.item, required this.onTap});

  final YtSearchItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
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
                        src: item.bestThumbnail?.url,
                        width: box.maxWidth,
                        height: box.maxHeight,
                      ),
                      if (item.isLive)
                        const PBadge(
                          text: 'LIVE',
                          top: 6,
                          right: 6,
                          type: PBadgeType.error,
                        )
                      else if (item.duration case final duration?)
                        PBadge(
                          text: DurationUtils.formatDuration(
                            duration.inSeconds,
                          ),
                          right: 6,
                          bottom: 6,
                          type: PBadgeType.gray,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _content(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(ThemeData theme) {
    final published = item.publishedText;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: theme.textTheme.bodyMedium!.fontSize,
                height: 1.42,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Text(
            published == null ? item.author : '$published  ${item.author}',
            maxLines: 1,
            style: TextStyle(
              fontSize: 12,
              height: 1,
              color: theme.colorScheme.outline,
              overflow: TextOverflow.clip,
            ),
          ),
          if (item.viewCountText case final views?) ...[
            const SizedBox(height: 3),
            Text(
              views,
              maxLines: 1,
              style: TextStyle(
                fontSize: 12,
                height: 1,
                color: theme.colorScheme.outline,
                overflow: TextOverflow.clip,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
