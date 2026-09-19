import 'dart:async';

import 'package:PiliPlus/models_new/download/download_info.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart'
    show BaseMultiSelectMixin;
import 'package:PiliPlus/pages/download/delete_dialog.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:collection/collection.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class DownloadPageController extends GetxController
    with BaseMultiSelectMixin<DownloadPageInfo> {
  final _downloadService = Get.find<DownloadService>();
  final pages = RxList<DownloadPageInfo>();
  final flag = RxInt(0);

  @override
  List<DownloadPageInfo> get list => pages;
  @override
  RxList<DownloadPageInfo> get state => pages;

  @override
  void onInit() {
    super.onInit();
    _loadList();
    _downloadService.flagNotifier.add(_loadList);
  }

  @override
  void onClose() {
    _downloadService.flagNotifier.remove(_loadList);
    super.onClose();
  }

  Future<void> _loadList() async {
    await _downloadService.waitForInitialization;
    if (isClosed) return;
    if (_downloadService.downloadList.isEmpty) {
      pages.clear();
      rxCount.value = 0;
      enableMultiSelect.value = false;
      return;
    }
    final list = <DownloadPageInfo>[];
    for (final entry in _downloadService.downloadList) {
      final pageId = entry.pageId;
      final page = list.firstWhereOrNull((e) => e.pageId == pageId);
      if (page != null) {
        final aSortKey = entry.sortKey;
        final bSortKey = page.sortKey;
        if (aSortKey < bSortKey) {
          page
            ..cover = entry.cover
            ..sortKey = aSortKey;
        }
        page.entries.add(entry);
      } else {
        list.add(
          DownloadPageInfo(
            pageId: pageId,
            dirPath: entry.pageDirPath,
            title: entry.title,
            cover: entry.cover,
            sortKey: entry.sortKey,
            seasonType: entry.ep?.seasonType,
            entries: [entry],
          ),
        );
      }
    }
    if (enableMultiSelect.value) {
      // the items are rebuilt here: carry the selection over by pageId, so
      // the count keeps matching the ticks
      final checked = {
        for (final page in pages)
          if (page.checked) page.pageId,
      };
      int count = 0;
      for (final page in list) {
        if (checked.contains(page.pageId)) {
          page.checked = true;
          count++;
        }
      }
      rxCount.value = count;
      if (count == 0) {
        enableMultiSelect.value = false;
      }
    }
    pages.value = list;
    flag.value++;
  }

  @override
  Future<void> onRemove() async {
    final allChecked = this.allChecked.toList();
    final deleteExported = await showDeleteDownloadDialog(
      Get.context!,
      title: '确定删除选中视频？',
      exportOption: allChecked.any(
        (page) => page.entries.any((e) => e.mergedPath != null),
      ),
    );
    if (deleteExported == null) return;
    SmartDialog.showLoading();
    final watchProgress = GStorage.watchProgress;
    for (final page in allChecked) {
      await watchProgress.deleteAll(
        page.entries.map((e) => e.cid.toString()),
      );
      await _downloadService.deletePage(
        pageDirPath: page.dirPath,
        refresh: false,
        deleteExported: deleteExported,
      );
    }
    _downloadService.flagNotifier.refresh();
    if (enableMultiSelect.value) {
      rxCount.value = 0;
      enableMultiSelect.value = false;
    }
    SmartDialog.dismiss();
  }
}
