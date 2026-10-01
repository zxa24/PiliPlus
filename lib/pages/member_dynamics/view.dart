import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/pages/common/common_list_page.dart';
import 'package:PiliPlus/pages/dynamics/widgets/dynamic_panel.dart';
import 'package:PiliPlus/pages/member_dynamics/controller.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/waterfall.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:waterfall_flow/waterfall_flow.dart'
    hide SliverWaterfallFlowDelegateWithMaxCrossAxisExtent;

/// LibrePili: on [CommonListPageState], as the YouTube channel's 帖子 tab
/// is; the feed's frame (waterfall or centred column, skeleton) is
/// [DynMixin]'s on both.
class MemberDynamicsPage extends StatefulWidget {
  const MemberDynamicsPage({super.key, this.mid});

  final int? mid;

  @override
  State<MemberDynamicsPage> createState() => _MemberDynamicsPageState();
}

class _MemberDynamicsPageState
    extends
        CommonListPageState<
          MemberDynamicsPage,
          DynamicsDataModel,
          DynamicItemModel
        >
    with AutomaticKeepAliveClientMixin, DynMixin {
  late final int mid = widget.mid ?? int.parse(Get.parameters['mid']!);

  @override
  late final MemberDynamicsController controller = Get.put(
    MemberDynamicsController(mid),
    tag: Utils.makeHeroTag(mid),
  );

  @override
  bool get wantKeepAlive => true;

  @override
  bool get isClampingScrollPhysics => widget.mid != null;

  @override
  Widget wrapSliver(Widget sliver) => buildPage(sliver);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final padding = MediaQuery.viewPaddingOf(context);
    return widget.mid == null
        ? SimpleScaffold(
            appBar: AppBar(title: const Text('我的动态')),
            body: Padding(
              padding: EdgeInsets.only(
                left: padding.left,
                right: padding.right,
              ),
              child: buildBody(context),
            ),
          )
        : buildBody(context);
  }

  @override
  Widget get buildLoading => dynSkeleton;

  @override
  Widget buildList(List<DynamicItemModel> list) =>
      GlobalData().dynamicsWaterfallFlow
      ? SliverWaterfallFlow(
          gridDelegate: dynGridDelegate,
          delegate: SliverChildBuilderDelegate(
            (_, index) => _itemBuilder(list, index),
            childCount: list.length,
          ),
        )
      : SliverList.builder(
          itemBuilder: (context, index) => _itemBuilder(list, index),
          itemCount: list.length,
        );

  Widget _itemBuilder(List<DynamicItemModel> list, int index) {
    if (index == list.length - 1) {
      controller.onLoadMore();
    }
    return DynamicPanel(
      item: list[index],
      onRemove: controller.onRemove,
      onSetTop: controller.onSetTop,
    );
  }
}
