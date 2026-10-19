import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:get/get.dart';

abstract class CommonDataController<R, T> extends CommonController<R, T> {
  @override
  Rx<LoadingState<T>> loadingState = LoadingState<T>.loading().obs;

  @override
  Future<void> queryData([bool isRefresh = true]) async {
    if (isLoading) return;
    isLoading = true;
    LoadingState<R> res;
    try {
      res = await customGetData();
    } catch (e) {
      // a parse error would otherwise leave [isLoading] set for good
      res = Error(e.toString());
    }
    if (res is Success<R>) {
      if (!customHandleResponse(isRefresh, res)) {
        loadingState.value = res as LoadingState<T>;
      }
    } else {
      if (isRefresh && !handleError(res is Error ? res.errMsg : null)) {
        loadingState.value = res as Error;
      }
    }
    isLoading = false;
  }

  @override
  Future<void> onReload() {
    loadingState.value = LoadingState<T>.loading();
    return super.onReload();
  }
}
