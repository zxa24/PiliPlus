import 'dart:ui' as ui;

import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/common/watch_page/watch_page_state.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';

/// The layout branch a watch page is built in (design
/// feature-logs/watch-page-shell/design.md R1, §3.2).
enum WatchBranch { pip, portrait, landscape, split, almostSquare, threeColumn }

/// Where in a branch a content builder is called (§3.2 「布局上下文」).
enum WatchSlot { player, tab, introColumn, sideColumn, row }

/// What a tab holds, for the tap on the current tab (R6).
enum TabRole { intro, related, comments, playlist }

/// The label of the play button on the collapsed bar (R5).
enum PlayStateLabel { now, resume, replay }

/// Where a sheet opens (R7).
enum SheetPolicy {
  /// in fullscreen or when the shell's showVideoSheet holds: the global
  /// sheet, otherwise the tab area's MiniScaffold (childKey)
  perR7,

  /// always the tab area's MiniScaffold (childKey)
  alwaysInPage,
}

/// What the shell gives each content builder it calls (§3.2).
class WatchLayoutContext {
  const WatchLayoutContext({
    required this.branch,
    required this.slot,
    this.slotWidth,
    this.slotHeight,
    required this.windowSize,
    required this.isWindowMode,
    this.isHorizontal,
    this.attachIntroController = true,
    this.nested = false,
    required this.isPortrait,
    required this.padding,
    required this.theme,
    required this.isFullScreen,
  });

  final WatchBranch branch;
  final WatchSlot slot;

  /// the slot's size; given for the player, not given by some calls
  final double? slotWidth;
  final double? slotHeight;

  /// the window's logical size (the page's maxWidth × maxHeight)
  final Size windowSize;
  final bool isWindowMode;

  /// given: used as is; not given: the page works it out from the slot
  final bool? isHorizontal;

  /// whether the intro list takes the intro scroll controller (and with
  /// it the default physics; without it, clamping)
  final bool attachIntroController;

  /// inside the portrait layout's nested scroll view
  final bool nested;

  /// the layout's isPortrait (frozen in fullscreen from S1b on)
  final bool isPortrait;
  final EdgeInsets padding;
  final ThemeData theme;
  final bool isFullScreen;
}

/// What a page gives the watch-page shell (§3.2). Members with a body are
/// the 「选」 ones: a page that has nothing there leaves them.
abstract mixin class WatchPageSource {
  // ---- player and stand-in
  Widget player(WatchLayoutContext ctx, {required bool isPipMode});
  PlPlayerController get sharedPlayer;
  PlPlayerController? get claimedPlayer;
  WatchPageShellState get shell;

  // ---- the page State's own layout fields (written by its
  // didChangeDependencies)
  double get maxWidth;
  double get maxHeight;
  EdgeInsets get padding;
  bool get isWindowMode;
  ThemeData get theme;
  bool get pageIsPortrait;

  /// the page State's context, outside its Theme(data: theme) wrapper
  BuildContext get pageContext;

  VoidCallback get onPlayTap;
  bool get playPending => false;
  bool get gateUp;
  bool get autoPlay;
  bool get viewUp;
  String? get cover;
  ui.Image? get pictureAtPush => null;
  bool get loadFailed;
  VoidCallback get retry;
  Widget? get gate => null;
  bool get failureOverCover => false;
  Widget? failure(WatchLayoutContext ctx) => null;

  // ---- layout inputs
  RxBool get isVertical;
  bool get isFileSource;
  bool get showReply;
  bool get showRelated;
  bool showPlaylist({required bool isPortrait});
  bool get introColumnInLandscape;

  // ---- content
  Widget intro(WatchLayoutContext ctx, {required bool withRelated});
  Widget? related(WatchLayoutContext ctx) => null;
  Widget comments(WatchLayoutContext ctx);
  Widget Function()? get commentsLabel => null;
  Widget? playlist(WatchLayoutContext ctx) => null;
  String get pageTag;
  void onReselect(TabRole role);

  // ---- collapsed bar and the autoplay-off top row
  bool get playedHere;
  PlayStateLabel get playState;
  VoidCallback get onCollapsedBarTap;
  List<PopupMenuEntry> Function(BuildContext menuContext)? get moreMenu => null;
  VoidCallback? get openSettings => null;

  // ---- route (R9)
  void onCovered();
  void onUncovered();
  bool get ownsPlayer;
  void onPopped() {}

  // ---- keyboard (R13)
  CommonIntroController? get introController => null;
  bool canPlay();
  VoidCallback? get onSendDanmaku => null;
  ValueGetter<bool>? get onSkipSegment => null;
  VoidCallback? get onRefresh => null;

  // ---- page-only slots
  List<Widget> playerOverlays(WatchLayoutContext ctx) => const [];
  Widget? introFooter(WatchLayoutContext ctx) => null;
  List<Widget> get tabBarTrailing => const [];
}
