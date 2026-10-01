/// LibrePili: one YouTube video in a list — search results, the related
/// shelf, a channel's uploads, a playlist and the subscription feed all show
/// the same thing, so they share this.
///
/// The frame is [VideoCardHFrame], the one bilibili's [VideoCardH] and its
/// space cards are built on: same padding, cover, gap, title and line type,
/// by construction. What YouTube does not report — a danmaku count, a
/// watch-progress bar — is absent rather than faked; its own localised view
/// and date text stand where bilibili's numbers do.
library;

import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/common/widgets/video_card/video_card_h_frame.dart';
import 'package:PiliPlus/models/common/badge_type.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:material_ui/material_ui.dart';

class YtVideoTile extends StatelessWidget {
  const YtVideoTile({
    super.key,
    required this.item,
    required this.onTap,
    this.showAuthor = true,
  });

  final YtSearchItem item;
  final VoidCallback onTap;

  /// Off on the channel's own tabs, where every item is the channel's — as
  /// bilibili's 投稿 card shows the date alone.
  final bool showAuthor;

  @override
  Widget build(BuildContext context) {
    final published = item.publishedText;
    final byline = showAuthor
        ? (published == null ? item.author : '$published  ${item.author}')
        : (published ?? '');
    return VideoCardHFrame(
      cover: item.bestThumbnail?.url,
      onTap: onTap,
      overlays: [
        if (item.isLive)
          const PBadge(
            text: 'LIVE',
            top: 6,
            right: 6,
            type: PBadgeType.error,
          )
        else if (item.duration case final duration?)
          PBadge(
            text: DurationUtils.formatDuration(duration.inSeconds),
            right: 6,
            bottom: 6,
            type: PBadgeType.gray,
          ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: VideoCardHTitle(item.title)),
          VideoCardHLine(byline),
          if (item.viewCountText case final views?) ...[
            VideoCardHFrame.lineGap,
            VideoCardHLine(views),
          ],
        ],
      ),
    );
  }
}

/// One playlist on a channel's 播放列表 tab: the frame of bilibili's 合集
/// card ([SeasonSeriesCard]), with YouTube's own count badge ('28 集').
class YtPlaylistCard extends StatelessWidget {
  const YtPlaylistCard({super.key, required this.item, required this.onTap});

  final YtPlaylistItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => VideoCardHFrame(
    cover: item.bestThumbnail?.url,
    onTap: onTap,
    overlays: [
      if (item.countText case final count?)
        PBadge(text: count, bottom: 6.0, right: 6.0),
    ],
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VideoCardHTitle(item.title),
        const Spacer(),
        // where the 合集 card has its date: the first video, which is the
        // one fact YouTube gives about a playlist's contents
        VideoCardHLine(item.firstVideoTitle ?? ''),
        const Spacer(),
      ],
    ),
  );
}
