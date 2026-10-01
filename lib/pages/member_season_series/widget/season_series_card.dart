import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/common/widgets/image/image_save.dart';
import 'package:PiliPlus/common/widgets/video_card/video_card_h_frame.dart';
import 'package:PiliPlus/models_new/space/space_season_series/season.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: on [VideoCardHFrame], the frame every horizontal card shares —
/// the YouTube channel's playlist card is the same frame with YouTube's
/// count badge.
class SeasonSeriesCard extends StatelessWidget {
  const SeasonSeriesCard({
    super.key,
    required this.item,
    required this.onTap,
  });
  final SpaceSsModel item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    void onLongPress() => imageSaveDialog(
      title: item.meta!.name,
      cover: item.meta!.cover,
    );
    return VideoCardHFrame(
      cover: item.meta!.cover,
      onLongPress: onLongPress,
      onSecondaryTap: PlatformUtils.isMobile ? null : onLongPress,
      onTap: onTap,
      overlays: [
        PBadge(
          text:
              '${item.meta!.seasonId != null ? '合集' : '列表'}: ${item.meta!.total}',
          bottom: 6.0,
          right: 6.0,
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          VideoCardHTitle(item.meta!.name!),
          const Spacer(),
          VideoCardHLine(DateFormatUtils.dateFormat(item.meta!.ptime)),
          const Spacer(),
        ],
      ),
    );
  }
}
