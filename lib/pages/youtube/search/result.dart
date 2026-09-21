/// LibrePili — YouTube search results, as a page of their own.
///
/// bilibili puts the keyword in the app bar and lets a tap on it take you
/// back to editing; the results sit in the same responsive grid the rest of
/// the app uses. This does both — and it does the loading, the empty state,
/// the failure, the pull-to-refresh and the paging by inheriting them from
/// [CommonListPageState] rather than writing a fifth version of each.
///
/// There is one tab where bilibili has six: a YouTube search returns videos,
/// channels and playlists in one stream and this reads the videos out of it.
/// A tab bar with a single tab is not alignment, it is decoration.
library;

import 'package:PiliPlus/common/skeleton/video_card_h.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/pages/common/common_list_page.dart';
import 'package:PiliPlus/pages/youtube/common/yt_list_controller.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtSearchResultController extends YtListController<YtSearchItem> {
  YtSearchResultController(this.keyword);

  final String keyword;

  @override
  Future<YtRoutedResult<YtPage<YtSearchItem>>> fetchFirst() =>
      router.run((s) => (s as YtDirectSource).search(keyword));

  @override
  Future<YtRoutedResult<YtPage<YtSearchItem>>> fetchMore(String token) =>
      router.run((s) => (s as YtDirectSource).searchContinuation(token));
}

class YtSearchResultPage extends StatefulWidget {
  const YtSearchResultPage({super.key});

  @override
  State<YtSearchResultPage> createState() => _YtSearchResultPageState();
}

class _YtSearchResultPageState
    extends
        CommonListPageState<
          YtSearchResultPage,
          YtPage<YtSearchItem>,
          YtSearchItem
        > {
  late final String keyword = Get.parameters['keyword'] ?? '';

  @override
  late final YtSearchResultController controller = Get.put(
    YtSearchResultController(keyword),
    tag: keyword,
  );

  late final _gridDelegate = Grid.videoCardHDelegate();

  @override
  void initState() {
    super.initState();
    controller.queryData();
  }

  @override
  void dispose() {
    Get.delete<YtSearchResultController>(tag: keyword);
    super.dispose();
  }

  @override
  ScrollController? get scrollController => controller.scrollController;

  @override
  Widget get buildLoading => SliverGrid(
    gridDelegate: _gridDelegate,
    delegate: const SliverChildBuilderDelegate(
      childCount: 10,
      _skeleton,
    ),
  );

  static Widget _skeleton(BuildContext context, int index) =>
      const VideoCardHSkeleton();

  @override
  Widget buildEmpty() => SliverToBoxAdapter(
    child: Container(
      height: 300,
      alignment: Alignment.center,
      child: Text(
        '没有找到「$keyword」',
        style: TextStyle(color: Theme.of(context).colorScheme.outline),
      ),
    ),
  );

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
        onTap: () =>
            Get.toNamed('/ytVideo', parameters: {'id': item.videoId}),
      );
    }),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        shape: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
        title: GestureDetector(
          // the same gesture as the bilibili result page: the keyword is the
          // way back into the box that produced it
          onTap: () => Get.offNamed(
            '/ytSearch',
            parameters: {'keyword': keyword},
          ),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: double.infinity,
            child: Text(
              keyword,
              style: theme.textTheme.titleMedium,
              maxLines: 1,
            ),
          ),
        ),
      ),
      body: ViewSafeArea(child: super.build(context)),
    );
  }
}
