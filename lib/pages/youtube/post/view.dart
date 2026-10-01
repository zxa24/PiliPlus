/// LibrePili: a YouTube post with its comments — what bilibili's 动态详情 is
/// for a dynamic (`dynamics_detail/view.dart`), laid out the same way: in a
/// tall window the post scrolls away above a 评论 tab bar and the comments;
/// in a wide one the post and the comments stand side by side, split by the
/// same 动态详情 ratio setting.
///
/// The comment section is [YtCommentPane] over [YtCommentsMixin] — the video
/// page's, not a copy — on the chrome bilibili's list uses. Only where the
/// comments come from differs: a post's are on `browse`, a video's on
/// `next`. bilibili's 转发 / 赞 tabs have no YouTube counterpart without an
/// account, so the tab bar has the one tab.
library;

import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/flutter/dyn_tab_bar.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/scroll_behavior.dart'
    show NoOverscrollIndicator;
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/youtube/channel/widgets/post_card.dart';
import 'package:PiliPlus/pages/youtube/comments/yt_comment_pane.dart';
import 'package:PiliPlus/pages/youtube/comments/yt_comments_controller.dart';
import 'package:PiliPlus/pages/youtube/common/yt_list_controller.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtPostController extends GetxController with YtCommentsMixin {
  YtPostController(this.params, {this.postId, YtPost? post})
    : router = YtSourceRouter(YtDirectSource.create()) {
    if (post != null) {
      loadingState.value = Success(post);
      commentCount.value = post.commentCountText;
    }
  }

  /// The count on the 评论 tab. The list's post carries it on its reply
  /// button; the detail page's copy of the post has no such button, so it
  /// is kept from whichever had it rather than dropped when the detail
  /// lands.
  final commentCount = RxnString();

  /// The `FEpost_detail` params the post's links carry.
  final String params;
  final String? postId;

  @override
  final YtSourceRouter router;

  /// The post. Shown at once when the list handed it over; the detail
  /// request is still made, for the comments token it carries.
  final loadingState = Rx<LoadingState<YtPost>>(LoadingState<YtPost>.loading());

  @override
  String get commentsKey => 'ytpost:${postId ?? params}';

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load() async {
    final result = await router.run(
      (s) => (s as YtDirectSource).postDetail(params),
    );
    if (isClosed) return;
    if (!result.ok || result.value == null) {
      if (loadingState.value is! Success) {
        loadingState.value = Error(ytMessageFor(result.verdict));
      }
      commentsError.value = ytMessageFor(result.verdict);
      return;
    }
    loadingState.value = Success(result.value!.post);
    commentCount.value ??= result.value!.post.commentCountText;
    commentsToken = result.value!.commentsToken;
    ensureCommentsStarted();
  }

  @override
  Future<YtRoutedResult<String?>> fetchCommentsBootstrap() async {
    final result = await router.run(
      (s) => (s as YtDirectSource).postDetail(params),
    );
    return YtRoutedResult(
      result.ok && result.value != null
          ? YtResult.ok(result.value!.commentsToken)
          : YtResult.failed(result.verdict),
      result.source,
    );
  }

  @override
  Future<YtResult<YtPage<YtComment>>> fetchCommentsPage(
    YouTubeVideoSource source,
    String token,
  ) => (source as YtDirectSource).postComments(token);
}

class YtPostPage extends StatefulWidget {
  const YtPostPage({super.key});

  @override
  State<YtPostPage> createState() => _YtPostPageState();
}

class _YtPostPageState extends State<YtPostPage>
    with SingleTickerProviderStateMixin {
  late final String params = Get.parameters['params'] ?? '';
  late final String? postId = Get.parameters['id'];

  late final YtPostController controller = Get.put(
    YtPostController(
      params,
      postId: postId,
      post: Get.arguments is YtPost ? Get.arguments as YtPost : null,
    ),
    tag: params,
  );

  // one tab; the controller is what DynTabBar's look needs
  late final _tabController = TabController(length: 1, vsync: this);

  late final List<double> _ratio = Pref.dynamicDetailRatio;

  @override
  void dispose() {
    _tabController.dispose();
    Get.delete<YtPostController>(tag: params);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.viewPaddingOf(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: Obx(
          () => Text(controller.loadingState.value.dataOrNull?.author ?? ''),
        ),
      ),
      body: Padding(
        padding: EdgeInsets.only(left: padding.left, right: padding.right),
        child: Obx(() {
          final state = controller.loadingState.value;
          return switch (state) {
            Loading() => m3eLoading,
            Error(:final errMsg) => scrollErrorWidget(
              errMsg: errMsg,
              onReload: controller.load,
            ),
            Success(:final response) =>
              size.isPortrait
                  ? _portrait(response, size.width)
                  : _wide(response, size.width, padding.bottom),
          };
        }),
      ),
    );
  }

  /// The 评论 tab bar, as bilibili's detail page draws its three.
  Widget _tabBar() {
    final theme = Theme.of(context);
    final count = controller.commentCount.value;
    return SizedBox(
      height: 40,
      child: DynTabBar(
        padding: .zero,
        indicatorSize: .tab,
        tabAlignment: .start,
        isScrollable: true,
        controller: _tabController,
        labelPadding: const .symmetric(horizontal: 12),
        dividerColor: theme.colorScheme.outline.withValues(alpha: 0.1),
        tabs: [
          Tab(text: count == null ? '评论' : '评论 $count'),
        ],
      ),
    );
  }

  Widget _comments() => Column(
    children: [
      _tabBar(),
      Expanded(child: YtCommentPane(controller: controller)),
    ],
  );

  Widget _portrait(YtPost post, double width) {
    final side = math.max(width / 2 - Grid.smallCardWidth, 0.0);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: side),
      child: NestedScrollView(
        scrollBehavior: const NoOverscrollIndicator(),
        headerSliverBuilder: (context, _) => [
          SliverToBoxAdapter(child: YtPostCard(post: post, isDetail: true)),
        ],
        body: _comments(),
      ),
    );
  }

  Widget _wide(YtPost post, double width, double bottom) {
    final side = math.max(width / 2 - Grid.smallCardWidth, 0.0) / 4;
    return Row(
      children: [
        Expanded(
          flex: _ratio[0].toInt(),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(left: side, bottom: bottom + 100),
                sliver: SliverToBoxAdapter(
                  child: YtPostCard(post: post, isDetail: true, band: false),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: _ratio[1].toInt(),
          child: Padding(
            padding: EdgeInsets.only(right: side),
            child: _comments(),
          ),
        ),
      ],
    );
  }
}
