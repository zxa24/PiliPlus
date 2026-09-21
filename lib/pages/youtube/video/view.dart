/// LibrePili — YouTube, stage 3: the watch page.
///
/// Laid out like the bilibili video page: the player on top, then 简介 / 评论
/// as tabs, with the related shelf under the description. What a YouTube
/// video does not have — danmaku, coins, the season list — simply is not
/// there.
library;

import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/comments/comment_chrome.dart';
import 'package:PiliPlus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/models/common/badge_type.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/pages/local/fav_sheet.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/action_item.dart';
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
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/share_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
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
              final avatar = controller.extra.value?.ownerAvatar?.url;
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
                      final subscribers = controller.extra.value?.subscriberText;
                      if (subscribers == null) return const SizedBox.shrink();
                      return Text(
                        subscribers,
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
            // 收藏 / 下载 / 分享 share this row with 订阅: bilibili gives the
            // actions a row of their own because it has five of them and
            // three carry counts. Three unlabelled ones on their own line
            // is a line of empty space.
            _actionRow(theme),
          ],
        ),
        const SizedBox(height: 10),
        Text(detail.title, style: theme.textTheme.titleMedium),
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
            fontSize: 12,
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

  /// The comments pane. It is a [MiniScaffold] because 评论详情 opens as a
  /// sheet *inside* it, the way the bilibili page does it
  /// (reply/view.dart:245): the detail takes over the comment area and
  /// leaves the video where it is, rather than covering the window.
  Widget _comments(ThemeData theme) =>
      MiniScaffold(body: _commentList(theme));

  Widget _commentList(ThemeData theme) => Obx(() {
    final items = controller.comments;
    final error = controller.commentsError.value;

    if (items.isEmpty) {
      if (error != null) {
        // a failed request used to empty into 「暂无评论」, which is what a
        // video with comments turned off says: the two were the same screen
        return HttpError(errMsg: error, onReload: controller.retryComments);
      }
      if (controller.commentsLoading.value) {
        return ListView(
          padding: EdgeInsets.zero,
          children: CommentChrome.skeletons(CommentChrome.listSkeletons),
        );
      }
      return Center(
        child: Text(
          '暂无评论',
          style: TextStyle(color: theme.colorScheme.outline),
        ),
      );
    }

    return refreshIndicator(
      onRefresh: controller.refreshComments,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: items.length + 1,
        separatorBuilder: (_, _) => CommentChrome.itemDivider(theme),
        itemBuilder: (context, index) {
          if (index == items.length) return _commentsFooter(theme);
          return _thread(context, theme, items[index]);
        },
      ),
    );
  });

  /// What the bilibili list puts at the bottom: loading, the end, or the
  /// reason the next page did not arrive.
  Widget _commentsFooter(ThemeData theme) => Obx(() {
    final error = controller.commentsError.value;
    if (error == null && controller.hasMoreComments) {
      // reaching this row means the list has been scrolled to its end
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => controller.loadMoreComments(),
      );
    }
    return CommentChrome.pagingFooter(
      theme,
      isEnd: !controller.hasMoreComments,
      error: error,
      onRetry: controller.retryComments,
    );
  });

  /// A top-level comment with a preview of its replies under it, the way
  /// the bilibili page shows them: a rounded block, the first few replies as
  /// `name: text`, then 「共 N 条回复」. Tapping anywhere opens the thread.
  /// [host] is the row's own context, which is below the comment pane's
  /// MiniScaffold — the State's own context is above it, and using that
  /// would quietly send the detail back to being a window-wide route.
  Widget _thread(BuildContext host, ThemeData theme, YtComment comment) {
    // asking here means asking when the row is built, which is when it is
    // about to be seen — YouTube sends no replies with the comments, so a
    // preview costs one request per thread and twenty at once is not a page
    // opening, it is a page hanging
    controller.ensureRepliesPreview(comment);
    void more() => _commentMenu(comment);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        // the whole row opens the thread and long-press opens the menu,
        // exactly as on the bilibili item — a comment used to be inert
        // unless it happened to have replies
        onTap: () => _openThread(host, comment),
        onLongPress: more,
        onSecondaryTap: PlatformUtils.isMobile ? null : more,
        child: Padding(
          padding: CommentChrome.itemPadding,
          child: Obx(() {
            final loaded = controller.replies[comment.commentId];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _comment(theme, comment),
                if (comment.hasReplies)
                  Padding(
                    padding: const EdgeInsets.only(top: 5, bottom: 12),
                    child: _replyPreview(host, theme, comment, loaded),
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }

  /// 复制全部 / 自由复制 — what the bilibili long-press menu offers that a
  /// logged-out YouTube can also do. 删除 / 举报 / 置顶 need an account.
  void _commentMenu(YtComment comment) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxWidth: math.min(640, MediaQuery.sizeOf(context).shortestSide),
      ),
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              minLeadingWidth: 0,
              leading: const Icon(Icons.copy_all_outlined, size: 19),
              title: const Text('复制全部', style: TextStyle(fontSize: 14)),
              onTap: () {
                Get.back();
                Utils.copyText(comment.content);
              },
            ),
            ListTile(
              minLeadingWidth: 0,
              leading: const Icon(Icons.copy_outlined, size: 19),
              title: const Text('自由复制', style: TextStyle(fontSize: 14)),
              onTap: () {
                Get.back();
                _freeCopy(comment.content);
              },
            ),
            if (comment.authorChannelId?.isNotEmpty == true)
              ListTile(
                minLeadingWidth: 0,
                leading: const Icon(Icons.person_outline, size: 19),
                title: const Text('查看频道', style: TextStyle(fontSize: 14)),
                onTap: () {
                  Get
                    ..back()
                    ..toNamed(
                      '/ytChannel',
                      parameters: {'id': comment.authorChannelId!},
                    );
                },
              ),
          ],
        ),
      ),
    );
  }

  void _freeCopy(String message) => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      constraints: const BoxConstraints.tightFor(width: 380),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: SelectionArea(
          child: SingleChildScrollView(child: Text(message)),
        ),
      ),
    ),
  );

  /// bilibili's preview block: same indent, same rounded surface, same
  /// one-line-per-reply shape, and each row its own tap target.
  Widget _replyPreview(
    BuildContext host,
    ThemeData theme,
    YtComment comment,
    List<YtComment>? loaded,
  ) {
    const previewCount = 3;
    final shown = loaded == null
        ? const <YtComment>[]
        : loaded.take(previewCount).toList();
    // YouTube's own label is in the response's language ('962 replies'),
    // which is not this interface's. The number is the part worth keeping —
    // including when it is abbreviated ('1.2K'), which is exactly the case
    // the numeric replyCount reports as 0 rather than inventing a figure.
    final counted = comment.replyCountText == null
        ? null
        : RegExp(
            r'[\d][\d.,]*\s*[KMB]?',
            caseSensitive: false,
          ).firstMatch(comment.replyCountText!)?.group(0);
    final label = counted != null
        ? '共 $counted 条回复'
        : comment.replyCount > 0
        ? '共 ${comment.replyCount} 条回复'
        : '查看回复';
    // the count row is bilibili's "there are more than these" row: it is not
    // shown when the preview already is the whole thread
    final loading =
        loaded == null && controller.repliesLoading.contains(comment.commentId);
    final extraRow =
        loaded == null ||
        loading ||
        loaded.length > shown.length ||
        controller.hasMoreReplies(comment.commentId);
    final length = shown.length + (extraRow ? 1 : 0);
    return Padding(
      padding: const EdgeInsets.only(
        left: CommentChrome.previewIndent,
        right: 4,
      ),
      child: Material(
        animationDuration: Duration.zero,
        color: theme.colorScheme.onInverseSurface,
        borderRadius: const BorderRadius.all(
          Radius.circular(CommentChrome.previewRadiusValue),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, reply) in shown.indexed)
              InkWell(
                borderRadius: CommentChrome.previewRadius(index, length),
                onTap: () => _openThread(host, comment),
                child: Padding(
                  padding: CommentChrome.previewPadding(index, length),
                  child: Text.rich(
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    TextSpan(
                      style: TextStyle(
                        height: 1.6,
                        fontSize: 14,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.85,
                        ),
                      ),
                      children: [
                        TextSpan(
                          text: reply.author,
                          style: TextStyle(color: theme.colorScheme.primary),
                        ),
                        if (reply.authorIsUploader) ...[
                          const TextSpan(text: ' '),
                          const WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: PBadge(
                              text: 'UP',
                              size: PBadgeSize.small,
                              isStack: false,
                              fontSize: 9,
                              textScaleFactor: 1,
                            ),
                          ),
                        ],
                        const TextSpan(text: ': '),
                        TextSpan(text: reply.content),
                      ],
                    ),
                  ),
                ),
              ),
            if (extraRow)
              InkWell(
                borderRadius: CommentChrome.previewRadius(length - 1, length),
                onTap: () => _openThread(host, comment),
                child: Padding(
                  padding: CommentChrome.previewPadding(length - 1, length),
                  child: Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      if (loading) ...[
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 评论详情. It opens as a sheet inside the comment area's own
  /// [MiniScaffold] — which is what the bilibili page does
  /// (reply/view.dart:245) — so the video stays where it is and, in the
  /// wide layout, the detail stays inside the side panel. It was a route
  /// over the whole window, which is a different thing wearing the same
  /// title.
  ///
  /// [host] must be a context below that MiniScaffold, so it has to come
  /// from the row that was tapped rather than from the page.
  void _openThread(BuildContext host, YtComment comment) {
    final id = comment.commentId;
    controller.ensureRepliesPreview(comment);
    final scaffold = MiniScaffold.maybeOf(host);
    if (scaffold == null) {
      // the intro tab's related shelf has no scaffold of its own; falling
      // back keeps the thread reachable instead of silently doing nothing
      PageUtils.showVideoBottomSheet(
        host,
        maxWidth: 640,
        child: Builder(builder: (context) => _threadPanel(context, comment, id)),
      );
      return;
    }
    scaffold.showBottomSheet(
      constraints: const BoxConstraints(),
      (context) => _threadPanel(context, comment, id),
    );
  }

  Widget _threadPanel(BuildContext context, YtComment comment, String id) {
    final theme = Theme.of(context);
    return Material(
      color: theme.canvasColor,
      child: Column(
        children: [
          CommentChrome.panelHeader(theme, title: '评论详情'),
          Expanded(child: _threadBody(theme, comment, id)),
        ],
      ),
    );
  }

  Widget _threadBody(ThemeData theme, YtComment comment, String id) =>
      refreshIndicator(
        onRefresh: () => controller.refreshReplies(comment),
        child: Obx(() {
          final loaded = controller.replies[id];
          final loading = controller.repliesLoading.contains(id);
          final error = controller.repliesError[id];
          final replies = loaded ?? const <YtComment>[];

          // the head comment, then a thick rule, then the count line — the
          // order bilibili's panel puts them in
          final head = <Widget>[
            Padding(
              padding: CommentChrome.itemPadding,
              child: _comment(theme, comment),
            ),
            CommentChrome.thickDivider(theme),
            CommentChrome.countLine(_replyCountLine(comment, replies.length)),
          ];

          if (error != null && replies.isEmpty) {
            return ListView(
              children: [
                ...head,
                SizedBox(
                  height: 300,
                  child: HttpError(
                    errMsg: error,
                    onReload: () => controller.refreshReplies(comment),
                  ),
                ),
              ],
            );
          }

          if (replies.isEmpty && loading) {
            return ListView(
              children: [
                ...head,
                ...CommentChrome.skeletons(CommentChrome.panelSkeletons),
              ],
            );
          }

          return ListView.separated(
            padding: EdgeInsets.zero,
            itemCount: head.length + replies.length + 1,
            separatorBuilder: (context, index) => index < head.length - 1
                ? const SizedBox.shrink()
                : CommentChrome.itemDivider(theme),
            itemBuilder: (context, index) {
              if (index < head.length) return head[index];
              final replyIndex = index - head.length;
              if (replyIndex < replies.length) {
                // full-size items, as in bilibili's panel: a reply here is
                // not a footnote to the comment above it
                return Padding(
                  padding: CommentChrome.itemPadding,
                  child: _comment(theme, replies[replyIndex]),
                );
              }
              if (controller.hasMoreReplies(id) && !loading) {
                // reaching this row means the end of the loaded replies is
                // on screen, which is how the comment list pages too
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => controller.loadMoreReplies(id),
                );
              }
              return CommentChrome.pagingFooter(
                theme,
                isEnd: !loading && !controller.hasMoreReplies(id),
                error: error,
                onRetry: () => controller.refreshReplies(comment),
                emptyText: replies.isEmpty ? '没有取到回复' : '没有更多了',
              );
            },
          );
        }),
      );

  /// 「相关回复共N条」, preferring YouTube's own total over how many have
  /// been loaded so far — the loaded count would climb as you scroll and
  /// read as the thread growing.
  static String _replyCountLine(YtComment comment, int loaded) {
    final counted = comment.replyCountText == null
        ? null
        : RegExp(
            r'[\d][\d.,]*\s*[KMB]?',
            caseSensitive: false,
          ).firstMatch(comment.replyCountText!)?.group(0);
    if (counted != null) return '相关回复共 $counted 条';
    if (comment.replyCount > 0) return '相关回复共 ${comment.replyCount} 条';
    return loaded > 0 ? '相关回复共 $loaded 条' : '相关回复';
  }

  Widget _comment(
    ThemeData theme,
    YtComment comment, {
    double avatar = 34,
  }) {
    void openChannel() {
      final channelId = comment.authorChannelId;
      if (channelId == null || channelId.isEmpty) return;
      feedBack();
      Get.toNamed('/ytChannel', parameters: {'id': channelId});
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: openChannel,
          child: NetworkImgLayer(
            type: ImageType.avatar,
            width: avatar,
            height: avatar,
            src: comment.authorAvatar?.url,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // name on one line, time on the next — the shape the bilibili
              // item uses. Side by side, a 13pt name and an 11pt time sit on
              // different baselines and read as misaligned, which is what
              // they were.
              GestureDetector(
                onTap: openChannel,
                behavior: HitTestBehavior.opaque,
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
                              fontSize: 13,
                              color: comment.authorIsUploader
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                            ),
                          ),
                        ),
                        if (comment.authorIsUploader) ...[
                          const SizedBox(width: 6),
                          const PBadge(
                            text: 'UP',
                            size: PBadgeSize.small,
                            isStack: false,
                            fontSize: 9,
                            textScaleFactor: 1,
                          ),
                        ],
                        if (comment.isPinned) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.push_pin_outlined,
                            size: 12,
                            color: theme.colorScheme.outline,
                          ),
                        ],
                      ],
                    ),
                    if (comment.publishedText case final posted?)
                      Text(
                        posted,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // not selectable: the row's own tap opens the thread and its
              // long-press opens 复制全部 / 自由复制, which is how the
              // bilibili item does copying. A SelectableText here would eat
              // both gestures.
              Text(
                comment.content,
                style: const TextStyle(fontSize: 14, height: 1.75),
              ),
              if (comment.likeCountText case final likes?)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.thumb_up_outlined,
                        size: 14,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        likes,
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
        ),
      ],
    );
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
            if (captions.isEmpty) return const SizedBox.shrink();
            final index = controller.captionIndex.value;
            return _popup<int>(
              tooltip: '字幕',
              initialValue: index,
              items: [
                (value: -1, label: '关闭字幕', enabled: true),
                for (final (i, track) in captions.indexed)
                  (value: i, label: _label(track), enabled: true),
              ],
              onSelected: controller.setCaption,
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

  /// The dark popup the bilibili bar uses for every one of these buttons.
  Widget _popup<T>({
    required String tooltip,
    required T initialValue,
    required List<({T value, String label, bool enabled})> items,
    required ValueChanged<T> onSelected,
    required Widget child,
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
          child: Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
    ],
    child: child,
  );

  static Widget _popupLabel(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: 13),
    ),
  );

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
