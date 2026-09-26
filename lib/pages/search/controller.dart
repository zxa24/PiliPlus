import 'dart:async';

import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models/common/setting_type.dart';
import 'package:PiliPlus/models/search/suggest.dart';
import 'package:PiliPlus/models_new/search/search_rcmd/data.dart';
import 'package:PiliPlus/models_new/search/search_trending/data.dart';
import 'package:PiliPlus/pages/scan/view.dart';
import 'package:PiliPlus/pages/setting/common_setting.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:stream_transform/stream_transform.dart';

mixin DebounceStreamMixin<T> {
  final Duration duration = const Duration(milliseconds: 200);
  StreamController<T>? ctr;
  StreamSubscription<T>? _sub;
  void onValueChanged(T value);

  void subInit() {
    _sub = (ctr = StreamController<T>()).stream
        .debounce(duration, trailing: true)
        .listen(onValueChanged);
  }

  void subDispose() {
    _sub?.cancel();
    ctr?.close();
    _sub = null;
    ctr = null;
  }
}

abstract class DebounceStreamState<T extends StatefulWidget, S> extends State<T>
    with DebounceStreamMixin<S> {
  @override
  void dispose() {
    subDispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    subInit();
  }
}

class BaseSearchController extends GetxController {
  final historyList = List<String>.from(
    GStorage.historyWord.get('cacheList') ?? const <String>[],
  ).obs;

  late final Rx<LoadingState<SearchTrendingData>> trendingState;

  final recordSearchHistory = Pref.recordSearchHistory.obs;
  final searchSuggestion = Pref.searchSuggestion;
  final enableTrending = Pref.enableTrending;
  final enableSearchRcmd = Pref.enableSearchRcmd;

  @override
  void onInit() {
    super.onInit();

    if (enableTrending) {
      trendingState = LoadingState<SearchTrendingData>.loading().obs;
      queryTrendingList();
    }
  }

  // 获取热搜关键词
  Future<void> queryTrendingList() async {
    trendingState.value = await SearchHttp.searchTrending(limit: 10);
  }
}

