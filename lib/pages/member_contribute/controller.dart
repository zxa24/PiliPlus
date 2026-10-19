import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/space/space/tab2.dart';
import 'package:PiliPlus/pages/member/controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class MemberContributeCtr extends GetxController
    with GetSingleTickerProviderStateMixin {
  MemberContributeCtr({
    required this.heroTag,
    required this.initialIndex,
  });
  final String? heroTag;
  final int? initialIndex;

  TabController? tabController;
  List<Tab>? tabs;
  late final _ctr = Get.find<MemberController>(tag: heroTag);
  List<SpaceTab2Item>? items;

  Worker? _worker;

  @override
  void onInit() {
    super.onInit();
    _initTabs();
    // this controller outlives the tab: a reload of the member page brings
    // new sub-tabs, which must replace the ones read at the first load
    _worker = ever(_ctr.loadingState, (state) {
      if (state is Success) _initTabs();
    });
  }

  void _initTabs() {
    tabController?.dispose();
    tabController = null;
    tabs = null;
    this.items = null;
    final tab2 = _ctr.tab2;
    final index = tab2?.indexWhere((item) => item.param == 'contribute') ?? -1;
    if (index == -1) return;
    SpaceTab2 contribute = tab2![index];
    // a copy: 'ugcSeason' is not to be added to the member controller's list
    final items = contribute.items?.toList();
    if (items != null && items.isNotEmpty) {
      this.items = items;
      if (items.length > 1) {
        // show if exist
        if (_ctr.hasSeasonOrSeries == true) {
          items.add(const SpaceTab2Item(param: 'ugcSeason', title: '全部合集/列表'));
        }
        tabs = items.map((item) => Tab(text: item.title)).toList();
        tabController = TabController(
          vsync: this,
          length: items.length,
          initialIndex: (initialIndex ?? 0).clamp(0, items.length - 1),
        );
      }
    }
  }

  @override
  void onClose() {
    _worker?.dispose();
    tabController?.dispose();
    super.onClose();
  }
}
