/// LibrePili: one shape for every list in the app.
///
/// bilibili's search panels already work this way — a base State wires the
/// refresh indicator, the scroll view and the switch over [LoadingState],
/// and a subclass says only what a loading list and a loaded list look like
/// (`lib/pages/search_panel/view.dart`). Everything a list does *around* its
/// items is therefore written once.
///
/// The YouTube pages were each written with their own `_loading` / `_error`
/// / `_items` fields, so every one of them had to be brought into line by
/// hand, one screen at a time, as somebody noticed. This is the same base
/// with the bilibili-specific parts (a search keyword, a result count)
/// lifted out, so both platforms can sit on it and a change to how a list
/// loads is a change in one file.
///
/// What a subclass still owns: how to fetch a page, and how to draw an item.
/// That is the part that genuinely differs between two platforms.
library;

import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract class CommonListPageState<S extends StatefulWidget, R, T>
    extends State<S> {
  CommonListController<R, T> get controller;

  /// What the list looks like before its first page arrives. Usually a run
  /// of the skeleton that matches the item.
  Widget get buildLoading;

  /// The loaded list, as a sliver.
  Widget buildList(List<T> list);

  /// Anything pinned above the list — a header, a count, a sort control.
  Widget? buildHeader() => null;

  /// Shown when the request succeeded and returned nothing at all. The
  /// default offers a reload, because "empty" is usually "try again"; a page
  /// that can genuinely be empty (a subscription list nobody has added to)
  /// should say so instead.
  Widget buildEmpty() => HttpError(onReload: controller.onReload);

  ScrollController? get scrollController => null;

  /// Room under the list for whatever floats over it.
  double get bottomPadding => 100;

  /// True for a list inside a tab of a nested scroll view (a creator
  /// page's tabs): the outer view owns the overscroll, and the refresh
  /// indicator has to be told so.
  bool get isClampingScrollPhysics => false;

  ScrollPhysics get physics => const AlwaysScrollableScrollPhysics();

  /// Wraps the list's sliver — a feed that centres itself on a wide window
  /// ([DynMixin.buildPage]) does it here.
  Widget wrapSliver(Widget sliver) => sliver;

  @override
  Widget build(BuildContext context) => buildBody(context);

  /// What [build] returns. Separate so a page that mixes in
  /// [AutomaticKeepAliveClientMixin] — whose `build` must be called and
  /// returns nothing usable — can call that and then return this.
  Widget buildBody(BuildContext context) => refreshIndicator(
    isClampingScrollPhysics: isClampingScrollPhysics,
    onRefresh: controller.onRefresh,
    child: CustomScrollView(
      controller: scrollController,
      physics: physics,
      slivers: [
        ?buildHeader(),
        SliverPadding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewPaddingOf(context).bottom + bottomPadding,
          ),
          sliver: wrapSliver(Obx(() => _body(controller.loadingState.value))),
        ),
      ],
    ),
  );

  Widget _body(LoadingState<List<T>?> state) => switch (state) {
    Loading() => buildLoading,
    Success(:final response) =>
      response != null && response.isNotEmpty ? buildList(response) : buildEmpty(),
    Error(:final errMsg) => HttpError(
      errMsg: errMsg,
      onReload: controller.onReload,
    ),
  };
}
