import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/scroll_behavior.dart'
    show NoOverscrollIndicator;
import 'package:PiliPlus/common/widgets/scroll_physics.dart'
    show tabBarView, platformClampingPhysics;
import 'package:PiliPlus/common/widgets/simple_app_bar.dart';
import 'package:PiliPlus/common/widgets/sliver/video_header.dart';
import 'package:PiliPlus/common/widgets/svg/play_icon.dart';
import 'package:PiliPlus/pages/common/watch_page/watch_page_source.dart';
import 'package:PiliPlus/pages/common/watch_page/watch_page_state.dart';
import 'package:PiliPlus/pages/video/widgets/player_stand_in.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/self_test_probe.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:flutter/foundation.dart' show clampDouble;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// The watch page's layout branches (design feature-logs/watch-page-shell/
/// design.md R1-R7, R10, R15), moved from lib/pages/video/view.dart
/// (05b103a52 B:588-1420, 1479-1722) as they were: the page's own reads go
/// through [source] (WatchPageSource), the layout fields through [shell].
/// Each content builder is called in the builder it was called in (§3.2
/// 「调用作用域不变式」).
class WatchPageLayouts {
  WatchPageLayouts(this.source);

  final WatchPageSource source;

  WatchPageShellState get shell => source.shell;

  bool get isFullScreen => source.sharedPlayer.isFullScreen.value;

  ThemeData get theme => source.theme;
  ColorScheme get colorScheme => theme.colorScheme;

  /// live (R3's readers table: header heights, the app bar, canPop)
  bool get isPortrait => source.pageIsPortrait;

  /// the layout's (frozen in fullscreen from S1b on): the vertical variants,
  /// the playlist tab, the contents' isPortrait
  bool get layoutIsPortrait => shell.layoutIsPortrait;
  double get maxWidth => source.maxWidth;
  double get maxHeight => source.maxHeight;
  bool get isWindowMode => source.isWindowMode;
  EdgeInsets get padding => source.padding;

  bool get _showPlaylist => source.showPlaylist(isPortrait: layoutIsPortrait);

  WatchLayoutContext _ctx(
    WatchBranch branch,
    WatchSlot slot, {
    required bool isFullScreen,
    double? width,
    double? height,
    bool? isHorizontal,
    bool attachIntroController = true,
    bool nested = false,
  }) => WatchLayoutContext(
    branch: branch,
    slot: slot,
    slotWidth: width,
    slotHeight: height,
    windowSize: Size(maxWidth, maxHeight),
    isWindowMode: isWindowMode,
    isHorizontal: isHorizontal,
    attachIntroController: attachIntroController,
    nested: nested,
    isPortrait: layoutIsPortrait,
    padding: padding,
    theme: theme,
    isFullScreen: isFullScreen,
  );

  /// R15: in picture-in-picture only the player
  Widget pip() => plPlayer(
    _ctx(
      WatchBranch.pip,
      WatchSlot.player,
      isFullScreen: isFullScreen,
      width: maxWidth,
      height: maxHeight,
    ),
    isPipMode: true,
  );

  bool removeAppBar(bool isFullScreen) =>
      PlatformUtils.isDesktop ||
      source.sharedPlayer.removeSafeArea ||
      (isWindowMode && isFullScreen && !isPortrait);

