import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/space/space_cheese/data.dart';
import 'package:PiliPlus/models_new/space/space_cheese/item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class FavCheeseController
    extends CommonListController<SpaceCheeseData, SpaceCheeseItem> {
  final mid = Accounts.main.mid;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  List<SpaceCheeseItem>? getDataList(SpaceCheeseData response) {
    isEnd = response.page?.next == false;
    return response.items;
  }

  @override
  Future<LoadingState<SpaceCheeseData>> customGetData() =>
      FavHttp.favPugv(mid: mid, page: page);

  Future<void> onRemove(int index, int sid) async {
    // the row, not its index: the list may change while the request runs
    final item = loadingState.value.dataOrNull?.elementAtOrNull(index);
    final res = await FavHttp.delFavPugv(sid);
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
