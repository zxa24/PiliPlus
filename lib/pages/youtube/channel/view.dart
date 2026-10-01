/// LibrePili: a YouTube channel — the page bilibili's UP主空间 is, built
/// from the same pieces.
///
/// [SpaceShell] (the collapsing header and the tab bar), [SpaceHeaderCard]
/// and its parts (banner, avatar, counts, follow button, name, sign),
/// [SpaceListHeader] over the video lists, [VideoCardHFrame] for every video
/// and playlist, [PortraitCardFrame] for the Shorts, [DynCardFrame] for the
/// posts — all imported by the bilibili space too, so the two pages change
/// together. What is YouTube's own is the data and what each tab shows:
/// 视频 / Shorts / 直播 / 播放列表 / 帖子, the tabs this channel has.
///
/// Each tab's list is [CommonListPageState]'s, as bilibili's 合集 and 动态
/// tabs are now: loading, empty, failure, pull-to-refresh and paging are
/// written once.
library;

import 'package:PiliPlus/common/skeleton/video_card_h.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/space/space_header.dart';
import 'package:PiliPlus/common/widgets/space/space_list_header.dart';
import 'package:PiliPlus/common/widgets/space/space_shell.dart';
import 'package:PiliPlus/common/widgets/video_card/portrait_card_frame.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/image_preview_type.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/pages/common/common_list_page.dart';
import 'package:PiliPlus/pages/youtube/channel/controller.dart';
import 'package:PiliPlus/pages/youtube/channel/widgets/post_card.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/waterfall.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:waterfall_flow/waterfall_flow.dart'
    hide SliverWaterfallFlowDelegateWithMaxCrossAxisExtent;

class YtChannelPageView extends StatefulWidget {
  const YtChannelPageView({super.key});

  @override
  State<YtChannelPageView> createState() => _YtChannelPageViewState();
}

class _YtChannelPageViewState extends State<YtChannelPageView> {
  late final String channelId = Get.parameters['id'] ?? '';

  late final YtChannelController controller = Get.put(
    YtChannelController(channelId),
    tag: channelId,
  );

  @override
  void dispose() {
    for (final tab in YtChannelTab.values) {
      final tag = _tabTag(channelId, tab);
      if (Get.isRegistered<YtChannelTabController>(tag: tag)) {
        Get.delete<YtChannelTabController>(tag: tag);
      }
    }
    Get.delete<YtChannelController>(tag: channelId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    color: ColorScheme.of(context).surface,
    child: Obx(
      () => switch (controller.loadingState.value) {
        Loading() => SpaceShell.loading,
        Success(:final response) => SpaceShell(
          scrollKey: controller.scrollKey,
          title: Text(response?.name ?? '频道'),
          onTitleTap: controller.onReload,
          header: response == null
              ? null
              : YtChannelHeader(info: response, controller: controller),
          tabs: [for (final tab in controller.tabs) Tab(text: tab.label)],
          tabController: controller.tabController,
          children: [
            for (final tab in controller.tabs)
              _YtChannelTabPage(
                key: ValueKey(tab),
                channelId: channelId,
                channelName: response?.name,
                tab: tab,
              ),
          ],
        ),
        Error(:final errMsg) => SpaceShell.error(errMsg, controller.onReload),
      },
    ),
  );
}

String _tabTag(String channelId, YtChannelTab tab) => '$channelId/${tab.name}';

/// The channel's header: [SpaceHeaderCard] with YouTube's facts in it.
class YtChannelHeader extends StatelessWidget {
  const YtChannelHeader({
    super.key,
    required this.info,
    required this.controller,
  });

  final YtChannelInfo info;
  final YtChannelController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.of(context);
    final avatar = info.avatar?.url;
    return SpaceHeaderCard(
      banner: SpaceBanner(url: info.banner?.url),
      avatar: SpaceAvatarRing(
        child: GestureDetector(
          onTap: avatar == null
              ? null
              : () => PageUtils.imageView(imgList: [SourceModel(url: avatar)]),
          child: NetworkImgLayer(
            type: ImageType.avatar,
            width: kAvatarSize,
            height: kAvatarSize,
            src: avatar,
          ),
        ),
      ),
      left: (_) => [
        SpaceName(name: info.name, onTap: () => Utils.copyText(info.name)),
        if (info.description case final d? when d.isNotEmpty) SpaceSign(d),
        SpaceExtraLine(
          children: [
            if (info.handle case final handle?)
              GestureDetector(
                onTap: () => Utils.copyText(handle),
                child: Text(handle, style: SpaceExtraLine.style(scheme)),
              ),
            if (info.link case final link?)
              GestureDetector(
                onTap: () => PageUtils.launchURL(
                  link.startsWith('http') ? link : 'https://$link',
                ),
                child: Text(
                  link,
                  style: SpaceExtraLine.style(scheme, link: true),
                ),
              ),
          ],
        ),
      ],
      actions: SpaceActions(
        counts: [
          _count(info.subscriberText, '订阅者'),
          _count(info.videoCountText, '视频'),
        ],
        follow: Obx(() {
          final subscribed = controller.subscribed.value;
          return SpaceFollowButton(
            label: subscribed ? '已订阅' : '订阅',
            followed: subscribed,
            onPressed: controller.toggleSubscribe,
          );
        }),
      ),
    );
  }

