/// LibrePili: the YouTube player's header, in the same place and with the
/// same gestures as the bilibili one.
///
/// It carries what a YouTube video actually has. Danmaku, chapters, episode
/// lists and SponsorBlock are bilibili's and are simply absent — but 听视频,
/// 投屏, 字幕, 画质 and 倍速 all exist here and now sit where a user of this
/// app already looks for them.
library;

import 'package:PiliPlus/pages/video/widgets/asr_entry.dart';
import 'package:PiliPlus/pages/youtube/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtHeaderControl extends StatelessWidget {
  const YtHeaderControl({super.key, required this.controller});

  final YtVideoController controller;

  PlPlayerController get player => controller.plPlayerController;

  @override
  Widget build(BuildContext context) {
    const style = ButtonStyle(
      padding: WidgetStatePropertyAll(EdgeInsets.zero),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            height: 34,
            child: IconButton(
              tooltip: '返回',
              style: style,
              onPressed: () => player.isFullScreen.value
                  ? player.triggerFullScreen(status: false)
                  : Get.back(),
              icon: const Icon(
                Icons.arrow_back_ios_new,
                size: 18,
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
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
          Obx(() {
            final onlyAudio = player.onlyPlayAudio.value;
            return SizedBox(
              width: 42,
              height: 34,
              child: IconButton(
                tooltip: '听视频',
                style: style,
                onPressed: () {
                  player.onlyPlayAudio.value = !onlyAudio;
                  player.videoPlayerController?.setProperty(
                    'file-local-options/vid',
                    onlyAudio ? 'auto' : 'no',
                  );
                },
                icon: Icon(
                  onlyAudio ? Icons.headphones : Icons.headphones_outlined,
                  size: 19,
                  color: Colors.white,
                ),
              ),
            );
          }),
          SizedBox(
            width: 42,
            height: 34,
            child: IconButton(
              tooltip: '投屏',
              style: style,
              onPressed: () => _cast(context),
              icon: const Icon(Icons.cast, size: 19, color: Colors.white),
            ),
          ),
          SizedBox(
            width: 42,
            height: 34,
            child: IconButton(
              tooltip: '更多',
              style: style,
              onPressed: () => _menu(context),
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

  void _cast(BuildContext context) {
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

  void _menu(BuildContext context) {
    const titleStyle = TextStyle(fontSize: 14);
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.closed_caption_outlined, size: 20),
              title: const Text('字幕', style: titleStyle),
              onTap: () {
                Get.back();
                showCaptions(context);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.high_quality_outlined, size: 20),
              title: const Text('选择画质', style: titleStyle),
              subtitle: Obx(
                () => Text(
                  controller.maxHeight.value == 0
                      ? '最高'
                      : '${controller.maxHeight.value}P 以内',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              onTap: () {
                Get.back();
                _quality(context);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.speed_outlined, size: 20),
              title: const Text('播放速度', style: titleStyle),
              onTap: () {
                Get.back();
                _speed(context);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.link, size: 20),
              title: const Text('复制链接', style: titleStyle),
              onTap: () {
                Get.back();
                Utils.copyText(controller.shareUrl!);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _quality(BuildContext context) {
    final heights = controller.availableHeights;
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final height in heights)
              Obx(
                () => ListTile(
                  dense: true,
                  title: Text('${height}P'),
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
  }

  void _speed(BuildContext context) {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final speed in speeds)
              ListTile(
                dense: true,
                title: Text('${speed}x'),
                selected: player.playbackSpeed == speed,
                onTap: () {
                  Get.back();
                  player.setPlaybackSpeed(speed);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Caption tracks plus on-device transcription — the same sheet the bottom
  /// bar's CC button opens.
  void showCaptions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Obx(
          () => ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                dense: true,
                title: const Text('关闭字幕'),
                selected: controller.captionIndex.value == -1,
                onTap: () {
                  Get.back();
                  controller.setCaption(-1);
                },
              ),
              if (controller.canTranscribe)
                AsrMenuTile(
                  session: controller.asrSession,
                  onStart: () {
                    Get.back();
                    AsrEntry.startFor(context, controller.startAsr);
                  },
                  onStop: () {
                    Get.back();
                    controller.stopAsr();
                  },
                ),
              for (final (index, track) in controller.captions.indexed)
                ListTile(
                  dense: true,
                  title: Text(
                    track.name.isEmpty ? track.languageCode : track.name,
                  ),
                  selected: controller.captionIndex.value == index,
                  onTap: () {
                    Get.back();
                    controller.setCaption(index);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
