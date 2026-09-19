import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/fav/fav_article/data.dart';
import 'package:PiliPlus/models_new/fav/fav_article/item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class FavArticleController
    extends CommonListController<FavArticleData, FavArticleItemModel> {
  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  List<FavArticleItemModel>? getDataList(FavArticleData response) {
    if (response.hasMore == false) {
      isEnd = true;
    }
    return response.items;
  }

  @override
  Future<LoadingState<FavArticleData>> customGetData() =>
      FavHttp.favArticle(page: page);

  Future<void> onRemove(int index, String id) async {
    // the row, not its index: the list may change while the request runs
    final item = loadingState.value.dataOrNull?.elementAtOrNull(index);
    final res = await FavHttp.communityAction(opusId: id, action: 4);
    if (res.isSuccess) {
      loadingState
        ..value.dataOrNull?.remove(item)
        ..refresh();
      SmartDialog.showToast('已取消收藏');
    } else {
      res.toast();
    }
  }
}
