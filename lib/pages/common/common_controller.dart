import 'dart:async';

import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/widgets.dart' show ScrollController;
import 'package:get/get.dart';

/// LibrePili: runs a refresh asked for by a tap (re-tapping the 首页 / 动态
/// tab, a double tap on it) behind the pull-to-refresh indicator of the
/// list [scrollController] scrolls, so that it is seen: it used to reload
/// with nothing on screen. The indicator calls its own `onRefresh`, the
/// same refresh a pull would run; [fallback] runs when there is no
/// indicator to show (no list laid out yet, a list without one).
Future<void> refreshWithIndicator(
  ScrollController scrollController,
  Future<void> Function() fallback,
) {
  final indicator = scrollController.hasClients
      ? scrollController.position.context.notificationContext
            ?.findAncestorStateOfType<RefreshIndicatorState>()
      : null;
  return indicator != null ? indicator.show() : fallback();
}

mixin ScrollOrRefreshMixin {
  ScrollController get scrollController;

  void animateToTop() => scrollController.animToTop();

  Future<void> onRefresh();

  /// [onRefresh] with the list's refresh indicator showing.
  Future<void> onRefreshShown() =>
      refreshWithIndicator(scrollController, onRefresh);

  void toTopOrRefresh() {
    if (scrollController.hasClients) {
      if (scrollController.position.pixels == 0) {
        EasyThrottle.throttle(
          'topOrRefresh',
          const Duration(milliseconds: 500),
          onRefreshShown,
        );
      } else {
        animateToTop();
      }
    }
  }
}

abstract class CommonController<R, T> extends GetxController
    with ScrollOrRefreshMixin {
  @override
  final ScrollController scrollController = ScrollController();

  bool isLoading = false;
  Rx<LoadingState> get loadingState;

  Future<LoadingState<R>> customGetData();

  Future<void> queryData([bool isRefresh = true]);

  bool customHandleResponse(bool isRefresh, Success<R> response) {
    return false;
  }

  bool handleError(String? errMsg) {
    return false;
  }

  @override
  Future<void> onRefresh() {
    return queryData();
  }

  Future<void> onLoadMore() {
    return queryData(false);
  }

  Future<void> onReload() {
    return onRefresh();
  }

  @override
  void onClose() {
    scrollController.dispose();
    super.onClose();
  }
}
