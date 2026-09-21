/// LibrePili: a YouTube channel — its header, its uploads, and the follow
/// button that puts it in the local subscription list.
///
/// The list itself is [CommonListPageState]'s: loading, empty, failure,
/// pull-to-refresh and paging are inherited rather than written again here.
library;

import 'package:PiliPlus/common/skeleton/video_card_h.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/pages/common/common_list_page.dart';
import 'package:PiliPlus/pages/youtube/common/yt_list_controller.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_subscriptions.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtChannelController extends YtListController<YtSearchItem> {
  YtChannelController(this.channelId);

  final String channelId;

  /// Avatar, subscriber count, video count — they arrive with the first
  /// page, because a channel page is one request for both.
  final info = Rxn<YtChannelInfo>();

  final subscribed = false.obs;

  @override
  void onInit() {
    super.onInit();
    subscribed.value = YtSubscriptions.isFollowed(channelId);
  }

  @override
  Future<YtRoutedResult<YtPage<YtSearchItem>>> fetchFirst() async {
    final result = await router.run(
      (s) => (s as YtDirectSource).channelPage(channelId),
    );
    if (result.ok && result.value != null) {
      info.value = result.value!.info;
      return YtRoutedResult(YtResult.ok(result.value!.videos), result.source);
    }
    return YtRoutedResult(YtResult.failed(result.verdict), result.source);
  }

  @override
  Future<YtRoutedResult<YtPage<YtSearchItem>>> fetchMore(String token) =>
      router.run(
        (s) => (s as YtDirectSource).channelVideos(
          channelId,
          continuation: token,
        ),
      );

  Future<void> toggleSubscribe() async {
    final now = await YtSubscriptions.toggle(
      channelId,
      name: info.value?.name ?? channelId,
      avatar: info.value?.avatar?.url,
    );
    subscribed.value = now;
    SmartDialog.showToast(now ? '已订阅' : '已取消订阅');
  }
}

class YtChannelPageView extends StatefulWidget {
  const YtChannelPageView({super.key});

  @override
  State<YtChannelPageView> createState() => _YtChannelPageViewState();
}

class _YtChannelPageViewState
    extends
        CommonListPageState<
          YtChannelPageView,
          YtPage<YtSearchItem>,
          YtSearchItem
        > {
  late final String channelId = Get.parameters['id'] ?? '';

  @override
  late final YtChannelController controller = Get.put(
    YtChannelController(channelId),
    tag: channelId,
  );

  late final _gridDelegate = Grid.videoCardHDelegate();

  @override
  void initState() {
    super.initState();
    controller.queryData();
  }

  @override
  void dispose() {
    Get.delete<YtChannelController>(tag: channelId);
    super.dispose();
  }

  @override
  ScrollController? get scrollController => controller.scrollController;

  @override
  Widget? buildHeader() => SliverToBoxAdapter(child: _header(context));

  @override
  Widget get buildLoading => SliverGrid(
    gridDelegate: _gridDelegate,
    delegate: const SliverChildBuilderDelegate(childCount: 10, _skeleton),
  );

  static Widget _skeleton(BuildContext context, int index) =>
      const VideoCardHSkeleton();

  @override
  Widget buildList(List<YtSearchItem> list) => SliverGrid(
    gridDelegate: _gridDelegate,
    delegate: SliverChildBuilderDelegate(childCount: list.length, (
      context,
      index,
    ) {
      if (index == list.length - 1) controller.onLoadMore();
      final item = list[index];
      return YtVideoTile(
        item: item,
        onTap: () => Get.toNamed('/ytVideo', parameters: {'id': item.videoId}),
      );
    }),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Obx(() => Text(controller.info.value?.name ?? '频道')),
    ),
    body: super.build(context),
  );

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final info = controller.info.value;
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (info?.avatar?.url case final avatar?)
              NetworkImgLayer(
                type: ImageType.avatar,
                width: 56,
                height: 56,
                src: avatar,
              )
            else
              CircleAvatar(
                radius: 28,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                child: Icon(Icons.person, color: theme.colorScheme.outline),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    info?.name ?? channelId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [?info?.subscriberText, ?info?.videoCountText].join('    '),
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Obx(
              () => FilledButton.tonal(
                onPressed: controller.toggleSubscribe,
                child: Text(controller.subscribed.value ? '已订阅' : '订阅'),
              ),
            ),
          ],
        ),
      );
    });
  }
}
