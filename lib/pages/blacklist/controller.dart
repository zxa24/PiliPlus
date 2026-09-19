import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/http/black.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models_new/blacklist/data.dart';
import 'package:PiliPlus/models_new/blacklist/list.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class BlackListController
    extends CommonListController<BlackListData, BlackListItem> {
  RxInt total = (-1).obs;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  List<BlackListItem>? getDataList(BlackListData response) {
    total.value = response.total ?? 0;
    return response.list;
  }

  @override
  void checkIsEnd(int length) {
    if (length >= total.value) {
      isEnd = true;
    }
  }

  void onRemove(BuildContext context, int index, name, mid) {
    showConfirmDialog(
      context: context,
      title: Text('确定将 $name 移出黑名单？'),
      onConfirm: () async {
        final result = await VideoHttp.relationMod(mid: mid, act: 6, reSrc: 11);
        if (result.isSuccess) {
          Pref.removeBlackMid(mid);
          // by id: the list may have changed while the request ran
          loadingState
            ..value.dataOrNull?.removeWhere((e) => e.mid == mid)
            ..refresh();
          total.value -= 1;
          SmartDialog.showToast('移除成功');
        }
      },
    );
  }

  @override
  Future<LoadingState<BlackListData>> customGetData() =>
      BlackHttp.blackList(pn: page);
}
