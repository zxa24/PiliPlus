/// LibrePili — YouTube, stage 3: the watch page.
///
/// Laid out like the bilibili video page: the player on top, then 简介 / 评论
/// as tabs, with the related shelf under the description. What a YouTube
/// video does not have — danmaku, coins, the season list — simply is not
/// there.
library;

import 'dart:math' as math;

import 'package:PiliPlus/common/skeleton/video_card_h.dart';
import 'package:PiliPlus/common/widgets/video_intro/intro_metrics.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/pages/local/fav_sheet.dart';
import 'package:PiliPlus/pages/video/widgets/on_device_menu.dart';
import 'package:PiliPlus/pages/video/widgets/subtitle_gate.dart';
import 'package:PiliPlus/pages/video/widgets/player_focus.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/action_item.dart';
import 'package:PiliPlus/pages/youtube/comments/yt_comment_pane.dart';
import 'package:PiliPlus/pages/youtube/video/controller.dart';
import 'package:PiliPlus/pages/youtube/video/header_control.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/view/view.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/bottom_control.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/common_btn.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/play_pause_btn.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/share_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/common/widgets/dialog/qr_share.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
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

  /// The same card metrics the rest of the app lists videos with.
  static const _cardExtent = 110.0;
  final _gridDelegate = Grid.videoCardHDelegate();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = controller.plPlayerController;
    final page = Obx(() => _scaffold(theme, player.isFullScreen.value));
    // the keyboard controls the player as on the bilibili page: without
    // this the page had no key handling at all, and the arrow keys only
    // moved focus from one button to the next
    if (!player.keyboardControl) return page;
    return PlayerFocus(
      plPlayerController: player,
      // no danmaku to send, nothing to check before playing
      onSendDanmaku: () {},
      canPlay: () => true,
      child: page,
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
        tabs: const [
          Tab(text: '相关视频'),
          Tab(text: '评论'),
        ],
      ),
      Expanded(
        child: TabBarView(
          controller: _sideTabs,
          children: [_relatedList(theme), YtCommentPane(controller: controller)],
        ),
      ),
    ],
  );

  Widget _relatedList(ThemeData theme) => Obx(() {
    // the same three states every other list in the app has: skeletons while
    // it loads, the reason when it fails, the list when it arrives. This was
    // a bare GridView that showed 「暂无相关视频」 for all three.
    if (controller.related.isEmpty) {
      if (controller.relatedError.value case final error?) {
        return HttpError(errMsg: error, onReload: controller.reloadRelated);
      }
      if (controller.relatedPending) {
        return GridView.builder(
          padding: const EdgeInsets.symmetric(vertical: 6),
          gridDelegate: _gridDelegate,
          itemCount: 6,
          itemBuilder: (_, _) => const VideoCardHSkeleton(),
        );
      }
      return Center(
        child: Text(
          '暂无相关视频',
          style: TextStyle(color: theme.colorScheme.outline),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      gridDelegate: _gridDelegate,
      itemCount: controller.related.length,
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
        // asrPending: transcription is a peer of the stream, so a video whose
        // subtitles are being generated is not ready until they start
        if (controller.asrPending.value) {
          // the same face as any other loading: waiting for subtitles is not
          // a different kind of wait to the user — with a way past it once it
          // has gone on a while (3A)
          return SubtitleGate(
            skippable: controller.asrGateSkippable.value,
            onSkip: controller.skipSubtitleGate,
          );
        }
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
        tabs: const [
          Tab(text: '简介'),
          Tab(text: '评论'),
        ],
      ),
      Expanded(
        child: TabBarView(
          controller: _tabs,
          children: [_intro(theme, inSidePanel: false), YtCommentPane(controller: controller)],
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
              final avatar = controller.extra.value?.ownerAvatar?.url;
              return GestureDetector(
                onTap: _openChannel,
                child: avatar == null
                    ? CircleAvatar(
                        radius: IntroMetrics.avatarSize / 2,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.person,
                          size: 20,
                          color: theme.colorScheme.outline,
                        ),
                      )
                    : NetworkImgLayer(
                        type: ImageType.avatar,
                        width: IntroMetrics.avatarSize,
                        height: IntroMetrics.avatarSize,
                        src: avatar,
                      ),
              );
            }),
            const SizedBox(width: IntroMetrics.avatarGap),
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
                      style: const TextStyle(
                        fontSize: IntroMetrics.ownerName,
                      ),
                    ),
                    Obx(() {
                      final subscribers =
                          controller.extra.value?.subscriberText;
                      if (subscribers == null) return const SizedBox.shrink();
                      return Text(
                        subscribers,
                        style: TextStyle(
                          fontSize: IntroMetrics.ownerSecondary,
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
                child: Text(
                  controller.subscribed.value ? '已订阅' : '订阅',
                  style: const TextStyle(fontSize: IntroMetrics.followButton),
                ),
              ),
            ),
            // 收藏 / 下载 / 分享 share this row with 订阅: bilibili gives the
            // actions a row of their own because it has five of them and
            // three carry counts. Three unlabelled ones on their own line
            // is a line of empty space.
            _actionRow(theme),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          detail.title,
          style: const TextStyle(fontSize: IntroMetrics.title),
        ),
        const SizedBox(height: 6),
        // 播放量 · 发布时间, the line the bilibili page puts under the title.
        // The date is not in the player response at all; it arrives with the
        // related shelf, so it appears a moment after the rest.
        Obx(() {
          final info = controller.extra.value;
          final views =
              info?.viewCountText ??
              (detail.viewCount == null ? null : '${detail.viewCount} views');
          final date = info?.dateText ?? info?.relativeDateText;
          final style = TextStyle(
            fontSize: IntroMetrics.stat,
            color: theme.colorScheme.outline,
          );
          return Row(
            children: [
              Icon(
                Icons.play_circle_outline,
                size: 13,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(width: 4),
              Text(views ?? '-', style: style),
              if (date != null) ...[
                const SizedBox(width: 12),
                Icon(
                  Icons.schedule_outlined,
                  size: 13,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Text(date, style: style),
              ],
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  detail.videoId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            ],
          );
        }),
        if (controller.streams case final pair?) ...[
          const SizedBox(height: 4),
          Text(
            '来源 ${pair.sourceId} · ${pair.video?.qualityLabel ?? ''} '
            '${pair.video?.codec ?? ''} + ${pair.audio?.codec ?? ''}',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
          ),
        ],
        if (detail.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          // bodySmall is 12; the bilibili description is 14 at 1.4, which is
          // why this read as the small print of the same page
          SelectableText(
            detail.description,
            style: const TextStyle(
              fontSize: IntroMetrics.description,
              height: IntroMetrics.descriptionHeight,
            ),
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
                  SizedBox(
                    // the card is laid out from its cover's aspect ratio, so
                    // it needs a height the way it gets one in a grid
                    height: _cardExtent,
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

  /// The three actions, sized to what they need rather than to the row:
  /// they sit next to the channel name, which must keep the rest.
  Widget _actionRow(ThemeData theme) => SizedBox(
    height: 48,
    width: 3 * 52,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Obx(
          () => ActionItem(
            icon: const Icon(FontAwesomeIcons.star),
            selectIcon: const Icon(FontAwesomeIcons.solidStar),
            onTap: _toggleFav,
            selectStatus: controller.isFav.value,
            semanticsLabel: '收藏',
            text: '收藏',
          ),
        ),
        Obx(
          () => ActionItem(
            icon: const Icon(FontAwesomeIcons.download),
            onTap: _download,
            selectStatus: false,
            semanticsLabel: '下载',
            text: controller.downloading.value ? '下载中' : '下载',
          ),
        ),
        ActionItem(
          icon: const Icon(FontAwesomeIcons.shareFromSquare),
          onTap: _share,
          selectStatus: false,
          semanticsLabel: '分享',
          text: '分享',
        ),
      ],
    ),
  );

  /// The same little dialog the bilibili page opens, with the entries that
  /// mean something here.
  void _share() {
    final url = controller.shareUrl!;
    final detail = controller.detail.value;
    showDialog<void>(
      context: context,
      builder: (_) => SimpleDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          ListTile(
            dense: true,
            title: const Text('复制链接', style: TextStyle(fontSize: 14)),
            onTap: () {
              Get.back();
              Utils.copyText(url);
            },
          ),
          ListTile(
            dense: true,
            title: const Text('分享为二维码', style: TextStyle(fontSize: 14)),
            onTap: () {
              Get.back();
              // where playback is, as YouTube's own share does with t=
              final at = controller.plPlayerController.position.value;
              showQrShare(
                context,
                url: at > 0 ? '$url&t=${at}s' : url,
                title: detail?.title,
              );
            },
          ),
          ListTile(
            dense: true,
            title: const Text('其它app打开', style: TextStyle(fontSize: 14)),
            onTap: () {
              Get.back();
              PiliAndroidHelper.openUrl(url);
            },
          ),
          if (PlatformUtils.isMobile)
            ListTile(
              dense: true,
              title: const Text('分享视频', style: TextStyle(fontSize: 14)),
              onTap: () {
                Get.back();
                ShareUtils.shareText(
                  detail == null
                      ? url
                      : '${detail.title} 频道: ${detail.author} - $url',
                );
              },
            ),
        ],
      ),
    );
  }

  Future<void> _download() => controller.download(context);

  /// The same folder sheet a bilibili video opens — one 收藏夹 holding both,
  /// since neither side has an account here.
  Future<void> _toggleFav() async {
    final now = await showLocalFavSheet(
      context,
      key: controller.favKey,
      data: controller.favData,
    );
    if (now != null) controller.isFav.value = now;
  }

  /// The bottom bar, carrying what the bilibili one carries and in the same
  /// order: play, time — then 画面比例, 字幕, 倍速, 画质, 全屏. The CC button
  /// lists the tracks and nothing else, exactly as it does there; loading a
  /// file, styling the text and transcribing all live in 更多设置.
  ///
  /// A fixed height: the bar sits in a Column the player sizes tightly, and
  /// an intrinsically taller row overflowed it.
  Widget _controls(PlPlayerController player) {
    final isFullScreen = player.isFullScreen.value;
    final width = isFullScreen ? 42.0 : 35.0;
    return SizedBox(
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
          Obx(() {
            final fit = player.videoFit.value;
            return _popup<VideoFitType>(
              tooltip: '画面比例',
              initialValue: fit,
              items: [
                for (final value in VideoFitType.values)
                  (value: value, label: value.desc, enabled: true),
              ],
              onSelected: player.toggleVideoFit,
              child: _popupLabel(fit.desc),
            );
          }),
          Obx(() {
            final captions = controller.captions;
            final canTranscribe = controller.canTranscribe;
            // The button used to disappear when a video had no captions —
            // which is precisely the video transcription exists for. Someone
            // looking for subtitles on such a video found no button at all
            // and no hint that the app could make one.
            if (captions.isEmpty && !canTranscribe) {
              return const SizedBox.shrink();
            }
            final index = controller.captionIndex.value;
            // read so the menu opens on what is current: the labels follow
            // the runs by themselves while it is open
            controller.asrSession.value?.state.value;
            controller.translation.session.value?.state.value;
            // the same menu as the bilibili player's (OnDeviceMenu)
            return PopupMenuButton<int>(
              tooltip: '字幕',
              requestFocus: false,
              initialValue: OnDeviceMenu.initialValue(controller),
              color: Colors.black.withValues(alpha: 0.8),
              constraints: OnDeviceMenu.constraints,
              itemBuilder: (context) => OnDeviceMenu.items(context, controller),
              child: SizedBox(
                width: width,
                height: 30,
                child: Icon(
                  index == -1
                      ? Icons.closed_caption_off_outlined
                      : Icons.closed_caption_off_rounded,
                  size: 22,
                  color: Colors.white,
                ),
              ),
            );
          }),
          Obx(
            () => _popup<double>(
              tooltip: '倍速',
              initialValue: player.playbackSpeed,
              items: [
                for (final speed in player.speedList)
                  (value: speed, label: '${speed}X', enabled: true),
              ],
              onSelected: player.setPlaybackSpeed,
              child: _popupLabel('${player.playbackSpeed}X'),
            ),
          ),
          Obx(() {
            final heights = controller.availableHeights;
            if (heights.isEmpty) return const SizedBox.shrink();
            final current = controller.maxHeight.value;
            return _popup<int>(
              tooltip: '画质',
              initialValue: current,
              items: [
                for (final height in heights)
                  (value: height, label: '${height}P', enabled: true),
              ],
              onSelected: controller.setMaxHeight,
              child: _popupLabel(current == 0 ? '自动' : '${current}P'),
            );
          }),
          ComBtn(
            width: width,
            height: 30,
            tooltip: isFullScreen ? '退出全屏' : '全屏',
            icon: Icon(
              isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
              size: 24,
              color: Colors.white,
            ),
            onTap: () => player.triggerFullScreen(status: !isFullScreen),
          ),
        ],
      ),
    );
  }

  /// A value no caption index can take, for the transcription row.

  /// The dark popup the bilibili bar uses for every one of these buttons.
  Widget _popup<T>({
    required String tooltip,
    required T initialValue,
    required List<({T value, String label, bool enabled})> items,
    required ValueChanged<T> onSelected,
    required Widget child,
    // labels that follow a state while the menu is open: a model download's
    // progress, read once when the menu opened, stood still
    Map<T, ValueGetter<String>> live = const {},
  }) => PopupMenuButton<T>(
    tooltip: tooltip,
    requestFocus: false,
    initialValue: initialValue,
    color: Colors.black.withValues(alpha: 0.8),
    onSelected: onSelected,
    itemBuilder: (context) => [
      for (final item in items)
        PopupMenuItem<T>(
          height: 35,
          padding: const EdgeInsets.only(left: 30, right: 10),
          value: item.value,
          enabled: item.enabled,
          child: switch (live[item.value]) {
            final label? => Obx(() => _popupItemText(label())),
            null => _popupItemText(item.label),
          },
        ),
    ],
    child: child,
  );

  static Widget _popupItemText(String text) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(color: Colors.white, fontSize: 13),
  );

  static Widget _popupLabel(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: 13),
    ),
  );

  @override
  void dispose() {
    _tabs.dispose();
    _sideTabs.dispose();
    Get.delete<YtVideoController>(tag: videoId);
    super.dispose();
  }
}
