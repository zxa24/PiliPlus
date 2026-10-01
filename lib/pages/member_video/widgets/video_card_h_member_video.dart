import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/common/widgets/image/image_save.dart';
import 'package:PiliPlus/common/widgets/progress_bar/video_progress_indicator.dart';
import 'package:PiliPlus/common/widgets/stat/stat.dart';
import 'package:PiliPlus/common/widgets/video_card/video_card_h_frame.dart';
import 'package:PiliPlus/common/widgets/video_popup_menu.dart';
import 'package:PiliPlus/models/common/badge_type.dart';
import 'package:PiliPlus/models/common/stat_type.dart';
import 'package:PiliPlus/models_new/space/space_archive/item.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/dimension_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:material_ui/material_ui.dart';

// 视频卡片 - 水平布局
class VideoCardHMemberVideo extends StatelessWidget {
  const VideoCardHMemberVideo({
    super.key,
    required this.videoItem,
    this.onTap,
    this.bvid,
    this.fromViewAid,
  });
  final SpaceArchiveItem videoItem;
  final VoidCallback? onTap;
  final dynamic bvid;
  final String? fromViewAid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void onLongPress() => imageSaveDialog(
      title: videoItem.title,
      cover: videoItem.cover,
      bvid: videoItem.bvid,
    );
    // LibrePili: the frame is [VideoCardHFrame], shared with every other
    // horizontal card on both platforms
    return VideoCardHFrame(
      cover: videoItem.cover,
      onLongPress: onLongPress,
      onSecondaryTap: PlatformUtils.isMobile ? null : onLongPress,
      onTap:
          onTap ??
          () {
            final isPgc = videoItem.isPgc == true;
            final isPugv = videoItem.isPugv == true;
            if ((isPgc || isPugv) && videoItem.uri?.isNotEmpty == true) {
              if (PageUtils.viewPgcFromUri(
                videoItem.uri!,
                isPgc: isPgc,
              )) {
                return;
              }
            }
            if (videoItem.bvid == null || videoItem.cid == null) {
              return;
            }
            bool isVertical = false;
            if (videoItem.uri case final uri?) {
              isVertical = uri.isVerticalFromUri;
            }
            PageUtils.toVideoPage(
              bvid: videoItem.bvid,
              cid: videoItem.cid!,
              cover: videoItem.cover,
              title: videoItem.title,
              isVertical: isVertical,
            );
          },
      overlays: [
        if (fromViewAid == videoItem.param)
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: Style.mdRadius,
                color: Colors.black54,
              ),
              child: Center(
                child: Text(
                  '上次观看',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    letterSpacing: 5,
                  ),
                ),
              ),
            ),
          ),
        if (videoItem.badges?.isNotEmpty == true)
          PBadge(
            text: videoItem.badges!.map((item) => item.text).join('|'),
            right: 6.0,
            top: 6.0,
            type: videoItem.badges!.first.text == '充电专属'
                ? PBadgeType.error
                : PBadgeType.primary,
          ),
        if (videoItem.history != null) ...[
          Builder(
            builder: (context) {
              try {
                return Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: VideoProgressIndicator(
                    color: theme.colorScheme.primary,
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    progress:
                        videoItem.history!.progress! /
                        videoItem.history!.duration!,
                  ),
                );
              } catch (_) {
                return const SizedBox.shrink();
              }
            },
          ),
          Builder(
            builder: (context) {
              try {
                return PBadge(
                  text:
                      videoItem.history!.progress ==
                          videoItem.history!.duration
                      ? '已看完'
                      : '${DurationUtils.formatDuration(videoItem.history!.progress)}/${DurationUtils.formatDuration(videoItem.history!.duration)}',
                  right: 6.0,
                  bottom: 6.0,
                  type: PBadgeType.gray,
                );
              } catch (_) {
                return PBadge(
                  text: DurationUtils.formatDuration(videoItem.duration),
                  right: 6.0,
                  bottom: 6.0,
                  type: PBadgeType.gray,
                );
              }
            },
          ),
        ] else if (videoItem.duration > 0)
          PBadge(
            text: DurationUtils.formatDuration(videoItem.duration),
            right: 6.0,
            bottom: 6.0,
            type: PBadgeType.gray,
          ),
      ],
      content: content(context, theme),
      menu: VideoPopupMenu(
        iconSize: 17,
        videoItem: videoItem,
      ),
    );
  }

  Widget content(BuildContext context, ThemeData theme) {
    final isCurr =
        fromViewAid == videoItem.param ||
        (videoItem.bvid != null && videoItem.bvid == bvid);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: VideoCardHTitle(
            videoItem.title,
            fontWeight: isCurr ? FontWeight.bold : null,
            color: isCurr ? theme.colorScheme.primary : null,
          ),
        ),
        VideoCardHLine(
          videoItem.season != null
              ? DateFormatUtils.dateFormat(videoItem.season!.mtime)
              : videoItem.publishTimeText ?? '',
        ),
        VideoCardHFrame.lineGap,
        Row(
          spacing: 8,
          children: [
            StatWidget(
              type: StatType.play,
              value: videoItem.stat.view,
            ),
            StatWidget(
              type: StatType.danmaku,
              value: videoItem.stat.danmu,
            ),
          ],
        ),
      ],
    );
  }
}
