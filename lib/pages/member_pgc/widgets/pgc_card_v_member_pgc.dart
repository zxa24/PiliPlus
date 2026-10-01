import 'package:PiliPlus/common/widgets/image/image_save.dart';
import 'package:PiliPlus/common/widgets/video_card/portrait_card_frame.dart';
import 'package:PiliPlus/models_new/space/space_archive/item.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:material_ui/material_ui.dart';

// 视频卡片 - 垂直布局
// LibrePili: on [PortraitCardFrame], which a YouTube channel's Shorts use too
class PgcCardVMemberPgc extends StatelessWidget {
  const PgcCardVMemberPgc({
    super.key,
    required this.item,
  });

  final SpaceArchiveItem item;

  @override
  Widget build(BuildContext context) {
    void onLongPress() => imageSaveDialog(
      title: item.title,
      cover: item.cover,
    );
    return PortraitCardFrame(
      cover: item.cover,
      title: item.title,
      onTap: () => PageUtils.viewPgc(seasonId: item.param),
      onLongPress: onLongPress,
      onSecondaryTap: PlatformUtils.isMobile ? null : onLongPress,
    );
  }
}
