/// LibrePili: a YouTube list, on the app's own list machinery.
///
/// [CommonListController] already knows how to page, refresh, coalesce two
/// refreshes into one, drop the answer to a request nobody is waiting for
/// any more, and say when a list has ended. None of that is about bilibili;
/// all of it was being re-written, differently and worse, in each YouTube
/// page. The only piece missing was a way to speak [LoadingState] instead of
/// [YtResult], and that is this file.
library;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';

/// The reading of a verdict that the UI shows. Kept next to the adapter so
/// every YouTube list fails with the same words.
String ytMessageFor(YtVerdict verdict) => switch (verdict.cause) {
  YtCause.ok => '',
  YtCause.contentUnavailable => '该内容无法访问（已删除、私有或地区限制）',
  YtCause.ipBlocked => '当前网络被 YouTube 限流，可稍后重试或切换来源',
  YtCause.transient => '网络错误，请重试',
  YtCause.clientBroken => 'YouTube 接口已变化，应用需要更新（${verdict.signal}）',
};

extension YtResultToLoadingState<T> on YtResult<T> {
  /// A verdict carries more than a message — which of the four causes fired
  /// decides whether a retry is worth offering — so it is turned into a
  /// [LoadingState] here rather than thrown away at each call site.
  LoadingState<T> get asLoadingState => ok && value != null
      ? Success<T>(value as T)
      : Error(ytMessageFor(verdict));
}

extension YtRoutedResultToLoadingState<T> on YtRoutedResult<T> {
  LoadingState<T> get asLoadingState => ok && value != null
      ? Success<T>(value as T)
      : Error(ytMessageFor(verdict));
}

/// A page of YouTube items reached by a continuation token.
///
/// Subclasses say only how to fetch the first page and how to fetch the
/// next; paging, refreshing and failing are the base's.
abstract class YtListController<T> extends CommonListController<YtPage<T>, T> {
  YtListController({YouTubeVideoSource? source})
    : router = YtSourceRouter(source ?? YtDirectSource.create());

  final YtSourceRouter router;

  String? continuation;

  /// The first page.
  Future<YtRoutedResult<YtPage<T>>> fetchFirst();

  /// The page after [token].
  Future<YtRoutedResult<YtPage<T>>> fetchMore(String token);

  @override
  Future<LoadingState<YtPage<T>>> customGetData() async {
    final token = continuation;
    final result = page == 1 || token == null
        ? await fetchFirst()
        : await fetchMore(token);
    return result.asLoadingState;
  }

  @override
  List<T>? getDataList(YtPage<T> response) => response.items;

  @override
  bool customHandleResponse(bool isRefresh, Success<YtPage<T>> response) {
    // the token travels with the page, so it is read here rather than in
    // each subclass's fetch
    continuation = response.response.continuation;
    return false;
  }

  @override
  void checkIsEnd(int length) {
    if (continuation == null) isEnd = true;
  }

  @override
  Future<void> onRefresh() {
    continuation = null;
    return super.onRefresh();
  }
}
