import 'package:PiliPlus/common/widgets/pair.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/msg.dart';
import 'package:PiliPlus/models_new/msg/msg_like/data.dart';
import 'package:PiliPlus/models_new/msg/msg_like/item.dart';
import 'package:PiliPlus/pages/common/common_data_controller.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class LikeMeController
    extends
        CommonDataController<
          MsgLikeData,
          Pair<List<MsgLikeItem>, List<MsgLikeItem>>
        > {
  int? cursor;
  int? cursorTime;

  bool isEnd = false;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (!isRefresh && isEnd) {
      return Future.syncValue(null);
    }
    return super.queryData(isRefresh);
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<MsgLikeData> response) {
    MsgLikeData data = response.response;
    if (data.total?.cursor?.isEnd == true ||
        data.total?.items.isNullOrEmpty == true) {
      isEnd = true;
    }
    cursor = data.total?.cursor?.id;
    cursorTime = data.total?.cursor?.time;
    List<MsgLikeItem> latest = data.latest?.items ?? <MsgLikeItem>[];
    List<MsgLikeItem> total = data.total?.items ?? <MsgLikeItem>[];
    if (!isRefresh) {
      if (loadingState.value case Success(:final response)) {
        latest.insertAll(0, response.first);
        total.insertAll(0, response.second);
      }
    }
    loadingState.value = Success(Pair(first: latest, second: total));
    return true;
  }

  @override
  Future<void> onRefresh() {
    cursor = null;
    cursorTime = null;
    // a refresh starts from the first page again: more may follow it
    isEnd = false;
    return super.onRefresh();
  }

  @override
  Future<LoadingState<MsgLikeData>> customGetData() =>
      MsgHttp.msgFeedLikeMe(cursor: cursor, cursorTime: cursorTime);

  Future<void> onRemove(dynamic id, int index, bool isLatest) async {
    try {
      // the item, not its position: the list may change while this runs
      final before = loadingState.value.dataOrNull;
      final item = isLatest ? before?.first[index] : before?.second[index];
      final res = await MsgHttp.delMsgfeed(0, id);
      if (res.isSuccess) {
        final pair = loadingState.value.dataOrNull;
        if (isLatest) {
          pair?.first.remove(item);
        } else {
          pair?.second.remove(item);
        }
        loadingState.refresh();
        SmartDialog.showToast('删除成功');
      } else {
        res.toast();
      }
    } catch (_) {}
  }

  Future<void> onSetNotice(MsgLikeItem item, bool isNotice) async {
    int noticeState = isNotice ? 1 : 0;
    final res = await MsgHttp.msgSetNotice(
      id: item.id!,
      noticeState: noticeState,
    );
    if (res.isSuccess) {
      item.noticeState = noticeState;
      loadingState.refresh();
      SmartDialog.showToast('设置成功');
    } else {
      res.toast();
    }
  }
}