  /// YouTube's text ('2560万位订阅者', '391 个视频') split into the number
  /// and a fixed label, so the counts read like bilibili's (2560万 / 订阅者).
  /// The number is kept as YouTube wrote it — abbreviated, localised —
  /// because turning it into a figure would invent precision.
  static SpaceCount _count(String? text, String label) {
    final match = RegExp(
      r'^\s*([\d.,]+\s*[万亿千KMBkmb]?)',
    ).firstMatch(text ?? '');
    return SpaceCount(
      value: match?.group(1)?.trim() ?? (text ?? '-'),
      label: label,
      detail: text,
    );
  }
}

/// One tab of the channel.
class _YtChannelTabPage extends StatefulWidget {
  const _YtChannelTabPage({
    super.key,
    required this.channelId,
    required this.channelName,
    required this.tab,
  });

  final String channelId;
  final String? channelName;
  final YtChannelTab tab;

  @override
  State<_YtChannelTabPage> createState() => _YtChannelTabPageState();
}

class _YtChannelTabPageState
    extends CommonListPageState<_YtChannelTabPage, YtPage<Object>, Object>
    with AutomaticKeepAliveClientMixin, GridMixin, DynMixin {
  YtChannelTab get tab => widget.tab;

  late final _channel = Get.find<YtChannelController>(tag: widget.channelId);

  @override
  late final YtChannelTabController controller = Get.put(
    YtChannelTabController(
      widget.channelId,
      tab,
      channelName: widget.channelName,
      seed: _channel.takeSeed(tab),
      // the channel's own source: it holds the tab params the first
      // response listed, which every later tab is asked for with
      source: _channel.router.direct,
    ),
    tag: _tabTag(widget.channelId, tab),
  );

  @override
  bool get wantKeepAlive => true;

  // inside the space's nested scroll, as bilibili's tabs are
  @override
  bool get isClampingScrollPhysics => true;

  @override
  Widget wrapSliver(Widget sliver) => switch (tab) {
    YtChannelTab.posts => buildPage(sliver),
    YtChannelTab.shorts => SliverPadding(
      // as bilibili's 追番 grid sits
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      sliver: sliver,
    ),
    _ => sliver,
  };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return buildBody(context);
  }

  late final _shortsDelegate = PortraitCardFrame.gridDelegate(
    context,
    aspectRatio: 9 / 16,
    textExtent: 66,
  );

  @override
  Widget get buildLoading => switch (tab) {
    YtChannelTab.posts => dynSkeleton,
    YtChannelTab.shorts => SliverGrid(
      gridDelegate: _shortsDelegate,
      delegate: SliverChildBuilderDelegate(
        childCount: 12,
        (context, _) => const Card(),
      ),
    ),
    _ => SliverGrid(
      gridDelegate: gridDelegate,
      delegate: SliverChildBuilderDelegate(
        childCount: 10,
        (context, _) => const VideoCardHSkeleton(),
      ),
    ),
  };

  @override
  Widget buildList(List<Object> list) {
    Widget item(BuildContext context, int index) {
      if (index == list.length - 1) controller.onLoadMore();
      return switch (list[index]) {
        final YtSearchItem video => YtVideoTile(
          item: video,
          showAuthor: false,
          onTap: () =>
              Get.toNamed('/ytVideo', parameters: {'id': video.videoId}),
        ),
        final YtShortItem short => PortraitCardFrame(
          cover: short.bestThumbnail?.url,
          title: short.title,
          aspectRatio: 9 / 16,
          subtitle: short.viewCountText,
          onTap: () =>
              Get.toNamed('/ytVideo', parameters: {'id': short.videoId}),
        ),
        final YtPlaylistItem playlist => YtPlaylistCard(
          item: playlist,
          onTap: () => Get.toNamed(
            '/ytPlaylist',
            parameters: {'id': playlist.playlistId, 'title': playlist.title},
          ),
        ),
        final YtPost post => YtPostCard(post: post),
        _ => const SizedBox.shrink(),
      };
    }

    return switch (tab) {
      YtChannelTab.videos || YtChannelTab.streams => SliverMainAxisGroup(
        slivers: [
          Obx(
            () => SpaceListHeader(
              sortLabel: controller.sortLabel,
              onSort: controller.chips.isEmpty ? null : controller.nextSort,
            ),
          ),
          SliverGrid.builder(
            gridDelegate: gridDelegate,
            itemCount: list.length,
            itemBuilder: item,
          ),
        ],
      ),
      YtChannelTab.shorts => SliverGrid.builder(
        gridDelegate: _shortsDelegate,
        itemCount: list.length,
        itemBuilder: item,
      ),
      YtChannelTab.playlists => SliverGrid.builder(
        gridDelegate: gridDelegate,
        itemCount: list.length,
        itemBuilder: item,
      ),
      // the waterfall setting holds here as on bilibili's 动态
      YtChannelTab.posts =>
        GlobalData().dynamicsWaterfallFlow
            ? SliverWaterfallFlow(
                gridDelegate: dynGridDelegate,
                delegate: SliverChildBuilderDelegate(
                  item,
                  childCount: list.length,
                ),
              )
            : SliverList.builder(itemCount: list.length, itemBuilder: item),
    };
  }
}
