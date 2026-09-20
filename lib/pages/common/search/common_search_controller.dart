import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract class CommonSearchController<R, T> extends CommonListController<R, T> {
  final editController = TextEditingController();
  final focusNode = FocusNode();

  void onClear() {
    if (editController.text.isNotEmpty) {
      editController.clear();
    } else {
      Get.back();
    }
  }

  @override
  Future<void> onRefresh() {
    if (editController.value.text.isEmpty) {
      return Future.syncValue(null);
    }
    // the keyword can have changed since a refresh started (submitting a new
    // query calls this): that one is searching for the old one
    markRefreshStale();
    return super.onRefresh();
  }

  @override
  void onClose() {
    editController.dispose();
    focusNode.dispose();
    super.onClose();
  }
}
