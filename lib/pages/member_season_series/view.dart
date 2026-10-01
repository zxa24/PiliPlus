import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/scroll_physics.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/models/common/member/contribute_type.dart';
import 'package:PiliPlus/models_new/space/space_season_series/item.dart';
import 'package:PiliPlus/models_new/space/space_season_series/season.dart'
    show SpaceSsModel;
import 'package:PiliPlus/pages/common/common_list_page.dart';
import 'package:PiliPlus/pages/member_season_series/controller.dart';
import 'package:PiliPlus/pages/member_season_series/widget/season_series_card.dart';
import 'package:PiliPlus/pages/member_video/view.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: on [CommonListPageState], as the YouTube channel's 播放列表 tab
/// is — loading, empty, failure and paging are the shared base's, not a
/// hand-written switch per page.
class SeasonSeriesPage extends StatefulWidget {
  const SeasonSeriesPage({
    super.key,
    required this.mid,
    this.heroTag,
  });

  final int mid;
  final String? heroTag;

  @override
  State<SeasonSeriesPage> createState() => _SeasonSeriesPageState();
}

class _SeasonSeriesPageState
    extends CommonListPageState<SeasonSeriesPage, SpaceSsData, SpaceSsModel>
    with AutomaticKeepAliveClientMixin, GridMixin {
  @override
  late final SeasonSeriesController controller = Get.put(
    SeasonSeriesController(widget.mid),
    tag: widget.heroTag,
  );

  @override
  bool get wantKeepAlive => true;

  @override
  bool get isClampingScrollPhysics => true;

  @override
  ScrollPhysics get physics => platformAlwaysClampingPhysics;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return buildBody(context);
  }

  @override
  Widget get buildLoading => gridSkeleton;

  @override
  Widget buildList(List<SpaceSsModel> list) => SliverGrid.builder(
    gridDelegate: gridDelegate,
    itemBuilder: (context, index) {
      if (index == list.length - 1) {
        controller.onLoadMore();
      }
      final item = list[index];
      return SeasonSeriesCard(
        item: item,
        onTap: () {
          bool isSeason = item.meta!.seasonId != null;
          dynamic id = isSeason ? item.meta!.seasonId : item.meta!.seriesId;
          Get.to(
            SimpleScaffold(
              appBar: AppBar(title: Text(item.meta!.name!)),
              body: ViewSafeArea(
                child: MemberVideo(
                  type: isSeason ? ContributeType.season : ContributeType.series,
                  heroTag: widget.heroTag,
                  mid: widget.mid,
                  seasonId: isSeason ? id : null,
                  seriesId: isSeason ? null : id,
                  title: item.meta!.name,
                ),
              ),
            ),
          );
        },
      );
    },
    itemCount: list.length,
  );
}
