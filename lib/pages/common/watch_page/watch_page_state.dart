import 'package:PiliPlus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:PiliPlus/pages/common/watch_page/watch_page_source.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/extension/nested_scroll_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:flutter/foundation.dart' show kDebugMode, clampDouble;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// The watch-page shell's state (design feature-logs/watch-page-shell/
/// design.md §3.3): the layout fields that were on VideoDetailController,
/// held by the page's controller (its lifetime) and read and written by the
/// shell and the layouts. Moved from lib/pages/video/controller.dart
/// (05b103a52 BC:245, 269, 292-352, 866-872) and the page's playerListener
/// (B:251-273).
class WatchPageShellState {
  WatchPageShellState({required this.vsync, required this.player});

  /// the page controller (its ticker: tabCtr and the expand animation)
  final TickerProvider vsync;

  /// the shared player (the sheets' route and theme read it)
  final PlPlayerController player;

  /// live: written by the page's didChangeDependencies (R14)
  bool isPortrait = true;

  /// the layout's isPortrait (R3's readers table): S1 has no fullscreen
  /// stickiness, so it is [isPortrait]
  bool get layoutIsPortrait => isPortrait;

  bool get showVideoSheet =>
      (!player.horizontalScreen && !isPortrait) || player.isDesktopPip;

  final videoPlayerKey = GlobalKey();
  final childKey = GlobalKey<MiniScaffoldState>();
  late final headerCtrKey = GlobalKey<TimeBatteryMixin>();

  /// tabs相关配置
  late TabController tabCtr;

  ScrollController? introScrollCtr;
  ScrollController get effectiveIntroScrollCtr =>
      introScrollCtr ??= ScrollController();

  late final scrollKey = GlobalKey<ExtendedNestedScrollViewState>();
  late final RxDouble scrollRatio = 0.0.obs;

  ScrollController? _scrollCtr;

  /// the scroll controller if it was made (VideoDetailController's
  /// _setVideoHeight reads this one: [scrollCtr] would make it)
  ScrollController? get scrollCtrOrNull => _scrollCtr;
  ScrollController get scrollCtr => _scrollCtr ??= ScrollController();

  late bool isExpanding = false;
  late bool isCollapsing = false;

  late double minVideoHeight;
  late double maxVideoHeight;
  late double videoHeight;
  late double animHeight;

  AnimationController? animController;
  AnimationController get animationController =>
      animController ??= (AnimationController(
        vsync: vsync,
        duration: const Duration(milliseconds: 200),
      )..addListener(_animListener));

  void refreshPage() {
    scrollKey.currentState?.refresh();
  }

  void _animListener() {
    if (animationController.isForwardOrCompleted) {
      _calcAnimHeight();
      refreshPage();
    }
  }

  void _calcAnimHeight() {
    if (isExpanding) {
      animHeight = clampDouble(
        videoHeight * animationController.value,
        kToolbarHeight,
        videoHeight,
      );
    } else if (isCollapsing) {
      animHeight = clampDouble(
        maxVideoHeight -
            (maxVideoHeight - minVideoHeight) * animationController.value,
        minVideoHeight,
        maxVideoHeight,
      );
    }
  }

  void animToTop() {
    scrollKey.currentState?.animToTop();
  }

  /// R5: the header refreshed, and opened when playing starts with it
  /// scrolled away. Called by the page's own status listener (registered
  /// and taken off at the page's times, R5).
  void onPlayerStatus(PlayerStatus status) {
    final isPlaying = status.isPlaying;
    try {
      if (scrollCtr.hasClients) {
        if (isPlaying) {
          if (!isExpanding &&
              scrollCtr.offset != 0 &&
              !animationController.isAnimating) {
            isExpanding = true;
            animationController.forward(
              from: 1 - scrollCtr.offset / videoHeight,
            );
          } else {
            refreshPage();
          }
        } else {
          refreshPage();
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('handle player status: $e');
    }
  }

  /// R7: a sheet over the tab area, or (by [policy]) the global one in
  /// fullscreen or when [showVideoSheet] holds. [theme] is the dark theme
  /// the global sheet takes when the dark video page is on; without it,
  /// ThemeUtils.darkTheme (the controller's sheets).
  void showSheet(
    BuildContext context,
    Widget Function(BuildContext context, {required bool inPage}) builder, {
    SheetPolicy policy = SheetPolicy.perR7,
    ThemeData? theme,
  }) {
    if (policy == SheetPolicy.perR7 &&
        (player.isFullScreen.value || showVideoSheet)) {
      final child = builder(context, inPage: false);
      PageUtils.showVideoBottomSheet(
        context,
        child: player.darkVideoPage
            ? Theme(data: theme ?? ThemeUtils.darkTheme, child: child)
            : child,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        constraints: const BoxConstraints(),
        (context) => builder(context, inPage: true),
      );
    }
  }

  void dispose() {
    introScrollCtr?.dispose();
    introScrollCtr = null;
    tabCtr.dispose();
    _scrollCtr?.dispose();
    animController
      ?..removeListener(_animListener)
      ..dispose();
  }
}
