/// LibrePili — what the YouTube search box remembers.
///
/// Its own history list rather than a share of bilibili's: the two are
/// searched separately and a YouTube phrase surfacing under B 站's box would
/// be a small lie about where it came from. The 记录搜索 / 无痕 switch is the
/// same one, because that is a decision about this device, not about a
/// platform.
library;

import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtSearchController extends GetxController {
  static const _historyKey = 'ytCacheList';

  final controller = TextEditingController();
  final focusNode = FocusNode();

  late final historyList = RxList<String>(
    List<String>.from(GStorage.historyWord.get(_historyKey) ?? const <String>[]),
  );
  late final recordSearchHistory = Pref.recordSearchHistory.obs;

  @override
  void onInit() {
    super.onInit();
    if (Get.parameters['keyword'] case final keyword?) {
      controller.text = keyword;
    }
  }

  void onClear() {
    if (controller.text.isNotEmpty) {
      controller.clear();
      focusNode.requestFocus();
    } else {
      Get.back();
    }
  }

  void submit([String? value]) {
    final text = (value ?? controller.text).trim();
    if (text.isEmpty) return;

    // a pasted link is not a search
    if (tryParseYouTubeVideoId(text) case final videoId?) {
      Get.toNamed('/ytVideo', parameters: {'id': videoId});
      return;
    }

    if (recordSearchHistory.value) {
      final index = historyList.indexOf(text);
      if (index != 0) {
        if (index != -1) historyList.removeAt(index);
        historyList.insert(0, text);
        GStorage.historyWord.put(_historyKey, historyList);
      }
    }

    focusNode.unfocus();
    Get.toNamed(
      '/ytSearchResult',
      parameters: {'keyword': text},
    )?.then((_) => focusNode.requestFocus());
  }

  void onClickKeyword(String keyword) {
    controller.text = keyword;
    submit(keyword);
  }

  void onLongSelect(String word) {
    historyList.remove(word);
    GStorage.historyWord.put(_historyKey, historyList);
  }

  void toggleRecord() {
    final enable = !recordSearchHistory.value;
    recordSearchHistory.value = enable;
    GStorage.setting.put(SettingBoxKey.recordSearchHistory, enable);
  }

  void onClearHistory() {
    showConfirmDialog(
      context: Get.context!,
      title: const Text('确定清空搜索历史？'),
      onConfirm: () {
        historyList.clear();
        GStorage.historyWord.delete(_historyKey);
      },
    );
  }

  @override
  void onClose() {
    focusNode.dispose();
    controller.dispose();
    super.onClose();
  }
}
