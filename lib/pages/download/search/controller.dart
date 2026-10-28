import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart'
    show BaseMultiSelectMixin;
import 'package:PiliPlus/pages/common/search/common_search_controller.dart';
import 'package:PiliPlus/pages/download/delete_dialog.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class DownloadSearchController
    extends CommonSearchController<List<DownloadEntry>, DownloadEntry>
    with BaseMultiSelectMixin<DownloadEntry> {
  final _downloadService = Get.find<DownloadService>();

  @override
  List<DownloadEntry> get list => loadingState.value.data!;
  @override
  Rx<LoadingState<List<DownloadEntry>?>> get state => loadingState;

  @override
  Future<LoadingState<List<DownloadEntry>>> customGetData() async {
    final text = editController.text.toLowerCase();
    return Success(
      _downloadService.downloadList
          .where(
            (e) =>
                e.title.toLowerCase().contains(text) ||
                e.showTitle.toLowerCase().contains(text) ||
                (e.ownerName?.toLowerCase().contains(text) ?? false),
          )
          .toList(),
    );
  }

  void onRemoveSingle(
    int index,
    DownloadEntry entry,
    bool deleteExported,
  ) {
    loadingState
      ..value.data!.removeAt(index)
      ..refresh();
    _downloadService.deleteDownload(
      entry: entry,
      removeList: true,
      deleteExported: deleteExported,
    );
    _downloadService.platformOf(entry).onDeleted([entry]);
  }

  @override
  Future<void> onRemove() async {
    final allChecked = this.allChecked.toSet();
    final deleteExported = await showDeleteDownloadDialog(
      Get.context!,
      title: '确定删除选中视频？',
      exportOption: allChecked.any((e) => e.mergedPath != null),
    );
    if (deleteExported == null) return;
    SmartDialog.showLoading();
    for (final entry in allChecked) {
      await _downloadService.platformOf(entry).onDeleted([entry]);
      await _downloadService.deleteDownload(
        entry: entry,
        removeList: true,
        refresh: false,
        deleteExported: deleteExported,
      );
    }
    loadingState
      ..value.data!.removeWhere(allChecked.contains)
      ..refresh();
    _downloadService.flagNotifier.refresh();
    if (enableMultiSelect.value) {
      rxCount.value = 0;
      enableMultiSelect.value = false;
    }
    SmartDialog.dismiss();
  }
}
