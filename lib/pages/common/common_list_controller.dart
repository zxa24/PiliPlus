import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:get/get.dart';

abstract class CommonListController<R, T> extends CommonController<R, T> {
  int page = 1;
  bool isEnd = false;
  bool? hasFooter;

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
    final LoadingState<R> res = await customGetData();
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
          isLoading = false;
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
      }
    }
    isLoading = false;
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
