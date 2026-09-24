/// LibrePili: the YouTube player's header, in the same place, at the same
/// height, and with the same panels as the bilibili one.
///
/// It carries what a YouTube video actually has. Danmaku, chapters, episode
/// lists and SponsorBlock are bilibili's and are simply absent — everything
/// else (听视频, 投屏, 更多设置 and the whole settings sheet behind it) is the
/// same widget in the same spot, and the panels come from [HeaderMixin], so
/// they open from the bottom on a phone and from the right on a wide window
/// exactly as the bilibili ones do.
library;

import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/pages/setting/models/play_settings.dart'
    show showPlayerVolumeDialog;
import 'package:PiliPlus/pages/setting/widgets/popup_item.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/menu_row.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart'
    show HeaderControlState;
import 'package:PiliPlus/pages/video/widgets/header_mixin.dart';
import 'package:PiliPlus/pages/youtube/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart'
    show shutdownTimerService, ShutdownPanel;
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide showBottomSheet;

class YtHeaderControl extends StatefulWidget {
  const YtHeaderControl({super.key, required this.controller});

  final YtVideoController controller;

  @override
  State<YtHeaderControl> createState() => YtHeaderControlState();
}

class YtHeaderControlState extends State<YtHeaderControl>
    with HeaderMixin<YtHeaderControl> {
  YtVideoController get controller => widget.controller;

  @override
  PlPlayerController get plPlayerController => controller.plPlayerController;

  static const titleStyle = TextStyle(fontSize: 14);
  static const subTitleStyle = TextStyle(fontSize: 12);

  @override
  Widget build(BuildContext context) {
    // the same metrics as the bilibili header: 42×34 buttons inside 12 points
    // of vertical padding. A shorter bar over the video reads as a different
    // app, which is what it looked like.
    const btnWidth = 42.0;
    const btnHeight = 34.0;
    const btnStyle = ButtonStyle(
      padding: WidgetStatePropertyAll(EdgeInsets.zero),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final isFullScreen = this.isFullScreen;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: btnWidth,
            height: btnHeight,
            child: IconButton(
              tooltip: '返回',
              style: btnStyle,
              onPressed: () => isFullScreen
                  ? plPlayerController.triggerFullScreen(status: false)
                  : Get.back(),
              icon: const Icon(
                Icons.arrow_back_ios_new,
                size: 18,
                color: Colors.white,
              ),
            ),
          ),
          SizedBox(
            width: btnWidth,
            height: btnHeight,
            child: IconButton(
              tooltip: '返回主页',
              style: btnStyle,
              onPressed: () => Get.until((route) => route.isFirst),
              icon: const Icon(
                Icons.home_outlined,
                size: 19,
                color: Colors.white,
              ),
            ),
          ),
          Expanded(
            child: Obx(
              () => Text(
                controller.detail.value?.title ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
          if (!isFullScreen) ...[
            Obx(() {
              final onlyAudio = plPlayerController.onlyPlayAudio.value;
              return SizedBox(
                width: btnWidth,
                height: btnHeight,
                child: IconButton(
                  tooltip: '听视频',
                  style: btnStyle,
                  onPressed: _toggleAudioOnly,
                  icon: Icon(
                    onlyAudio ? Icons.headphones : Icons.headphones_outlined,
                    size: 19,
                    color: Colors.white,
                  ),
                ),
              );
            }),
            SizedBox(
              width: btnWidth,
              height: btnHeight,
              child: IconButton(
                tooltip: '投屏',
                style: btnStyle,
                onPressed: _cast,
                icon: const Icon(Icons.cast, size: 19, color: Colors.white),
              ),
            ),
          ],
          SizedBox(
            width: btnWidth,
            height: btnHeight,
            child: IconButton(
              tooltip: '更多设置',
              style: btnStyle,
              onPressed: showSettingSheet,
              icon: const Icon(
                Icons.more_vert_outlined,
                size: 19,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleAudioOnly() {
    final onlyAudio = plPlayerController.onlyPlayAudio.value;
    plPlayerController.onlyPlayAudio.value = !onlyAudio;
    plPlayerController.videoPlayerController?.setProperty(
      'file-local-options/vid',
      onlyAudio ? 'auto' : 'no',
    );
  }

  void _cast() {
    // an adaptive video-only stream would arrive at the TV without sound, so
    // this casts a muxed format or says it cannot
    final url = controller.castUrl;
    if (url == null) {
      SmartDialog.showToast('该视频没有可投屏的单一流');
      return;
    }
    Get.toNamed(
      '/dlna',
      parameters: {
        'url': url,
        'title': ?controller.detail.value?.title,
      },
    );
  }

  /// 更多设置 — bilibili's sheet minus the entries a YouTube video has no
  /// equivalent for (稍后再看, 笔记, 弹幕, CDN, 举报).
  void showSettingSheet() {
    showBottomSheet(
      (context, setState) {
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 14),
              children: [
                if (controller.detail.value?.thumbnails.isNotEmpty == true)
                  ListTile(
                    dense: true,
                    onTap: () {
                      Get.back();
                      ImageUtils.downloadImg([
                        controller.detail.value!.thumbnails.last.url,
                      ]);
                    },
                    leading: const Icon(Icons.image_outlined, size: 20),
                    title: const Text('保存封面', style: titleStyle),
                  ),
                ListTile(
                  dense: true,
                  onTap: () {
                    Get.back();
                    shutdownTimerService.showScheduleExitDialog(
                      this.context,
                      isFullScreen: isFullScreen,
                    );
                  },
                  leading: const Icon(Icons.hourglass_top_outlined, size: 20),
                  title: const Text('定时关闭', style: titleStyle),
                  subtitle: shutdownTimerService.isActive
                      ? ShutdownPanel(
                          buildCountdownText: (text) =>
                              Text(text == null ? '已结束' : '剩余 $text'),
                          builder: (
                            context,
                            countdown,
                            onCountdown,
                            setState,
                          ) => countdown,
                        )
                      : null,
                ),
                ListTile(
                  dense: true,
                  onTap: () {
                    Get.back();
                    Utils.copyText(controller.shareUrl!);
                  },
                  leading: const Icon(Icons.link, size: 20),
                  title: const Text('复制链接', style: titleStyle),
                ),
                ListTile(
                  dense: true,
                  onTap: () {
                    Get.back();
                    controller.load();
                  },
                  leading: const Icon(Icons.refresh_outlined, size: 20),
                  title: const Text('重载视频', style: titleStyle),
                ),
                PopupListTile<SuperResolutionType>(
                  dense: true,
                  leading: const Icon(
                    Icons.stay_current_landscape_outlined,
                    size: 20,
                  ),
                  title: const Text('超分辨率', style: titleStyle),
                  titleStyle: theme.textTheme.bodyLarge,
                  value: () {
                    final value = plPlayerController.superResolutionType.value;
                    return (value, value.label);
                  },
                  itemBuilder: (_) =>
                      enumItemBuilder(SuperResolutionType.values),
                  onSelected: (value, setState) {
                    plPlayerController.setShader(value);
                    setState();
                  },
                  descPosType: .subtitle,
                  descStyle: subTitleStyle,
                ),
                if (PlatformUtils.isMobile)
                  if (plPlayerController.videoPlayerController
                      case final player?)
                    Builder(
                      builder: (context) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.volume_up, size: 20),
                        title: const Text('播放器音量', style: titleStyle),
                        subtitle: Text(
                          '当前: ${Pref.playerVolume.toStringAsFixed(0)}%',
                          style: subTitleStyle,
                        ),
                        onTap: () => showPlayerVolumeDialog(
                          context,
                          () => (context as Element).markNeedsBuild(),
                          onChanged: player.setVolume,
                        ),
                      ),
                    ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    spacing: 10,
                    children: [
                      Obx(() {
                        final flipX = plPlayerController.flipX.value;
                        return ActionRowLineItem(
                          iconData: Icons.flip,
                          onTap: () => plPlayerController.flipX.value = !flipX,
                          text: " 左右翻转 ",
                          selectStatus: flipX,
                        );
                      }),
                      Obx(() {
                        final flipY = plPlayerController.flipY.value;
                        return ActionRowLineItem(
                          iconData: Icons.flip_camera_android_outlined,
                          onTap: () => plPlayerController.flipY.value = !flipY,
                          text: " 上下翻转 ",
                          selectStatus: flipY,
                        );
                      }),
                      Obx(() {
                        final onlyAudio =
                            plPlayerController.onlyPlayAudio.value;
                        return ActionRowLineItem(
                          iconData: Icons.headphones,
                          onTap: _toggleAudioOnly,
                          text: " 听视频 ",
                          selectStatus: onlyAudio,
                        );
                      }),
                      if (PlatformUtils.isMobile)
                        Obx(
                          () => ActionRowLineItem(
                            iconData: Icons.play_circle_outline,
                            onTap:
                                plPlayerController.setContinuePlayInBackground,
                            text: " 后台播放 ",
                            selectStatus: plPlayerController
                                .continuePlayInBackground
                                .value,
                          ),
                        ),
                    ],
                  ),
                ),
                ListTile(
                  dense: true,
                  onTap: () {
                    Get.back();
                    showSetVideoQa();
                  },
                  leading: const Icon(Icons.play_circle_outline, size: 20),
                  title: const Text('选择画质', style: titleStyle),
                  subtitle: Obx(
                    () => Text(
                      controller.maxHeight.value == 0
                          ? '当前画质 最高'
                          : '当前画质 ${controller.maxHeight.value}P 以内',
                      style: subTitleStyle,
                    ),
                  ),
                ),
                PopupListTile(
                  dense: true,
                  leading: const Icon(Icons.repeat, size: 20),
                  title: const Text('播放顺序', style: titleStyle),
                  titleStyle: theme.textTheme.bodyLarge,
                  value: () {
                    final value = plPlayerController.playRepeat;
                    return (value, value.label);
                  },
                  itemBuilder: (_) => enumItemBuilder(PlayRepeat.values),
                  onSelected: (value, setState) {
                    plPlayerController.setPlayRepeat(value);
                    setState();
                  },
                  descPosType: .subtitle,
                  descStyle: subTitleStyle,
                ),
                ListTile(
                  dense: true,
                  onTap: () {
                    Get.back();
                    showSetSubtitle();
                  },
                  leading: const Icon(Icons.subtitles_outlined, size: 20),
                  title: const Text('字幕设置', style: titleStyle),
                ),
                // on-device subtitles are picked by language in the subtitle
                // menu, not started from here
                if (plPlayerController.videoPlayerController case final player?)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.info_outline, size: 20),
                    title: const Text('播放信息', style: titleStyle),
                    onTap: () => HeaderControlState.showPlayerInfo(
                      context,
                      player: player,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 选择画质 — the same panel shape as bilibili's, over the heights this
  /// video actually offers.
  void showSetVideoQa() {
    final heights = controller.availableHeights;
    showBottomSheet(
      (context, setState) {
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 14),
              children: [
                const SizedBox(
                  height: 45,
                  child: Center(child: Text('选择画质', style: titleStyle)),
                ),
                for (final height in heights)
                  Obx(
                    () => ListTile(
                      dense: true,
                      title: Text('${height}P', style: titleStyle),
                      selected: controller.maxHeight.value == height,
                      onTap: () {
                        Get.back();
                        controller.setMaxHeight(height);
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
