import 'dart:async' show scheduleMicrotask;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:get/get.dart';

/// What the row a paged list ends on ([LoadMoreFooter]) says.
enum LoadMoreStatus {
  /// No next page asked for since the last refresh: no row at all. A list
  /// that never pages (a search of local downloads) stays here.
  idle,

  /// "加载中…": the next page is on its way, or is about to be asked for.
  loading,

  /// "没有更多了".
  end,

  /// The last load-more failed: its error, and a tap to try again.
  error,
}

abstract class CommonListController<R, T> extends CommonController<R, T> {
  int page = 1;
  bool isEnd = false;
  bool? hasFooter;

  /// LibrePili: the footer's state, for the lists on the common bases.
  /// Nothing used to show while the next page loaded, and a failed load-more
  /// was dropped, tried again only when the last item happened to be built
  /// again. Its own observable rather than a refresh of [loadingState]:
  /// redrawing the list builds its last item again, whose builder asks for
  /// the next page, so a page that keeps failing would retry itself in a
  /// loop.
  final Rx<LoadMoreStatus> loadMoreStatus = LoadMoreStatus.idle.obs;

  /// Why the last load-more failed; shown in the footer until the next try.
  String? loadMoreError;

  /// The footer's 点击重试. [loadMore] is the page's own way of asking for
  /// the next page, where it does more than [onLoadMore] (fav_sort copies
  /// each page into the list it is sorting).
  Future<void> retryLoadMore([Future<void> Function()? loadMore]) {
    loadMoreError = null;
    loadMoreStatus.value = LoadMoreStatus.loading;
    return (loadMore ?? onLoadMore)();
  }

  @override
  Rx<LoadingState<List<T>?>> loadingState =
      LoadingState<List<T>?>.loading().obs;

  void handleListResponse(List<T> dataList) {}

  List<T>? getDataList(R response) {
    return response as List<T>?;
  }

  void checkIsEnd(int length) {}

  // bumped by every refresh: a response of an older request (a load-more or
  // refresh still in flight) is dropped, so it can neither append a page to
  // the new list nor advance [page]
  int _generation = 0;

  // A refresh already in flight is shared instead of raced: a fast second
  // pull would otherwise send a second request only to throw one away.
  // [_generation] still drops a stale response when a new request *is* made.
  Future<void>? _refreshing;

  // Set by [markRefreshStale]: the request parameters changed, so attaching
  // to the refresh in flight would answer with data fetched for the old ones.
  bool _refreshIsStale = false;

  /// Call before [onRefresh] when the next request differs from the one that
  /// may still be in flight (a new search keyword, a sort order, a different
  /// account): that one must not be attached to, it is answering the old
  /// parameters. [onReload] does this itself.
  void markRefreshStale() => _refreshIsStale = true;

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (!isRefresh) return _queryData(false);
    final stale = _refreshIsStale;
    _refreshIsStale = false;
    final refreshing = _refreshing;
    if (!stale && refreshing != null) return refreshing;
    final future = _queryData(true);
    _refreshing = future;
    return future.whenComplete(() {
      // a stale refresh that replaced this one owns the slot now
      if (identical(_refreshing, future)) _refreshing = null;
    });
  }

  Future<void> _queryData(bool isRefresh) async {
    if (!isRefresh && (isLoading || isEnd)) return;
    final generation = isRefresh ? ++_generation : _generation;
    isLoading = true;
    // a load-more is usually asked for by the builder of the list's last
    // item, in the middle of a layout, where an observable must not change:
    // the footer learns of it once the frame is done
    if (!isRefresh) {
      scheduleMicrotask(() {
        if (generation == _generation && isLoading) {
          loadMoreStatus.value = LoadMoreStatus.loading;
        }
      });
    }
    String? failure;
    // a throw anywhere below (the subclass parsing hooks too) would
    // otherwise leave [isLoading] set for good
    try {
      LoadingState<R> res;
      try {
        res = await customGetData();
      } catch (e) {
        res = Error(e.toString());
      }
      if (generation != _generation) return;
      if (res case Success(:final response)) {
        if (!customHandleResponse(isRefresh, res)) {
          final dataList = getDataList(response);
          if (dataList == null || dataList.isEmpty) {
            isEnd = true;
            if (isRefresh) {
              loadingState.value = Success(dataList);
            } else if (hasFooter == true) {
              loadingState.refresh();
            }
            return;
          }
          handleListResponse(dataList);
          if (isRefresh) {
            checkIsEnd(dataList.length);
            loadingState.value = Success(dataList);
          } else if (loadingState.value case Success(:final response)) {
            response!.addAll(dataList);
            checkIsEnd(response.length);
            loadingState.refresh();
          }
        }
        page++;
      } else {
        if (isRefresh && !handleError(res is Error ? res.errMsg : null)) {
          loadingState.value = res as Error;
        } else if (!isRefresh) {
          failure = (res is Error ? res.errMsg : null) ?? '加载失败';
        }
      }
    } catch (e) {
      if (!isRefresh) failure = e.toString();
      rethrow;
    } finally {
      // a stale load leaves the flag to the refresh that replaced it
      if (generation == _generation) {
        isLoading = false;
        loadMoreError = failure;
        // a refresh says nothing, whatever isEnd: "没有更多了" is the end
        // a load-more reached, not every list that fits on one page
        loadMoreStatus.value = isRefresh
            ? LoadMoreStatus.idle
            : failure != null
            ? LoadMoreStatus.error
            : isEnd
            ? LoadMoreStatus.end
            : LoadMoreStatus.loading;
      }
    }
  }

  @override
  Future<void> onRefresh() {
    page = 1;
    isEnd = false;
    return super.onRefresh();
  }

  @override
  Future<void> onReload() {
    markRefreshStale();
    loadingState.value = LoadingState<List<T>?>.loading();
    return super.onReload();
  }
}
