/// LibrePili: a YouTube channel's page state — the header and which tabs
/// the channel has — and one list controller per tab.
///
/// Split the way bilibili's space is: [MemberController] holds the card and
/// the tab list, and each tab owns its list. The first request (the 视频
/// tab) brings the header and the tab list together, so its page is handed
/// to the 视频 tab rather than fetched a second time.
library;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/youtube/common/yt_list_controller.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_subscriptions.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart'
    show ExtendedNestedScrollViewState;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtChannelController extends GetxController
    with GetTickerProviderStateMixin {
  YtChannelController(this.channelId, {YouTubeVideoSource? source})
    : router = YtSourceRouter(source ?? YtDirectSource.create());

  final String channelId;
  final YtSourceRouter router;

  /// The header; Loading until the first page lands.
  final loadingState = Rx<LoadingState<YtChannelInfo?>>(
    LoadingState<YtChannelInfo?>.loading(),
  );

  YtChannelInfo? get info => loadingState.value.dataOrNull;

  /// The tabs this channel has, in the app's order — a channel that never
  /// streamed has no 直播, one with no posts no 帖子.
  List<YtChannelTab> tabs = const [];
  TabController? tabController;

  final scrollKey = GlobalKey<ExtendedNestedScrollViewState>();

  final subscribed = false.obs;

  /// The first page of a tab that has already been fetched (the 视频 tab's,
  /// which came with the header), for that tab to take instead of asking
  /// again.
  final _seeds = <YtChannelTab, YtChannelTabPage>{};

  YtChannelTabPage? takeSeed(YtChannelTab tab) => _seeds.remove(tab);

  @override
  void onInit() {
    super.onInit();
    subscribed.value = YtSubscriptions.isFollowed(channelId);
    load();
  }

  Future<void> load() async {
    final result = await router.run(
      (s) => (s as YtDirectSource).channelTab(channelId, YtChannelTab.videos),
    );
    if (isClosed) return;
    if (!result.ok || result.value == null) {
      loadingState.value = Error(ytMessageFor(result.verdict));
      return;
    }
    final page = result.value!;
    final listed = [
      for (final tab in YtChannelTab.values)
        if (page.tabs.containsKey(tab)) tab,
    ];
    // a response with no tab list at all still has its uploads
    tabs = listed.isEmpty ? const [YtChannelTab.videos] : listed;
    _seeds[YtChannelTab.videos] = page;
    tabController?.dispose();
    tabController = TabController(length: tabs.length, vsync: this);
    loadingState.value = Success(page.info);
  }

  Future<void> onReload() {
    loadingState.value = LoadingState<YtChannelInfo?>.loading();
    return load();
  }

  Future<void> toggleSubscribe() async {
    final now = await YtSubscriptions.toggle(
      channelId,
      name: info?.name ?? channelId,
      avatar: info?.avatar?.url,
    );
    subscribed.value = now;
    SmartDialog.showToast(now ? '已订阅' : '已取消订阅');
  }

  @override
  void onClose() {
    tabController?.dispose();
    super.onClose();
  }
}

/// One tab's list. Items are [YtSearchItem], [YtShortItem],
/// [YtPlaylistItem] or [YtPost] by tab.
class YtChannelTabController extends YtListController<Object> {
  YtChannelTabController(
    this.channelId,
    this.tab, {
    this.channelName,
    this.seed,
    super.source,
  });

  final String channelId;
  final YtChannelTab tab;

  /// The channel's name, for the lockups that leave it out (all of a
  /// channel's own) — see `parseRelatedVideos`.
  final String? channelName;

  /// A first page already fetched (the 视频 tab's came with the header),
  /// used once instead of a request.
  YtChannelTabPage? seed;

  /// The sort chips over the list (视频 / 直播), and which is in force.
  final chips = <YtSortChip>[].obs;
  final sortIndex = 0.obs;

  /// Set while a chip other than the first is chosen: the first page is
  /// then the chip's reload, not the tab's.
  String? _sortToken;

  String? get sortLabel => chips.isEmpty ? null : chips[sortIndex.value].text;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  YtPage<Object> _pageOf(YtChannelTabPage page) {
    if (page.chips.isNotEmpty && chips.isEmpty) {
      chips.value = page.chips;
      final selected = page.chips.indexWhere((c) => c.selected);
      sortIndex.value = selected < 0 ? 0 : selected;
    }
    return YtPage(page.items, page.continuation);
  }

  @override
  Future<YtRoutedResult<YtPage<Object>>> fetchFirst() async {
    if (seed case final first?) {
      seed = null;
      return YtRoutedResult(YtResult.ok(_pageOf(first)), router.direct);
    }
    final token = _sortToken;
    final result = await router.run(
      (s) => (s as YtDirectSource).channelTab(
        channelId,
        tab,
        continuation: token,
        channelName: channelName,
      ),
    );
    return result.ok && result.value != null
        ? YtRoutedResult(YtResult.ok(_pageOf(result.value!)), result.source)
        : YtRoutedResult(YtResult.failed(result.verdict), result.source);
  }

  @override
  Future<YtRoutedResult<YtPage<Object>>> fetchMore(String token) async {
    final result = await router.run(
      (s) => (s as YtDirectSource).channelTab(
        channelId,
        tab,
        continuation: token,
        channelName: channelName,
      ),
    );
    return result.ok && result.value != null
        ? YtRoutedResult(
            YtResult.ok(
              YtPage(result.value!.items, result.value!.continuation),
            ),
            result.source,
          )
        : YtRoutedResult(YtResult.failed(result.verdict), result.source);
  }

  /// The next sort chip, the way bilibili's sort button flips its order:
  /// 最新 → 最热门 → 最早 → 最新.
  Future<void> nextSort() {
    if (chips.isEmpty) return Future.value();
    sortIndex.value = (sortIndex.value + 1) % chips.length;
    final chip = chips[sortIndex.value];
    // the chip YouTube marked selected is the tab's own order: back to it
    // is the tab's first page, not a reload token
    _sortToken = chip.selected ? null : chip.token;
    return onReload();
  }
}