class SSearchController extends GetxController
    with DebounceStreamMixin<String> {
  SSearchController(this.tag);
  final String tag;

  final searchFocusNode = FocusNode();
  final controller = TextEditingController();
  final _baseCtr = Get.putOrFind(BaseSearchController.new);

  String? hintText;

  int initIndex = 0;

  // uid
  final RxBool showUidBtn = false.obs;

  // history
  RxBool get recordSearchHistory => _baseCtr.recordSearchHistory;
  RxList<String> get historyList => _baseCtr.historyList;

  // suggestion
  bool get searchSuggestion => _baseCtr.searchSuggestion;
  late final RxList<SearchSuggestItem> searchSuggestList;

  // trending
  bool get enableTrending => _baseCtr.enableTrending;
  Rx<LoadingState<SearchTrendingData>> get trendingState =>
      _baseCtr.trendingState;

  // rcmd
  bool get enableSearchRcmd => _baseCtr.enableSearchRcmd;
  late final Rx<LoadingState<SearchRcmdData>> recommendData;

  Future<void> Function() get queryTrendingList => _baseCtr.queryTrendingList;

  @override
  void onInit() {
    super.onInit();
    final params = Get.parameters;
    hintText = params['hintText'];
    final text = params['text'];
    if (text != null) {
      controller.text = text;
    }

    if (searchSuggestion) {
      subInit();
      searchSuggestList = <SearchSuggestItem>[].obs;
      if (text != null) onValueChanged(text);
    }

    if (enableSearchRcmd) {
      recommendData = LoadingState<SearchRcmdData>.loading().obs;
      queryRecommendList();
    }
  }

  void validateUid() {
    showUidBtn.value = IdUtils.digitOnlyRegExp.hasMatch(controller.text);
  }

  void onChange(String value) {
    validateUid();
    if (searchSuggestion) {
      if (value.isEmpty) {
        searchSuggestList.clear();
      } else {
        ctr!.add(value);
      }
    }
  }

  void onClear() {
    if (controller.value.text != '') {
      controller.clear();
      if (searchSuggestion) searchSuggestList.clear();
      searchFocusNode.requestFocus();
      showUidBtn.value = false;
    } else {
      Get.back();
    }
  }

  /// The scan button (research/qr-code-design-2026-09-25.md): what was read
  /// opens a video when it is a link or a BV/av number, and goes into the
  /// search box otherwise — not searched, so it can be looked at first.
  Future<void> scan() async {
    if (!await _explainScan()) return;
    final text = (await scanQrCode())?.trim();
    if (text == null || text.isEmpty) return;
    final id =
        IdUtils.bvRegexExact.hasMatch(text) ||
            IdUtils.avRegexExact.hasMatch(text)
        ? text
        : null;
    final url = id != null ? '${HttpString.baseUrl}/video/$id' : text;
    if ((id != null || url.contains('://') || url.startsWith('www.')) &&
        await PiliScheme.routePushFromUrl(url, selfHandle: true)) {
      return;
    }
    controller
      ..text = text
      ..selection = TextSelection.collapsed(offset: text.length);
    onChange(text);
  }

  /// The first use asks before the camera is: what it is for, and where to
  /// turn the button off for good (user 2026-09-25).
  Future<bool> _explainScan() async {
    if (GStorage.setting.get(SettingBoxKey.scanExplained) == true) return true;
    final context = Get.context;
    if (context == null) return false;
    final go = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('扫一扫'),
        content: const Text(
          '扫码需要使用摄像头，接下来可能会请求摄像头权限。\n\n'
          '扫到的画面只在本机识别，不会上传。不需要扫码的话，可以在设置中关闭这个按钮。',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get
                ..back(result: false)
                ..to(
                  () => const CommonSetting(
                    settingType: SettingType.extraSetting,
                  ),
                );
            },
            child: const Text('去设置关闭'),
          ),
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Get.back(result: true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (go == true) {
      await GStorage.setting.put(SettingBoxKey.scanExplained, true);
      return true;
    }
    return false;
  }

  // 搜索
  Future<void> submit() async {
    if (controller.text.isEmpty) {
      if (hintText.isNullOrEmpty) return;
      controller.text = hintText!;
      validateUid();
    }

    final text = controller.text;

    if (await PiliScheme.routePushFromUrl(text, selfHandle: true)) {
      return;
    }

    if (recordSearchHistory.value) {
      final index = historyList.indexOf(text);
      if (index != 0) {
        if (index != -1) historyList.removeAt(index);
        historyList.insert(0, text);
        GStorage.historyWord.put('cacheList', historyList);
      }
    }

    searchFocusNode.unfocus();
    Get.toNamed(
      '/searchResult',
      parameters: {'tag': tag, 'keyword': text},
      arguments: {'initIndex': initIndex, 'fromSearch': true},
    )?.then((val) {
      searchFocusNode.requestFocus();
      if (val is bool && val) {
        onValueChanged(text);
      }
    });
  }

  Future<void> queryRecommendList() async {
    recommendData.value = await SearchHttp.searchRecommend();
  }

  void onClickKeyword(String keyword, {bool clearSuggest = true}) {
    controller.text = keyword;
    validateUid();

    if (searchSuggestion && clearSuggest) searchSuggestList.clear();
    submit();
  }

  @override
  Future<void> onValueChanged(String value) async {
    final res = await SearchHttp.searchSuggest(term: value);
    if (res case Success(:final response)) {
      if (response.tag?.isNotEmpty == true) {
        searchSuggestList.value = response.tag!;
      }
    }
  }

  void onLongSelect(String word) {
    historyList.remove(word);
    GStorage.historyWord.put('cacheList', historyList);
  }

  void onClearHistory() {
    showConfirmDialog(
      context: Get.context!,
      title: const Text('确定清空搜索历史？'),
      onConfirm: () {
        historyList.clear();
        GStorage.historyWord.delete('cacheList');
      },
    );
  }

  @override
  void onClose() {
    subDispose();
    searchFocusNode.dispose();
    controller.dispose();
    super.onClose();
  }
}