  Widget get childWhenDisabled {
    return Obx(
      () {
        final isFullScreen = this.isFullScreen;
        return SimpleScaffold(
          appBar: removeAppBar(isFullScreen)
              ? null
              : Obx(
                  () {
                    final scrollRatio = shell.scrollRatio.value;
                    final brightness = colorScheme.brightness;
                    final Brightness statusBarBrightness;
                    final Brightness statusBarIconBrightness;
                    final backgroundColor = isPortrait && scrollRatio > 0
                        ? Color.lerp(
                            Colors.black,
                            colorScheme.surface,
                            scrollRatio,
                          )!
                        : Colors.black;
                    if (isPortrait && scrollRatio >= 0.5) {
                      statusBarBrightness = brightness;
                      statusBarIconBrightness = brightness.reverse;
                    } else {
                      statusBarBrightness = .dark;
                      statusBarIconBrightness = .light;
                    }
                    return SimpleAppBar(
                      height: padding.top,
                      backgroundColor: backgroundColor,
                      brightness: brightness,
                      statusBarBrightness: statusBarBrightness,
                      statusBarIconBrightness: statusBarIconBrightness,
                    );
                  },
                ),
          body: ExtendedNestedScrollView(
            onlyOneScrollInBody: true,
            physics: platformClampingPhysics,
            key: shell.scrollKey,
            controller: shell.scrollCtr,
            scrollBehavior: const NoOverscrollIndicator(),
            pinnedHeaderSliverHeightBuilder: () {
              double pinnedHeight = this.isFullScreen || !isPortrait
                  ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
                  : shell.isExpanding || shell.isCollapsing
                  ? shell.animHeight
                  : shell.isCollapsing ||
                        (source.claimedPlayer?.playerStatus.isPlaying ?? false)
                  ? shell.minVideoHeight
                  : kToolbarHeight;
              if (shell.isExpanding && shell.animationController.value == 1) {
                shell.isExpanding = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  shell.scrollRatio.value = 0;
                  shell.refreshPage();
                });
              } else if (shell.isCollapsing &&
                  shell.animationController.value == 1) {
                shell.isCollapsing = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  shell.refreshPage();
                });
              }
              return pinnedHeight;
            },
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              final height = isFullScreen || !isPortrait
                  ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
                  : shell.isExpanding || shell.isCollapsing
                  ? shell.animHeight
                  : shell.videoHeight;
              return [
                VideoHeader(
                  minExtent: kToolbarHeight,
                  maxExtent: height,
                  minVideoHeight: shell.minVideoHeight,
                  onScrollRatioChanged: shell.scrollRatio.call,
                  child: Stack(
                    clipBehavior: .none,
                    children: [
                      SizedBox(
                        width: maxWidth,
                        height: height,
                        child: videoPlayer(
                          WatchBranch.portrait,
                          width: maxWidth,
                          height: height,
                        ),
                      ),
                      _buildHeaderOverlay(),
                    ],
                  ),
                ),
              ];
            },
            body: MiniScaffold(
              key: shell.childKey,
              body: Column(
                children: [
                  buildTabBar(onTap: shell.animToTop),
                  Expanded(
                    child: tabBarView(
                      hitTestBehavior: .translucent,
                      controller: shell.tabCtr,
                      children: [
                        source.intro(
                          _ctx(
                            WatchBranch.portrait,
                            WatchSlot.tab,
                            isFullScreen: isFullScreen,
                            isHorizontal: false,
                            attachIntroController: false,
                            nested: true,
                          ),
                          withRelated: true,
                        ),
                        if (source.showReply)
                          source.comments(
                            _ctx(
                              WatchBranch.portrait,
                              WatchSlot.tab,
                              isFullScreen: isFullScreen,
                              nested: true,
                            ),
                          ),
                        if (_showPlaylist)
                          source.playlist(
                            _ctx(
                              WatchBranch.portrait,
                              WatchSlot.tab,
                              isFullScreen: isFullScreen,
                              nested: true,
                            ),
                          )!,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildOverlayToolBar(double scrollRatio) {
    final IconData icon;
    final String playStat;
    switch (source.playState) {
      case PlayStateLabel.now:
        icon = Icons.play_arrow_rounded;
        playStat = '立即';
      case PlayStateLabel.replay:
        icon = CustomIcons.replay_rounded;
        playStat = '重新';
      case PlayStateLabel.resume:
        icon = Icons.play_arrow_rounded;
        playStat = '继续';
    }
    final playBtn = Row(
      spacing: 2,
      mainAxisSize: .min,
      children: [
        Icon(icon, color: colorScheme.primary),
        Text(
          '$playStat播放',
          style: TextStyle(color: colorScheme.primary),
        ),
      ],
    );
    return Opacity(
      opacity: shell.scrollRatio.value,
      child: Container(
        color: colorScheme.surface,
        alignment: .topCenter,
        child: SizedBox(
          height: kToolbarHeight,
          child: Stack(
            clipBehavior: .none,
            children: [
              Align(
                alignment: .centerLeft,
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    SizedBox(
                      width: 42,
                      height: 34,
                      child: IconButton(
                        tooltip: '返回',
                        icon: Icon(
                          FontAwesomeIcons.arrowLeft,
                          size: 15,
                          color: colorScheme.onSurface,
                        ),
                        onPressed: Get.back,
                      ),
                    ),
                    SizedBox(
                      width: 42,
                      height: 34,
                      child: IconButton(
                        tooltip: '返回主页',
                        icon: Icon(
                          FontAwesomeIcons.house,
                          size: 15,
                          color: colorScheme.onSurface,
                        ),
                        onPressed: source.sharedPlayer.onCloseAll,
                      ),
                    ),
                  ],
                ),
              ),
              Center(child: playBtn),
              Align(
                alignment: .centerRight,
                child: !source.playedHere
                    ? _moreBtn(colorScheme.onSurface)
                    : SizedBox(
                        width: 42,
                        height: 34,
                        child: IconButton(
                          tooltip: "更多设置",
                          style: const ButtonStyle(
                            padding: WidgetStatePropertyAll(EdgeInsets.zero),
                          ),
                          onPressed: source.openSettings,
                          icon: Icon(
                            Icons.more_vert_outlined,
                            size: 19,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderOverlay() {
    return Obx(
      () {
        final scrollRatio = shell.scrollRatio.value;
        if (scrollRatio == 0) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          bottom: -1,
          child: GestureDetector(
            onTap: source.onCollapsedBarTap,
            behavior: .opaque,
            child: _buildOverlayToolBar(scrollRatio),
          ),
        );
      },
    );
  }

  Widget get childWhenDisabledLandscape => Obx(
    () {
      final isFullScreen = this.isFullScreen;
      return SimpleScaffold(
        appBar: removeAppBar(isFullScreen)
            ? null
            : SimpleAppBar(
                height: padding.top,
                brightness: colorScheme.brightness,
              ),
        body: Padding(
          padding: isFullScreen
              ? EdgeInsets.zero
              : padding.copyWith(top: 0, bottom: 0),
          child: childWhenDisabledLandscapeInner(isFullScreen),
        ),
      );
    },
  );

  Widget childSplit(double ratio) {
    final double videoHeight = maxHeight - padding.vertical;
    final double width = videoHeight * ratio;
    final isFullScreen = this.isFullScreen;
    final videoWidth = isFullScreen ? maxWidth : width;
    final introWidth = maxWidth - width - padding.horizontal;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: videoWidth,
          height: videoHeight,
          child: videoPlayer(
            WatchBranch.split,
            width: videoWidth,
            height: videoHeight,
          ),
        ),
        Offstage(
          offstage: isFullScreen,
          child: SizedBox(
            width: introWidth,
            height: maxHeight - padding.top,
            child: MiniScaffold(
              key: shell.childKey,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildTabBar(),
                  Expanded(
                    child: tabBarView(
                      controller: shell.tabCtr,
                      children: [
                        source.intro(
                          _ctx(
                            WatchBranch.split,
                            WatchSlot.tab,
                            isFullScreen: isFullScreen,
                            width: introWidth,
                            height: maxHeight,
                          ),
                          withRelated: true,
                        ),
                        if (source.showReply)
                          source.comments(
                            _ctx(
                              WatchBranch.split,
                              WatchSlot.tab,
                              isFullScreen: isFullScreen,
                            ),
                          ),
                        if (_showPlaylist)
                          source.playlist(
                            _ctx(
                              WatchBranch.split,
                              WatchSlot.tab,
                              isFullScreen: isFullScreen,
                            ),
                          )!,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget childWhenDisabledLandscapeInner(bool isFullScreen) {
    if (source.sharedPlayer.enableVerticalExpand) {
      return Obx(() {
        if (source.isVertical.value && !layoutIsPortrait) {
          SelfTestProbe.threeColumn(source.pageTag, true);
          final double videoHeight = maxHeight - padding.vertical;
          final double width = videoHeight / Style.aspectRatio16x9;
          final videoWidth = isFullScreen ? maxWidth : width;
          final introWidth = (maxWidth - padding.horizontal - width) / 2;
          final introHeight = maxHeight - padding.top;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Offstage(
                offstage: isFullScreen,
                child: SizedBox(
                  width: introWidth,
                  height: introHeight,
                  child: source.intro(
                    _ctx(
                      WatchBranch.threeColumn,
                      WatchSlot.sideColumn,
                      isFullScreen: isFullScreen,
                      width: introWidth,
                      height: introHeight,
                    ),
                    withRelated: true,
                  ),
                ),
              ),
              SizedBox(
                width: videoWidth,
                height: videoHeight,
                child: videoPlayer(
                  WatchBranch.threeColumn,
                  width: videoWidth,
                  height: videoHeight,
                ),
              ),
              Offstage(
                offstage: isFullScreen,
                child: SizedBox(
                  width: introWidth,
                  height: introHeight,
                  child: MiniScaffold(
                    key: shell.childKey,
                    body: Column(
                      children: [
                        buildTabBar(showIntro: false),
                        Expanded(
                          child: tabBarView(
                            controller: shell.tabCtr,
                            children: [
                              if (source.showReply)
                                source.comments(
                                  _ctx(
                                    WatchBranch.threeColumn,
                                    WatchSlot.tab,
                                    isFullScreen: isFullScreen,
                                  ),
                                ),
                              if (_showPlaylist)
                                source.playlist(
                                  _ctx(
                                    WatchBranch.threeColumn,
                                    WatchSlot.tab,
                                    isFullScreen: isFullScreen,
                                  ),
                                )!,
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        SelfTestProbe.threeColumn(source.pageTag, false);
        return _childWhenDisabledLandscapeInner(isFullScreen);
      });
    }
    SelfTestProbe.threeColumn(source.pageTag, false);
    return _childWhenDisabledLandscapeInner(isFullScreen);
  }

  Widget _childWhenDisabledLandscapeInner(bool isFullScreen) {
    double width =
        clampDouble(maxHeight / maxWidth * 1.08, 0.5, 0.7) * maxWidth;
    if (maxWidth >= 560) {
      width = maxWidth - clampDouble(maxWidth - width, 280, 425);
    }
    final videoWidth = isFullScreen ? maxWidth : width;
    final double height = width / Style.aspectRatio16x9;
    final videoHeight = isFullScreen
        ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
        : height;
    SelfTestProbe.split16x9(source.pageTag, height > maxHeight);
    if (height > maxHeight) {
      return childSplit(Style.aspectRatio16x9);
    }
    final introHeight = maxHeight - height - padding.top;
    final showIntro = source.showRelated;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: videoWidth,
              height: videoHeight,
              child: videoPlayer(
                WatchBranch.landscape,
                width: videoWidth,
                height: videoHeight,
              ),
            ),
            if (source.introColumnInLandscape)
              Offstage(
                offstage: isFullScreen,
                child: SizedBox(
                  width: width,
                  height: introHeight,
                  child: source.intro(
                    _ctx(
                      WatchBranch.landscape,
                      WatchSlot.introColumn,
                      isFullScreen: isFullScreen,
                      width: width,
                      height: introHeight,
                      attachIntroController: false,
                    ),
                    withRelated: false,
                  ),
                ),
              ),
          ],
        ),
        Offstage(
          offstage: isFullScreen,
          child: SizedBox(
            width: maxWidth - width - padding.horizontal,
            height: maxHeight - padding.top,
            child: MiniScaffold(
              key: shell.childKey,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildTabBar(
                    introText: '相关视频',
                    showIntro: source.isFileSource ? true : showIntro,
                  ),
                  Expanded(
                    child: tabBarView(
                      controller: shell.tabCtr,
                      children: [
                        if (source.isFileSource)
                          source.intro(
                            _ctx(
                              WatchBranch.landscape,
                              WatchSlot.tab,
                              isFullScreen: isFullScreen,
                            ),
                            withRelated: true,
                          )
                        else if (showIntro)
                          source.related(
                            _ctx(
                              WatchBranch.landscape,
                              WatchSlot.tab,
                              isFullScreen: isFullScreen,
                            ),
                          )!,
                        if (source.showReply)
                          source.comments(
                            _ctx(
                              WatchBranch.landscape,
                              WatchSlot.tab,
                              isFullScreen: isFullScreen,
                            ),
                          ),
                        if (_showPlaylist)
                          source.playlist(
                            _ctx(
                              WatchBranch.landscape,
                              WatchSlot.tab,
                              isFullScreen: isFullScreen,
                            ),
                          )!,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget get childWhenDisabledAlmostSquare => Obx(() {
    final isFullScreen = this.isFullScreen;
    return SimpleScaffold(
      appBar: removeAppBar(isFullScreen)
          ? null
          : SimpleAppBar(
              height: padding.top,
              brightness: colorScheme.brightness,
            ),
      body: Padding(
        padding: isFullScreen
            ? EdgeInsets.zero
            : padding.copyWith(top: 0, bottom: 0),
        child: childWhenDisabledAlmostSquareInner(isFullScreen),
      ),
    );
  });

  Widget childWhenDisabledAlmostSquareInner(bool isFullScreen) {
    if (source.sharedPlayer.enableVerticalExpand) {
      return Obx(
        () {
          if (source.isVertical.value && !layoutIsPortrait) {
            SelfTestProbe.split9x16(source.pageTag, true);
            return childSplit(9 / 16);
          }

          SelfTestProbe.split9x16(source.pageTag, false);
          return _childWhenDisabledAlmostSquareInner(isFullScreen);
        },
      );
    }

    SelfTestProbe.split9x16(source.pageTag, false);
    return _childWhenDisabledAlmostSquareInner(isFullScreen);
  }

  Widget _childWhenDisabledAlmostSquareInner(bool isFullScreen) {
    final shouldShowSeasonPanel = _showPlaylist;
    final double height = maxHeight / 2.5;
    final videoHeight = isFullScreen
        ? maxHeight - (isWindowMode && !isPortrait ? 0 : padding.top)
        : height;
    final bottomHeight = maxHeight - height - padding.top;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: maxWidth,
          height: videoHeight,
          child: videoPlayer(
            WatchBranch.almostSquare,
            width: maxWidth,
            height: videoHeight,
          ),
        ),
        Offstage(
          offstage: isFullScreen,
          child: SizedBox(
            width: maxWidth - padding.horizontal,
            height: bottomHeight,
            child: MiniScaffold(
              key: shell.childKey,
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildTabBar(needIndicator: false),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: source.intro(
                            _ctx(
                              WatchBranch.almostSquare,
                              WatchSlot.row,
                              isFullScreen: isFullScreen,
                              width: () {
                                double flex = 1;
                                if (source.showReply) flex++;
                                if (shouldShowSeasonPanel) flex++;
                                return maxWidth / flex;
                              }(),
                              height: bottomHeight,
                            ),
                            withRelated: true,
                          ),
                        ),
                        if (source.showReply)
                          Expanded(
                            child: source.comments(
                              _ctx(
                                WatchBranch.almostSquare,
                                WatchSlot.row,
                                isFullScreen: isFullScreen,
                              ),
                            ),
                          ),
                        if (shouldShowSeasonPanel)
                          Expanded(
                            child: source.playlist(
                              _ctx(
                                WatchBranch.almostSquare,
                                WatchSlot.row,
                                isFullScreen: isFullScreen,
                              ),
                            )!,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget manualPlayerWidget(double height) => Obx(() {
    if (!source.autoPlay) {
      return Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: kToolbarHeight,
            child: Row(
              children: [
                SizedBox(
                  width: 42,
                  height: 34,
                  child: IconButton(
                    tooltip: '返回',
                    icon: const Icon(
                      FontAwesomeIcons.arrowLeft,
                      size: 15,
                      color: Colors.white,
                      shadows: [
                        Shadow(
                          blurRadius: 1.5,
                          color: Colors.black,
                        ),
                      ],
                    ),
                    onPressed: Get.back,
                  ),
                ),
                SizedBox(
                  width: 42,
                  height: 34,
                  child: IconButton(
                    tooltip: '返回主页',
                    icon: const Icon(
                      FontAwesomeIcons.house,
                      size: 15,
                      color: Colors.white,
                      shadows: [
                        Shadow(
                          blurRadius: 1.5,
                          color: Colors.black,
                        ),
                      ],
                    ),
                    onPressed: source.sharedPlayer.onCloseAll,
                  ),
                ),
                const Spacer(),
                _moreBtn(
                  Colors.white,
                  shadows: const [
                    Shadow(
                      blurRadius: 1.5,
                      color: Colors.black,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            right: 12,
            top: height - 70,
            child: const PlayIcon(),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  });

  /// 「更多」: the page's menu (none given: no button)
  Widget _moreBtn(Color color, {List<Shadow>? shadows}) {
    final menu = source.moreMenu;
    if (menu == null) return const SizedBox.shrink();
    return PopupMenuButton(
      icon: Icon(
        size: 22,
        Icons.more_vert,
        color: color,
        shadows: shadows,
      ),
      itemBuilder: menu,
    );
  }

  /// The player's popScope (the key keeps the player's State across the
  /// branches, R3; the controller reads it, §3.3), with the stand-in or the
  /// page's player in it (R10).
  Widget plPlayer(WatchLayoutContext ctx, {bool isPipMode = false}) {
    final width = ctx.slotWidth!;
    final height = ctx.slotHeight!;
    return popScope(
      key: shell.videoPlayerKey,
      canPop:
          !isFullScreen &&
          !source.sharedPlayer.isDesktopPip &&
          (source.sharedPlayer.horizontalScreen || isPortrait),
      onPopInvokedWithResult: source.sharedPlayer.onPopInvokedWithResult,
      child: Obx(
        () =>
            // transcription is a peer of the stream: when subtitles are going
            // to be generated for this video, it is not ready until they have
            // started arriving (the gate shows); autoplay off has the cover
            // and its play button
            source.gateUp || !source.autoPlay
            ? const SizedBox.shrink()
            : !source.viewUp
            // LibrePili: the player not up yet — the cover (or the picture
            // left at a push), the spinner and the way back, not a black box
            // with nothing on it (audit 2026-10-21)
            ? _playerStandIn(ctx, width, height)
            : source.player(ctx, isPipMode: isPipMode),
      ),
    );
  }

  /// Where the player will be, while it is not up (see [plPlayer]).
  Widget _playerStandIn(WatchLayoutContext ctx, double width, double height) {
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Obx(
            () => PlayerCover(
              cover: source.cover,
              picture: source.pictureAtPush,
              width: width,
              height: height,
            ),
          ),
          Center(
            child: Obx(
              // the open failed: said, and tried again on a tap. This page's
              // open only: the player's status is the whole app's, and a
              // page over one whose open failed showed its error (review
              // 2026-10-21)
              () => source.loadFailed
                  ? source.failure(ctx) ??
                        PlayerLoadFailed(onRetry: source.retry)
                  : const PlayerLoadingMark(),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            child: SizedBox(
              width: 42,
              height: 34,
              child: IconButton(
                tooltip: '返回',
                icon: const Icon(
                  FontAwesomeIcons.arrowLeft,
                  size: 15,
                  color: Colors.white,
                  shadows: [Shadow(blurRadius: 1.5, color: Colors.black)],
                ),
                onPressed: Get.back,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static TabRole _roleOf(String text) => switch (text) {
    '评论' => TabRole.comments,
    '播放列表' => TabRole.playlist,
    '相关视频' => TabRole.related,
    _ => TabRole.intro,
  };

  Widget buildTabBar({
    bool needIndicator = true,
    String? introText,
    bool showIntro = true,
    VoidCallback? onTap,
  }) {
    final tabs = [
      if (showIntro) source.isFileSource ? '离线视频' : introText ?? '简介',
      if (source.showReply) '评论',
      if (_showPlaylist) '播放列表',
    ];
    if (shell.tabCtr.length != tabs.length) {
      shell.tabCtr.dispose();
      shell.tabCtr = TabController(
        vsync: shell.vsync,
        length: tabs.length,
        initialIndex: tabs.isEmpty
            ? 0
            : shell.tabCtr.index.clamp(0, tabs.length - 1),
      );
    }

    Widget tabBar() {
      final flag = !needIndicator || tabs.length == 1;
      return TabBar(
        padding: .zero,
        dividerHeight: 0,
        labelPadding: .zero,
        dividerColor: Colors.transparent,
        controller: shell.tabCtr,
        indicator: flag ? const BoxDecoration() : null,
        labelColor: flag ? colorScheme.onSurface : null,
        labelStyle:
            TabBarTheme.of(source.pageContext).labelStyle?.copyWith(
              fontSize: 13,
            ) ??
            const TextStyle(fontSize: 13),
        onTap: (value) {
          void animToTop() {
            if (onTap != null) {
              onTap();
              return;
            }
            source.onReselect(_roleOf(tabs[value]));
          }

          if (flag) {
            animToTop();
          } else if (!shell.tabCtr.indexIsChanging) {
            animToTop();
          }
        },
        tabs: tabs.map((text) {
          if (text == '评论') {
            return source.commentsLabel?.call() ?? const Tab(text: '评论');
          } else {
            return Tab(
              child: Text(text, softWrap: false, overflow: .visible),
            );
          }
        }).toList(),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: SizedBox(
        height: 45,
        child: Row(
          children: [
            if (tabs.isEmpty)
              const Spacer()
            else
              Expanded(
                child: Align(
                  alignment: .centerLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 96.0 * tabs.length),
                    child: tabBar(),
                  ),
                ),
              ),
            ...source.tabBarTrailing,
            const SizedBox(width: 14),
          ],
        ),
      ),
    );
  }

  /// The player slot (§3.2 「播放器插槽的叠放顺序」), bottom to top.
  Widget videoPlayer(
    WatchBranch branch, {
    required double width,
    required double height,
  }) {
    final isFullScreen = this.isFullScreen;
    final ctx = _ctx(
      branch,
      WatchSlot.player,
      isFullScreen: isFullScreen,
      width: width,
      height: height,
    );
    // LibrePili: each layer under a key naming its role, for the self-test
    // to read the order by (SelfTestProbe.slotBlack); a KeyedSubtree makes
    // no render object, so a Positioned under it still reaches the Stack
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const KeyedSubtree(
          key: ValueKey(SelfTestProbe.slotBlack),
          child: Positioned.fill(
            child: ColoredBox(
              color: Colors.black,
              isAntiAlias: false,
            ),
          ),
        ),

        KeyedSubtree(
          key: const ValueKey(SelfTestProbe.slotPlayer),
          child: plPlayer(ctx),
        ),

        // LibrePili: the player is hidden while it waits for the subtitles
        // the switch makes on the device; this was a silent black box (3A)
        KeyedSubtree(
          key: const ValueKey(SelfTestProbe.slotGate),
          child: Obx(
            () => source.gateUp
                ? Positioned.fill(
                    child: source.gate ?? const SizedBox.shrink(),
                  )
                : const SizedBox.shrink(),
          ),
        ),

        KeyedSubtree(
          key: const ValueKey(SelfTestProbe.slotCover),
          child: Obx(() {
            if (!source.autoPlay) {
              return Positioned.fill(
                child: GestureDetector(
                  onTap: source.onPlayTap,
                  behavior: .opaque,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Obx(
                        () => NetworkImgLayer(
                          type: .emote,
                          quality: 60,
                          src: source.cover,
                          width: width,
                          height: height,
                          cacheWidth: true,
                          getPlaceHolder: () => Center(
                            child: Image.asset(Assets.loading),
                          ),
                        ),
                      ),
                      // a tap while the play URL is asked for: it plays once
                      // the URL is in (see the page's onPlayTap)
                      Obx(
                        () => source.playPending
                            ? const Center(child: PlayerLoadingMark())
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              );
            }
            return const SizedBox.shrink();
          }),
        ),
        KeyedSubtree(
          key: const ValueKey(SelfTestProbe.slotManualPlayer),
          child: manualPlayerWidget(height),
        ),

        // the page's own layers over the player (SponsorBlock list,
        // interactive-video choices), in their order
        ...source.playerOverlays(ctx),
      ],
    );
  }
}
