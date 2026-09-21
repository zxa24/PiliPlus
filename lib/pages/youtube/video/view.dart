/// LibrePili — YouTube, stage 2: the watch page.
///
/// Minimal on purpose. It owns the player and the caption picker and nothing
/// else; recommendations, comments and subscriptions arrive with the platform
/// modes in stage 3.
library;

import 'package:PiliPlus/pages/youtube/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/bottom_control.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/common_btn.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/play_pause_btn.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/plugin/pl_player/view/view.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtVideoPage extends StatefulWidget {
  const YtVideoPage({super.key});

  @override
  State<YtVideoPage> createState() => _YtVideoPageState();
}

class _YtVideoPageState extends State<YtVideoPage> {
  late final String videoId =
      Get.parameters['id'] ?? (Get.arguments as String? ?? '');
  late final YtVideoController controller = Get.put(
    YtVideoController(videoId: videoId),
    tag: videoId,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text('YouTube'),
        actions: [
          IconButton(
            tooltip: '复制链接',
            onPressed: () => Utils.copyText(controller.shareUrl!),
            icon: const Icon(Icons.link),
          ),
          Obx(() {
            if (controller.captions.isEmpty) return const SizedBox.shrink();
            return IconButton(
              tooltip: '字幕',
              onPressed: _pickCaption,
              icon: Icon(
                controller.captionIndex.value >= 0
                    ? Icons.closed_caption
                    : Icons.closed_caption_off_outlined,
              ),
            );
          }),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: _player(theme)),
          Expanded(child: _info(theme)),
        ],
      ),
    );
  }

  Widget _player(ThemeData theme) => Obx(() {
    switch (controller.stage.value) {
      case YtPageStage.loading:
        return const ColoredBox(
          color: Colors.black,
          child: Center(child: CircularProgressIndicator()),
        );
      case YtPageStage.failed:
        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    controller.message.value,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: controller.load,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        );
      case YtPageStage.ready:
        final player = controller.plPlayerController;
        if (player.videoController == null) {
          return const ColoredBox(color: Colors.black);
        }
        return LayoutBuilder(
          builder: (context, box) => PLVideoPlayer(
            maxWidth: box.maxWidth,
            maxHeight: box.maxHeight,
            plPlayerController: player,
            headerControl: const SizedBox.shrink(),
            // the default control bar is bilibili's and reaches for that
            // page's controller; this one carries only what a YouTube video
            // has
            bottomControl: BottomControl(
              maxWidth: box.maxWidth,
              isFullScreen: player.isFullScreen.value,
              controller: player,
              buildBottomControl: () => _controls(player),
            ),
          ),
        );
    }
  });

  Widget _info(ThemeData theme) => Obx(() {
    final detail = controller.detail.value;
    if (detail == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(detail.title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          detail.author,
          style: TextStyle(color: theme.colorScheme.outline),
        ),
        if (controller.streams case final pair?) ...[
          const SizedBox(height: 8),
          Text(
            '来源 ${pair.sourceId} · '
            '${pair.video?.qualityLabel ?? ''} '
            '${pair.video?.codec ?? ''} + ${pair.audio?.codec ?? ''}',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.outline,
            ),
          ),
        ],
        if (detail.description.isNotEmpty) ...[
          const SizedBox(height: 16),
          SelectableText(
            detail.description,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  });


  Widget _controls(PlPlayerController player) => Row(
    children: [
      PlayOrPauseButton(plPlayerController: player),
      const SizedBox(width: 8),
      Obx(
        () => Text(
          '${DurationUtils.formatDuration(player.position.value)}'
          ' / '
          '${DurationUtils.formatDuration(player.duration.value)}',
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
      const Spacer(),
      ComBtn(
        width: 35,
        height: 30,
        tooltip: '全屏',
        icon: Obx(
          () => Icon(
            player.isFullScreen.value
                ? Icons.fullscreen_exit
                : Icons.fullscreen,
            size: 22,
            color: Colors.white,
          ),
        ),
        onTap: () => player.triggerFullScreen(
          status: !player.isFullScreen.value,
        ),
      ),
    ],
  );

  Future<void> _pickCaption() async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              dense: true,
              title: const Text('关闭字幕'),
              selected: controller.captionIndex.value < 0,
              onTap: () => Get.back(result: -1),
            ),
            for (final (index, track) in controller.captions.indexed)
              ListTile(
                dense: true,
                title: Text(_label(track)),
                selected: controller.captionIndex.value == index,
                onTap: () => Get.back(result: index),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) await controller.setCaption(chosen);
  }

  static String _label(YtCaptionTrack track) =>
      track.name.isEmpty ? track.languageCode : track.name;

  @override
  void dispose() {
    Get.delete<YtVideoController>(tag: videoId);
    super.dispose();
  }
}
