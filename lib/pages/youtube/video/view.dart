/// LibrePili — YouTube, stage 3: the watch page.
///
/// Laid out like the bilibili video page: the player on top, then 简介 / 评论
/// as tabs, with the related shelf under the description. What a YouTube
/// video does not have — danmaku, coins, the season list — simply is not
/// there.
library;

import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/pages/video/widgets/asr_entry.dart';
import 'package:PiliPlus/pages/youtube/video/controller.dart';
import 'package:PiliPlus/pages/youtube/video/header_control.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/view/view.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/bottom_control.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/common_btn.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/play_pause_btn.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtVideoPage extends StatefulWidget {
  const YtVideoPage({super.key});

  @override
  State<YtVideoPage> createState() => _YtVideoPageState();
}

class _YtVideoPageState extends State<YtVideoPage>
    with TickerProviderStateMixin {
  late final String videoId =
      Get.parameters['id'] ?? (Get.arguments as String? ?? '');
  late final YtVideoController controller = Get.put(
    YtVideoController(videoId: videoId),
    tag: videoId,
  );
  late final TabController _sideTabs = TabController(length: 2, vsync: this)
    ..addListener(() {
      if (_sideTabs.index == 1) controller.ensureCommentsStarted();
    });
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() {
      // comments are fetched when the tab is first opened: most viewers never
      // open it, and it is a second network round trip
      if (_tabs.index == 1) controller.ensureCommentsStarted();
    });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(
      () => _scaffold(theme, controller.plPlayerController.isFullScreen.value),
    );
  }

  Widget _scaffold(ThemeData theme, bool isFullScreen) => Scaffold(
    backgroundColor: theme.colorScheme.surface,
    // no app bar at all: the back arrow and the menu live in the player's
    // own header, over the video, exactly as they do on the bilibili page.
    // A separate strip above the player is neither what this app looks like
    // nor what the space is for.
    body: isFullScreen
        ? _player(theme)
        : LayoutBuilder(
            builder: (context, box) {
              // the same split as the bilibili video page: on a wide window
              // the player keeps the left and the tabs take a side column,
              // rather than pushing everything below the fold
              final wide = box.maxWidth > box.maxHeight && box.maxWidth > 900;
              if (wide) {
                final panelWidth = math.min(420.0, box.maxWidth * 0.34);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: math.min(
                              (box.maxWidth - panelWidth) * 9 / 16,
                              box.maxHeight * 0.72,
                            ),
                            child: _player(theme),
                          ),
                          Expanded(child: _intro(theme, inSidePanel: true)),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: panelWidth,
                      child: _sidePanel(theme),
                    ),
                  ],
                );
              }
              // 16:9 of the width, but never taller than what is there: a
              // short window made the aspect box overflow the column
              final playerHeight = math.min(
                box.maxWidth * 9 / 16,
                box.maxHeight * 0.6,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(height: playerHeight, child: _player(theme)),
                  Expanded(child: _tabbed(theme)),
                ],
              );
            },
          ),
  );

  /// The wide layout's right column: 相关视频 / 评论, as on the bilibili page.
  Widget _sidePanel(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TabBar(
        controller: _sideTabs,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerHeight: 0,
        tabs: const [Tab(text: '相关视频'), Tab(text: '评论')],
      ),
      Expanded(
        child: TabBarView(
          controller: _sideTabs,
          children: [_relatedList(theme), _comments(theme)],
        ),
      ),
    ],
  );

  Widget _relatedList(ThemeData theme) => Obx(() {
    if (controller.related.isEmpty) {
      return Center(
        child: Text(
          '暂无相关视频',
          style: TextStyle(color: theme.colorScheme.outline),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: controller.related.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final item = controller.related[index];
        return YtVideoTile(
          item: item,
          onTap: () => Get.offAndToNamed(
            '/ytVideo',
            parameters: {'id': item.videoId},
          ),
        );
      },
    );
  });

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
            headerControl: YtHeaderControl(controller: controller),
            // the default bar is bilibili's and reaches for that page's
            // controller; this one carries only what a YouTube video has
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

  /// 简介 / 评论 — the same two tabs, in the same order, as the bilibili page.
  Widget _tabbed(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TabBar(
        controller: _tabs,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerHeight: 0,
        tabs: const [Tab(text: '简介'), Tab(text: '评论')],
      ),
      Expanded(
        child: TabBarView(
          controller: _tabs,
          children: [_intro(theme, inSidePanel: false), _comments(theme)],
        ),
      ),
    ],
  );

  /// The order the bilibili page uses: who made it and the follow button
  /// first, then the actions, then the title and its numbers.
  Widget _intro(ThemeData theme, {required bool inSidePanel}) => Obx(() {
    final detail = controller.detail.value;
    if (detail == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        Row(
          children: [
            Obx(() {
              // the player response has no avatar; the channel request that
              // follows the video fills it in
              final avatar = controller.channel.value?.avatar?.url;
              return GestureDetector(
                onTap: _openChannel,
                child: avatar == null
                    ? CircleAvatar(
                        radius: 20,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.person,
                          size: 22,
                          color: theme.colorScheme.outline,
                        ),
                      )
                    : NetworkImgLayer(
                        type: ImageType.avatar,
                        width: 40,
                        height: 40,
                        src: avatar,
                      ),
              );
            }),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: _openChannel,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    Obx(() {
                      final info = controller.channel.value;
                      if (info == null) return const SizedBox.shrink();
                      return Text(
                        [
                          ?info.subscriberText,
                          ?info.videoCountText,
                        ].join('    '),
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.outline,
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Obx(
              () => FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: controller.toggleSubscribe,
                child: Text(controller.subscribed.value ? '已订阅' : '订阅'),
              ),
            ),
            const SizedBox(width: 12),
            _action(
              theme,
              icon: Icons.closed_caption_outlined,
              label: '字幕',
              onTap: _pickCaption,
            ),
            _action(
              theme,
              icon: Icons.link,
              label: '复制链接',
              onTap: () => Utils.copyText(controller.shareUrl!),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(detail.title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(
              Icons.play_circle_outline,
              size: 13,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(width: 4),
            Text(
              detail.viewCount == null ? '-' : '${detail.viewCount}',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              detail.videoId,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
        if (controller.streams case final pair?) ...[
          const SizedBox(height: 4),
          Text(
            '来源 ${pair.sourceId} · ${pair.video?.qualityLabel ?? ''} '
            '${pair.video?.codec ?? ''} + ${pair.audio?.codec ?? ''}',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
          ),
        ],
        if (detail.description.isNotEmpty) ...[
          const SizedBox(height: 14),
          SelectableText(
            detail.description,
            style: theme.textTheme.bodySmall,
          ),
        ],
        // narrow layouts have no side column, so the shelf goes here
        if (!inSidePanel)
          Obx(() {
            if (controller.related.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                Text('相关视频', style: theme.textTheme.titleSmall),
                const SizedBox(height: 10),
                for (final item in controller.related)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: YtVideoTile(
                      item: item,
                      // replaces the page rather than stacking watch pages
                      onTap: () => Get.offAndToNamed(
                        '/ytVideo',
                        parameters: {'id': item.videoId},
                      ),
                    ),
                  ),
              ],
            );
          }),
      ],
    );
  });

  void _openChannel() {
    final channelId = controller.detail.value?.channelId;
    if (channelId == null || channelId.isEmpty) return;
    Get.toNamed('/ytChannel', parameters: {'id': channelId});
  }

  Widget _action(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) => Tooltip(
    message: label,
    child: IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 20, color: theme.colorScheme.outline),
    ),
  );

  Widget _comments(ThemeData theme) => Obx(() {
    final items = controller.comments;
    if (items.isEmpty) {
      return Center(
        child: controller.commentsLoading.value
            ? const CircularProgressIndicator()
            : Text(
                '暂无评论',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 300) {
          controller.loadMoreComments();
        }
        return false;
      },
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: items.length + (controller.hasMoreComments ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 20),
        itemBuilder: (context, index) {
          if (index >= items.length) {
            return const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return _comment(theme, items[index]);
        },
      ),
    );
  });

  Widget _comment(ThemeData theme, YtComment comment) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      NetworkImgLayer(
        type: ImageType.avatar,
        width: 32,
        height: 32,
        src: comment.authorAvatar?.url,
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    comment.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: comment.authorIsUploader
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                  ),
                ),
                if (comment.isPinned) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.push_pin_outlined,
                    size: 12,
                    color: theme.colorScheme.outline,
                  ),
                ],
                if (comment.publishedText case final posted?) ...[
                  const SizedBox(width: 6),
                  Text(
                    posted,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(
              comment.content,
              style: theme.textTheme.bodyMedium,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  if (comment.likeCountText case final likes?) ...[
                    Icon(
                      Icons.thumb_up_outlined,
                      size: 12,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      likes,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                  if (comment.replyCount > 0) ...[
                    const SizedBox(width: 12),
                    Text(
                      '${comment.replyCount} 条回复',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  /// A fixed height: the bar sits in a Column the player sizes tightly, and
  /// an intrinsically taller row overflowed it.
  Widget _controls(PlPlayerController player) => SizedBox(
    height: 30,
    child: Row(
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
          tooltip: '字幕',
          icon: Obx(
            () => Icon(
              controller.captionIndex.value == -1
                  ? Icons.closed_caption_off_outlined
                  : Icons.closed_caption,
              size: 20,
              color: Colors.white,
            ),
          ),
          onTap: () =>
              YtHeaderControl(controller: controller).showCaptions(context),
        ),
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
          onTap: () =>
              player.triggerFullScreen(status: !player.isFullScreen.value),
        ),
      ],
    ),
  );

  Future<void> _pickCaption() async {
    final chosen = await showModalBottomSheet<Object>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              dense: true,
              title: const Text('关闭字幕'),
              selected: controller.captionIndex.value == -1,
              onTap: () => Get.back(result: -1),
            ),
            // on-device transcription, for a video that offers no captions
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
                title: Text(_label(track)),
                selected: controller.captionIndex.value == index,
                onTap: () => Get.back(result: index),
              ),
          ],
        ),
      ),
    );
    if (chosen is int) await controller.setCaption(chosen);
  }

  static String _label(YtCaptionTrack track) =>
      track.name.isEmpty ? track.languageCode : track.name;

  @override
  void dispose() {
    _tabs.dispose();
    _sideTabs.dispose();
    Get.delete<YtVideoController>(tag: videoId);
    super.dispose();
  }
}
