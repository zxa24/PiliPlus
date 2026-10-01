/// LibrePili: the frame of a creator's page — bilibili's UP主空间 and a
/// YouTube channel are both this.
///
/// A collapsing app bar whose flexible space is the header card, a 45px tab
/// bar under it, and the tab pages below, all in one nested scroll so the
/// header scrolls away and the tab bar stays. Tapping the tab you are
/// already on scrolls back to the top.
///
/// It was bilibili's `MemberPage.build`. The YouTube channel page had a
/// plain AppBar over one list instead, and every difference between the two
/// (no collapsing header, no tab bar, a different scroll) came from there
/// being two copies. Both pages build this now, so the frame changes in one
/// place for both. What goes *in* it — the header's facts, the tabs' lists —
/// stays each platform's.
library;

import 'package:PiliPlus/common/widgets/dynamic_sliver_app_bar/dynamic_sliver_app_bar.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/common/widgets/scroll_behavior.dart'
    show NoOverscrollIndicator;
import 'package:PiliPlus/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:PiliPlus/utils/extension/nested_scroll_ext.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:material_ui/material_ui.dart';

/// The tab bar's height.
const double kSpaceTabBarHeight = 45;

class SpaceShell extends StatelessWidget {
  const SpaceShell({
    super.key,
    required this.scrollKey,
    required this.title,
    required this.tabs,
    required this.children,
    this.header,
    this.actions,
    this.tabController,
    this.onTitleTap,
  });

  final GlobalKey<ExtendedNestedScrollViewState> scrollKey;
  final Widget title;
  final List<Widget>? actions;

  /// The header card, in the app bar's flexible space. Null when the page
  /// has nothing to show there yet (bilibili's space without its card): the
  /// app bar is then a plain pinned one whose title reloads.
  final Widget? header;
  final VoidCallback? onTitleTap;

  final List<Widget> tabs;
  final TabController? tabController;

  /// One page per tab. Empty means there is nothing to show.
  final List<Widget> children;

  /// Scroll back to the top when the tab tapped is the one already shown.
  void _onTapTab(int _) {
    if (tabController?.indexIsChanging == false) {
      scrollKey.currentState?.animToTop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    return ExtendedNestedScrollView(
      onlyOneScrollInBody: true,
      key: scrollKey,
      scrollBehavior: const NoOverscrollIndicator(),
      pinnedHeaderSliverHeightBuilder: () =>
          kToolbarHeight + MediaQuery.viewPaddingOf(context).top,
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        if (header case final header?)
          DynamicSliverAppBar.medium(
            actions: actions,
            title: title,
            flexibleSpace: header,
          )
        else
          SliverAppBar(
            pinned: true,
            actions: actions,
            title: GestureDetector(
              onTap: onTitleTap,
              behavior: HitTestBehavior.opaque,
              child: title,
            ),
          ),
      ],
      body: children.isNotEmpty
          ? Padding(
              padding: .only(left: padding.left, right: padding.right),
              child: Column(
                children: [
                  if (tabs.length > 1)
                    SizedBox(
                      height: kSpaceTabBarHeight,
                      child: TabBar(
                        controller: tabController,
                        tabs: tabs,
                        onTap: _onTapTab,
                        dividerColor: scheme.outline.withValues(alpha: 0.2),
                      ),
                    ),
                  Expanded(
                    child: tabBarView(
                      hitTestBehavior: .translucent,
                      controller: tabController,
                      children: children,
                    ),
                  ),
                ],
              ),
            )
          : scrollableError,
    );
  }

  /// What the page shows before the header has arrived, and when it could
  /// not be fetched — the same on both platforms.
  static const Widget loading = m3eLoading;

  static Widget error(String? errMsg, VoidCallback onReload) =>
      scrollErrorWidget(errMsg: errMsg, onReload: onReload);
}
