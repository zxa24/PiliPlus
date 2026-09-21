/// LibrePili: one YouTube video in a list — search results and the related
/// shelf show the same thing, so they share this.
library;

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
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
    return InkWell(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              NetworkImgLayer(
                width: 150,
                height: 84,
                src: item.bestThumbnail?.url,
              ),
              if (item.isLive)
                _badge(context, 'LIVE', color: theme.colorScheme.error)
              else if (item.duration case final duration?)
                _badge(
                  context,
                  DurationUtils.formatDuration(duration.inSeconds),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    item.author,
                    ?item.viewCountText,
                    ?item.publishedText,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(BuildContext context, String text, {Color? color}) => Container(
    margin: const EdgeInsets.all(4),
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(
      color: color ?? Colors.black54,
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: 11),
    ),
  );
}
