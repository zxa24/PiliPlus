/// LibrePili: a YouTube playlist — what opens from a playlist on a
/// channel's 播放列表 tab.
///
/// Built as bilibili's 合集 page is (what a 合集 card opens,
/// `member_season_series/view.dart`): a plain scaffold titled with the
/// list's name over the same list as the 投稿 tab, with [SpaceListHeader]'s
/// 共N视频 / 播放全部 row and [VideoCardHFrame] cards. YouTube has no play
/// queue here, so 播放全部 starts the first video.
library;

import 'package:PiliPlus/common/skeleton/video_card_h.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/space/space_header.dart';
import 'package:PiliPlus/common/widgets/space/space_list_header.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/pages/common/common_list_page.dart';
import 'package:PiliPlus/pages/youtube/common/yt_list_controller.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtPlaylistController extends YtListController<YtSearchItem> {
  YtPlaylistController(this.playlistId);

  final String playlistId;

  /// The header: title, owner, count. With the first page.
  final info = Rxn<YtPlaylistInfo>();

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  Future<YtRoutedResult<YtPage<YtSearchItem>>> fetchFirst() async {
    final result = await router.run(
      (s) => (s as YtDirectSource).playlist(playlistId),
    );
    if (result.ok && result.value != null) {
      info.value = result.value!.info ?? info.value;
      return YtRoutedResult(YtResult.ok(result.value!.videos), result.source);
    }
    return YtRoutedResult(YtResult.failed(result.verdict), result.source);
  }

  @override
  Future<YtRoutedResult<YtPage<YtSearchItem>>> fetchMore(String token) async {
    final result = await router.run(
      (s) => (s as YtDirectSource).playlist(playlistId, continuation: token),
    );
    return result.ok && result.value != null
        ? YtRoutedResult(YtResult.ok(result.value!.videos), result.source)
        : YtRoutedResult(YtResult.failed(result.verdict), result.source);
  }
}

class YtPlaylistPage extends StatefulWidget {
  const YtPlaylistPage({super.key});

  @override
  State<YtPlaylistPage> createState() => _YtPlaylistPageState();
}

class _YtPlaylistPageState
    extends
        CommonListPageState<YtPlaylistPage, YtPage<YtSearchItem>, YtSearchItem>
    with GridMixin {
  late final String playlistId = Get.parameters['id'] ?? '';
  late final String? title = Get.parameters['title'];

  @override
  late final YtPlaylistController controller = Get.put(
    YtPlaylistController(playlistId),
    tag: playlistId,
  );

  @override
  void dispose() {
    Get.delete<YtPlaylistController>(tag: playlistId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SimpleScaffold(
    appBar: AppBar(
      title: Obx(() => Text(controller.info.value?.title ?? title ?? '播放列表')),
    ),
    body: ViewSafeArea(child: buildBody(context)),
  );

  @override
  Widget get buildLoading => SliverPadding(
    // as bilibili's 合集 page, which shows the same list on its own
    padding: const EdgeInsets.only(top: 7),
    sliver: SliverGrid(
      gridDelegate: gridDelegate,
      delegate: SliverChildBuilderDelegate(
        childCount: 10,
        (context, _) => const VideoCardHSkeleton(),
      ),
    ),
  );

  @override
  Widget buildList(List<YtSearchItem> list) {
    final info = controller.info.value;
    final count = info?.count;
    final scheme = ColorScheme.of(context);
    final byline = [?info?.ownerName, ?info?.viewCountText].join(' · ');
    return SliverMainAxisGroup(
      slivers: [
        if (byline.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: GestureDetector(
                onTap: info?.ownerChannelId == null
                    ? null
                    : () => Get.toNamed(
                        '/ytChannel',
                        parameters: {'id': info!.ownerChannelId!},
                      ),
                child: Text(byline, style: SpaceExtraLine.style(scheme)),
              ),
            ),
          ),
        SpaceListHeader(
          count: count != null ? '共$count视频' : info?.countText,
          onPlayAll: () => Get.toNamed(
            '/ytVideo',
            parameters: {'id': list.first.videoId},
          ),
        ),
        SliverGrid.builder(
          gridDelegate: gridDelegate,
          itemCount: list.length,
          itemBuilder: (context, index) {
            if (index == list.length - 1) controller.onLoadMore();
            final item = list[index];
            return YtVideoTile(
              item: item,
              onTap: () =>
                  Get.toNamed('/ytVideo', parameters: {'id': item.videoId}),
            );
          },
        ),
      ],
    );
  }
}
