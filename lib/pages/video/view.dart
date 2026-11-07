import 'dart:io' show Platform;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/common/widgets/keep_alive_wrapper.dart';
import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/common/widgets/scroll_physics.dart'
    show platformAlwaysClampingPhysics;
import 'package:PiliPlus/models/common/episode_panel_type.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/models_new/video/video_detail/ugc_season.dart';
import 'package:PiliPlus/models_new/video/video_tag/data.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/common/watch_page/watch_page_route.dart';
import 'package:PiliPlus/pages/common/watch_page/watch_page_shell.dart';
import 'package:PiliPlus/pages/common/watch_page/watch_page_source.dart';
import 'package:PiliPlus/pages/common/watch_page/watch_page_state.dart';
import 'package:PiliPlus/pages/danmaku/view.dart';
import 'package:PiliPlus/pages/episode_panel/view.dart';
import 'package:PiliPlus/pages/video/ai_conclusion/view.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/intro_header.dart';
import 'package:PiliPlus/pages/video/introduction/local/view.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/view.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/widgets/intro_detail.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/view.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/page.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/season.dart';
import 'package:PiliPlus/pages/video/member/controller.dart';
import 'package:PiliPlus/pages/video/member/view.dart';
import 'package:PiliPlus/pages/video/related/view.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/pages/video/reply/local_reply_panel.dart';
import 'package:PiliPlus/pages/video/reply/view.dart';
import 'package:PiliPlus/pages/video/view_point/view.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart';
import 'package:PiliPlus/pages/video/widgets/intro_layout.dart';
import 'package:PiliPlus/pages/video/widgets/subtitle_gate.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/plugin/pl_player/view/view.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart'
    show shutdownTimerService;
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/max_screen_size.dart';
import 'package:PiliPlus/utils/mobile_observer.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/self_test_probe.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

class VideoDetailPageV extends StatefulWidget {
  const VideoDetailPageV({super.key});

  @override
  State<VideoDetailPageV> createState() => _VideoDetailPageVState();
}

class _VideoDetailPageVState extends State<VideoDetailPageV>
    with RouteAware, RouteAwareMixin, WidgetsBindingObserver, WatchPageSource {
  final heroTag = Get.arguments['heroTag'];

  late final VideoDetailController videoDetailController;
  late final VideoReplyController _videoReplyController;
  PlPlayerController? plPlayerController;

  // intro ctr
  @override
  late final CommonIntroController introController =
      videoDetailController.isFileSource
      ? localIntroController
      : videoDetailController.isUgc
      ? ugcIntroController
      : pgcIntroController;
  late final UgcIntroController ugcIntroController;
  late final PgcIntroController pgcIntroController;
  late final LocalIntroController localIntroController;

  bool get autoExitFullscreen =>
      videoDetailController.plPlayerController.autoExitFullscreen;

  bool get autoPlayEnable =>
      videoDetailController.plPlayerController.autoPlayEnable;

  bool get enableVerticalExpand =>
      videoDetailController.plPlayerController.enableVerticalExpand;

  bool get pipNoDanmaku =>
      videoDetailController.plPlayerController.pipNoDanmaku;

  bool isShowing = true;

  bool get isFullScreen =>
      videoDetailController.plPlayerController.isFullScreen.value;

  @override
  bool showPlaylist({required bool isPortrait}) {
    if (videoDetailController.isFileSource ||
        isPortrait ||
        !videoDetailController.isUgc) {
      return false;
    }
    late final videoDetail = ugcIntroController.videoDetail.value;
    return videoDetailController.plPlayerController.horizontalSeasonPanel &&
        (videoDetail.ugcSeason != null ||
            ((videoDetail.pages?.length ?? 0) > 1));
  }

  final videoReplyPanelKey = GlobalKey();
  final videoRelatedKey = GlobalKey();
  final videoIntroKey = GlobalKey();

  @override
  void initState() {
    super.initState();

    PlPlayerController.setPlayCallBack(playCallBack);
    videoDetailController = Get.put(VideoDetailController(), tag: heroTag);
    SelfTestProbe.addPage(heroTag, context);

    if (videoDetailController.removeSafeArea) {
      hideSystemBar();
    }

    if (videoDetailController.showReply &&
        !videoDetailController.isFileSource) {
      _videoReplyController = Get.put(
        VideoReplyController(
          aid: videoDetailController.aid,
          videoType: videoDetailController.videoType,
          heroTag: heroTag,
        ),
        tag: heroTag,
      );
    }

    if (videoDetailController.isFileSource) {
      localIntroController = Get.put(LocalIntroController(), tag: heroTag);
    } else if (videoDetailController.isUgc) {
      ugcIntroController = Get.put(UgcIntroController(), tag: heroTag);
    } else {
      pgcIntroController = Get.put(PgcIntroController(), tag: heroTag);
    }

    videoSourceInit();

    addObserverMobile(this);
  }

  // 获取视频资源，初始化播放器
  void videoSourceInit() {
    videoDetailController.queryVideoUrl(autoFullScreenFlag: true);
    if (videoDetailController.autoPlay) {
      plPlayerController = videoDetailController.plPlayerController;
      plPlayerController!
        ..addStatusLister(playerListener)
        ..addPositionListener(positionListener);
    }
  }

  void positionListener(Duration position) {
    // the shared player still on the page before's video: its position is
    // not this one's (53 s of the last video was saved as a 14.7 s video's
    // resume point, and it opened at its end, 2026-10-12)
    if (!videoDetailController.ownsPlayer) return;
    videoDetailController
      ..playedTime = position
      ..onLocalPosition(position)
      ..saveLocalHistory();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isResume = state == .resumed;
    final ctr = videoDetailController.plPlayerController..visible = isResume;
    if (isResume) {
      if (!ctr.showDanmaku) {
        introController.startTimer();
        ctr.showDanmaku = true;
      }
    } else if (state == .paused) {
      if (videoDetailController.isFileSource) {
        videoDetailController.cacheLocalProgress();
      }
      // the process may not come back from the background
      videoDetailController.saveLocalHistory(force: true);
      introController.cancelTimer();
      ctr.showDanmaku = false;
    }
  }

  Future<void>? playCallBack() {
    if (isSelfTestProfile) {
      EventLog.add(
        'selftest',
        'play callback answered: bilibili page $heroTag, controller '
            '${identityHashCode(videoDetailController)}',
      );
    }
    if (!isShowing) {
      plPlayerController
        ?..addStatusLister(playerListener)
        ..addPositionListener(positionListener);
    }
    return plPlayerController?.play();
  }

  // 播放器状态监听
  Future<void> playerListener(PlayerStatus status) async {
    final isPlaying = status.isPlaying;
    if (!isPlaying) {
      videoDetailController.saveLocalHistory(
        force: true,
        completed: status.isCompleted,
      );
    }
    videoDetailController.shell.onPlayerStatus(status);

    if (status.isCompleted) {
      try {
        if (videoDetailController
                .steinEdgeInfo
                ?.edges
                ?.questions
                ?.firstOrNull
                ?.choices
                ?.isNotEmpty ==
            true) {
          videoDetailController.showSteinEdgeInfo.value = true;
          return;
        }
      } catch (_) {}

      bool exitFlag = true;

      /// 顺序播放 列表循环
      if (shutdownTimerService.isWaiting) {
        shutdownTimerService.handleWaiting();
      } else {
        switch (plPlayerController!.playRepeat) {
          case PlayRepeat.singleCycle:
            exitFlag = false;
            plPlayerController!.play(repeat: true);
          case PlayRepeat.listOrder:
          case PlayRepeat.listCycle:
          case PlayRepeat.autoPlayRelated:
            exitFlag = !introController.nextPlay();
          case PlayRepeat.pause:
        }
      }

      if (exitFlag) {
        if (autoExitFullscreen) {
          plPlayerController!.triggerFullScreen(status: false);
          if (plPlayerController!.controlsLock.value) {
            plPlayerController!.onLockControl(false);
          }
        } else {
          if (plPlayerController!.controlsLock.value &&
              (!Platform.isAndroid || !AndroidHelper.isPipMode)) {
            plPlayerController!.onLockControl(false);
          }
        }
      }
    }
  }

  // 继续播放或重新播放
  void continuePlay() {
    plPlayerController!.play();
  }

  /// A tap on the cover remembered while the play URL was asked for (see
  /// [handlePlay]); moved on by a push, which drops it.
  var _playTap = 0;

  /// 未开启自动播放时触发播放
  Future<void>? handlePlay() {
    if (!videoDetailController.isFileSource) {
      if (videoDetailController.isQuerying) {
        if (kDebugMode) debugPrint('handlePlay: querying');
        // LibrePili: remembered, and played once the play URL is in, the
        // cover showing the spinner meanwhile (it was dropped silently)
        final done = videoDetailController.queryDone;
        if (done == null || videoDetailController.playAfterQuery.value) {
          return null;
        }
        videoDetailController.playAfterQuery.value = true;
        // played only on this page, still on top, with nothing opened on
        // the shared player meanwhile: a page pushed over it in between
        // drops it (see didPushNext), or it would take the player from
        // that page (review 2026-10-21)
        final tap = ++_playTap;
        final opens = videoDetailController.plPlayerController.openCount;
        return done.then((_) {
          if (tap != _playTap) return null;
          videoDetailController.playAfterQuery.value = false;
          if (mounted &&
              isShowing &&
              !videoDetailController.autoPlay &&
              videoDetailController.plPlayerController.openCount == opens) {
            return handlePlay();
          }
          return null;
        });
      }
      if (videoDetailController.videoUrl == null ||
          videoDetailController.audioUrl == null) {
        if (kDebugMode) {
          debugPrint('handlePlay: videoUrl/audioUrl not initialized');
        }
        videoDetailController.queryVideoUrl();
        return null;
      }
    }
    final plPlayerController = this.plPlayerController =
        videoDetailController.plPlayerController;
    videoDetailController.autoPlay = true;
    plPlayerController
      ..addStatusLister(playerListener)
      ..addPositionListener(positionListener);
    if (plPlayerController.preInitPlayer) {
      if (plPlayerController.autoEnterFullScreen) {
        plPlayerController.triggerFullScreen();
      }
      return plPlayerController.play();
    } else {
      return videoDetailController.playerInit(
        autoplay: true,
        autoFullScreenFlag: true,
      );
    }
  }

  @override
  void dispose() {
    SelfTestProbe.removePage(heroTag, context);
    plPlayerController
      ?..removeStatusLister(playerListener)
      ..removePositionListener(positionListener);

    Get.delete<HorizontalMemberPageController>(
      tag: videoDetailController.heroTag,
    );

    if (!videoDetailController.isFileSource) {
      if (videoDetailController.isUgc) {
        ugcIntroController
          ..cancelTimer()
          ..videoDetail.close();
      } else {
        pgcIntroController.cancelTimer();
      }
    }

    if (!videoDetailController.removeSafeArea) {
      showSystemBar();
    }

    if (!videoDetailController.plPlayerController.isCloseAll) {
      videoPlayerServiceHandler?.onVideoDetailDispose(heroTag);
      if (plPlayerController != null) {
        videoDetailController
          ..makeHeartBeat()
          ..saveLocalHistory(force: true);
        plPlayerController!.dispose();
      } else {
        PlPlayerController.updatePlayCount();
      }
    }
    removeObserverMobile(this);

    super.dispose();
  }

  @override
  // 离开当前页面时
  void didPushNext() {
    super.didPushNext();
    WatchPageRoute.didPushNext(this);
  }

  @override
  void onCovered() {
    isShowing = false;
    // a cover tap waiting for the play URL is not played under the page
    // on top (see handlePlay)
    _playTap++;
    videoDetailController.playAfterQuery.value = false;

    removeObserverMobile(this);

    if (Platform.isAndroid && !videoDetailController.setSystemBrightness) {
      ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
    }

    introController.cancelTimer();

    // LibrePili: the player's view stays up through the push (it went
    // black at once); it goes only if the page over this one takes the
    // player (see VideoDetailController._whenTaken). The picture now, for a
    // return after that: shown over the reopen rather than a black area
    if (plPlayerController case final ctr?
        when videoDetailController.videoState.value &&
            videoDetailController.ownsPlayer) {
      // at most 1280 px on its longest side: it is only up until the first
      // frame, and each covered page keeps one (review 2026-10-21)
      ctr.captureVideo?.call(maxSide: 1280).then(
        (image) {
          if (image == null) return;
          if (!mounted || isShowing) {
            image.dispose();
            return;
          }
          videoDetailController.setPictureAtPush(image);
        },
        onError: (Object _) {},
      );
    }
    videoDetailController
      ..setCovered(true)
      ..cancelBlockListener()
      ..playerStatus = plPlayerController?.playerStatus.value
      ..brightness = plPlayerController?.brightness.value;
    if (plPlayerController != null) {
      videoDetailController
        ..makeHeartBeat()
        ..saveLocalHistory(force: true);
      plPlayerController!
        ..removeStatusLister(playerListener)
        ..removePositionListener(positionListener)
        ..pause();
    }
  }

  @override
  // 返回当前页面时
  void didPopNext() {
    super.didPopNext();
    WatchPageRoute.didPopNext(this);
  }

  @override
  void onUncovered() {
    if (videoDetailController.plPlayerController.isCloseAll) {
      return;
    }

    isShowing = true;

    addObserverMobile(this);

    plPlayerController?.isLive = false;
    if (videoDetailController.plPlayerController.playerStatus.isPlaying &&
        videoDetailController.playerStatus != PlayerStatus.playing) {
      videoDetailController.plPlayerController.pause();
    }

    PlPlayerController.setPlayCallBack(playCallBack);

    introController.startTimer();

    if (mounted &&
        Platform.isAndroid &&
        !videoDetailController.setSystemBrightness) {
      if (videoDetailController.brightness != null) {
        plPlayerController?.brightness.value =
            videoDetailController.brightness!;
        if (videoDetailController.brightness != -1.0) {
          ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(
            videoDetailController.brightness!,
          );
        } else {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      } else {
        ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
      }
    }

    plPlayerController
      ?..addStatusLister(playerListener)
      ..addPositionListener(positionListener);
    // LibrePili: opened again only if another page took the player; still
    // this page's, it goes on as it was (it was opened again every time).
    // A play URL that came while covered opens now
    if (videoDetailController.openAtReturn()) {
      // that open is the return's: nothing else is resumed or opened
    } else if (videoDetailController.autoPlay) {
      final play = videoDetailController.playerStatus?.isPlaying ?? false;
      if (!videoDetailController.resumeOwnPlayer(play: play)) {
        // the picture taken at the push, with the spinner, until a frame
        videoDetailController.videoState.value = false;
        videoDetailController.playerInit(autoplay: play);
      }
    } else if (videoDetailController.plPlayerController.preInitPlayer &&
        !videoDetailController.isQuerying &&
        videoDetailController.videoUrl != null &&
        // still this page's: its hooks back (a covering video page set
        // its own and took them with it), paused as it was
        !videoDetailController.resumeOwnPlayer(play: false)) {
      videoDetailController.playerInit();
    }
    videoDetailController.setCovered(false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (videoDetailController.removeSafeArea) {
      padding = .zero;
    } else {
      padding = MediaQuery.viewPaddingOf(context);
    }

    final size = MediaQuery.sizeOf(context);
    maxWidth = size.width;
    maxHeight = size.height;
    isWindowMode = MaxScreenSize.isWindowMode(
      width: maxWidth * videoDetailController.uiScale,
      height: maxHeight * videoDetailController.uiScale,
    );
    videoDetailController.plPlayerController.screenRatio = maxHeight / maxWidth;

    final shortestSide = size.shortestSide;
    final minVideoHeight = shortestSide / Style.aspectRatio16x9;
    final maxVideoHeight = max(size.longestSide * 0.65, shortestSide);
    videoDetailController.shell
      ..isPortrait = isPortrait = maxHeight >= maxWidth
      ..minVideoHeight = minVideoHeight
      ..maxVideoHeight = maxVideoHeight
      ..videoHeight = videoDetailController.isVertical.value
          ? maxVideoHeight
          : minVideoHeight;

    theme = videoDetailController.plPlayerController.darkVideoPage
        ? ThemeUtils.darkTheme
        : Theme.of(context);
  }

  // ---- WatchPageSource (design feature-logs/watch-page-shell/design.md
  // §3.2): the shell (lib/pages/common/watch_page/) lays the page out and
  // asks for these

  @override
  WatchPageShellState get shell => videoDetailController.shell;

  @override
  PlPlayerController get sharedPlayer =>
      videoDetailController.plPlayerController;

  @override
  PlPlayerController? get claimedPlayer => plPlayerController;

  @override
  bool get pageIsPortrait => isPortrait;

  @override
  BuildContext get pageContext => context;

  @override
  String get pageTag => heroTag;

  @override
  RxBool get isVertical => videoDetailController.isVertical;

  @override
  bool get isFileSource => videoDetailController.isFileSource;

  @override
  bool get showReply => videoDetailController.showReply;

  @override
  bool get showRelated =>
      videoDetailController.isUgc && videoDetailController.showRelatedVideo;

  @override
  bool get introColumnInLandscape => !videoDetailController.isFileSource;

  @override
  bool get ownsPlayer => videoDetailController.ownsPlayer;

  @override
  VoidCallback get onPlayTap => handlePlay;

  @override
  bool get playPending => videoDetailController.playAfterQuery.value;

  @override
  bool get gateUp => videoDetailController.asrPending.value;

  @override
  bool get autoPlay => videoDetailController.autoPlay;

  @override
  bool get viewUp =>
      videoDetailController.videoState.value &&
      plPlayerController?.videoController != null;

  @override
  String get cover => videoDetailController.cover.value;

  @override
  ui.Image? get pictureAtPush => videoDetailController.pictureAtPush.value;

  @override
  bool get loadFailed =>
      videoDetailController.plPlayerController.dataStatus.error &&
      videoDetailController.ownsPlayer;

  @override
  VoidCallback get retry => videoDetailController.retryPlayer;

  @override
  Widget get gate => SubtitleGate(
    skippable: videoDetailController.asrGateSkippable.value,
    onSkip: videoDetailController.skipSubtitleGate,
  );

  @override
  bool get playedHere => videoDetailController.playedTime != null;

  @override
  PlayStateLabel get playState {
    if (videoDetailController.playedTime == null) {
      return PlayStateLabel.now;
    } else if (plPlayerController!.isCompleted) {
      return PlayStateLabel.replay;
    } else {
      return PlayStateLabel.resume;
    }
  }

  @override
  VoidCallback get onCollapsedBarTap => _onCollapsedBarTap;

  void _onCollapsedBarTap() {
    if (!videoDetailController.isFileSource) {
      if (videoDetailController.isQuerying) {
        if (kDebugMode) {
          debugPrint('handlePlay: querying');
        }
        // remembered there (see handlePlay)
        if (!videoDetailController.autoPlay) handlePlay();
        return;
      }
      if (videoDetailController.videoUrl == null ||
          videoDetailController.audioUrl == null) {
        if (kDebugMode) {
          debugPrint('handlePlay: videoUrl/audioUrl not initialized');
        }
        videoDetailController.queryVideoUrl();
        return;
      }
    }
    if (plPlayerController == null ||
        videoDetailController.playedTime == null) {
      handlePlay();
    } else {
      plPlayerController!.onDoubleTapCenter();
    }
  }

  @override
  VoidCallback get openSettings =>
      () =>
          (videoDetailController.shell.headerCtrKey.currentState
                  as HeaderControlState?)
              ?.showSettingSheet();

  @override
  List<PopupMenuEntry> Function(BuildContext menuContext) get moreMenu =>
      _moreMenu;

  List<PopupMenuEntry> _moreMenu(BuildContext context) => <PopupMenuEntry>[
    if (Accounts.main.isLogin)
      PopupMenuItem(
        onTap: introController.viewLater,
        child: const Text('稍后再看'),
      ),
    if (videoDetailController.epId == null)
      PopupMenuItem(
        onTap: () => videoDetailController.showNoteList(context),
        child: const Text('查看笔记'),
      ),
    if (!videoDetailController.isFileSource)
      PopupMenuItem(
        onTap: () => videoDetailController.onDownload(this.context),
        child: const Text('缓存视频'),
      ),
    if (videoDetailController.cover.value.isNotEmpty)
      PopupMenuItem(
        onTap: () =>
            ImageUtils.downloadImg([videoDetailController.cover.value]),
        child: const Text('保存封面'),
      ),
    if (!videoDetailController.isFileSource && videoDetailController.isUgc)
      PopupMenuItem(
        onTap: videoDetailController.toAudioPage,
        child: const Text('听音频'),
      ),
    PopupMenuItem(
      onTap: () {
        if (!Accounts.main.isLogin) {
          SmartDialog.showToast('账号未登录');
        } else {
          PageUtils.reportVideo(videoDetailController.aid);
        }
      },
      child: const Text('举报'),
    ),
  ];

  @override
  VoidCallback get onSendDanmaku => videoDetailController.showShootDanmakuSheet;

  @override
  ValueGetter<bool> get onSkipSegment => videoDetailController.onSkipSegment;

  @override
  bool canPlay() {
    if (videoDetailController.autoPlay) {
      return true;
    }
    handlePlay();
    return false;
  }

  @override
  Widget player(WatchLayoutContext ctx, {required bool isPipMode}) {
    final width = ctx.slotWidth!;
    final height = ctx.slotHeight!;
    return PLVideoPlayer(
      maxWidth: width,
      maxHeight: height,
      plPlayerController: plPlayerController!,
      videoDetailController: videoDetailController,
      introController: introController,
      headerControl: HeaderControl(
        key: videoDetailController.shell.headerCtrKey,
        isPortrait: isPortrait,
        controller: videoDetailController.plPlayerController,
        videoDetailCtr: videoDetailController,
        heroTag: heroTag,
      ),
      danmuWidget: isPipMode && pipNoDanmaku
          ? null
          : Obx(
              () => PlDanmaku(
                key: ValueKey(videoDetailController.cid.value),
                isPipMode: isPipMode,
                cid: videoDetailController.cid.value,
                playerController: plPlayerController!,
                isFullScreen: plPlayerController!.isFullScreen.value,
                isFileSource: videoDetailController.isFileSource,
                size: Size(width, height),
              ),
            ),
      showEpisodes: showEpisodes,
      showViewPoints: showViewPoints,
    );
  }

  @override
  late ThemeData theme;
  ColorScheme get colorScheme => theme.colorScheme;
  late bool isPortrait;
  @override
  late double maxWidth;
  @override
  late double maxHeight;
  @override
  bool isWindowMode = false;
  @override
  late EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    SelfTestProbe.recorder?.built('build', heroTag, Size(maxWidth, maxHeight));
    return WatchPageShell(source: this);
  }

  @override
  List<Widget> get tabBarTrailing => [
    if (!Pref.hideInteraction &&
        Accounts.main.isLogin &&
        !videoDetailController.isFileSource)
      SizedBox(
        height: 32,
        child: TextButton(
          style: const ButtonStyle(
            padding: WidgetStatePropertyAll(.zero),
          ),
          onPressed: videoDetailController.showShootDanmakuSheet,
          child: Text(
            '发弹幕',
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    SizedBox.square(
      dimension: 38,
      child: Obx(
        () {
          final ctr = videoDetailController.plPlayerController;
          final enableShowDanmaku = ctr.enableShowDanmaku.value;
          return IconButton(
            onPressed: () {
              final newVal = !enableShowDanmaku;
              ctr.enableShowDanmaku.value = newVal;
              if (!ctr.tempPlayerConf) {
                GStorage.setting.put(
                  SettingBoxKey.enableShowDanmaku,
                  newVal,
                );
              }
            },
            icon: Icon(
              size: 22,
              enableShowDanmaku ? CustomIcons.dm_on : CustomIcons.dm_off,
              color: enableShowDanmaku
                  ? colorScheme.secondary
                  : colorScheme.outline,
            ),
          );
        },
      ),
    ),
  ];

  @override
  List<Widget> playerOverlays(WatchLayoutContext ctx) {
    final isFullScreen = ctx.isFullScreen;
    return [
      if (videoDetailController.plPlayerController.enableBlock ||
          videoDetailController.continuePlayingPart)
        KeyedSubtree(
          key: const ValueKey(SelfTestProbe.slotPartList),
          child: Positioned(
            left: 16,
            bottom: isFullScreen ? max(75, maxHeight * 0.25) : 75,
            width: MediaQuery.textScalerOf(context).scale(120),
            child: AnimatedList(
              padding: EdgeInsets.zero,
              key: videoDetailController.listKey,
              reverse: true,
              shrinkWrap: true,
              initialItemCount: videoDetailController.listData.length,
              itemBuilder: (context, index, animation) {
                return videoDetailController.buildItem(
                  videoDetailController.listData[index],
                  animation,
                );
              },
            ),
          ),
        ),

      // for debug
      // Positioned(
      //   right: 16,
      //   bottom: 75,
      //   child: FilledButton.tonal(
      //     onPressed: () {
      //       videoDetailController.onAddItem(
      //         SegmentModel(
      //           UUID: '',
      //           segmentType:
      //               SegmentType.values[Utils.random.nextInt(
      //                 SegmentType.values.length,
      //               )],
      //           segment: Pair(first: 0, second: 0),
      //           skipType: SkipType.alwaysSkip,
      //         ),
      //       );
      //     },
      //     child: const Text('skip'),
      //   ),
      // ),
      // Positioned(
      //   right: 16,
      //   bottom: 120,
      //   child: FilledButton.tonal(
      //     onPressed: () {
      //       videoDetailController.onAddItem(2);
      //     },
      //     child: const Text('index'),
      //   ),
      // ),
      KeyedSubtree(
        key: const ValueKey(SelfTestProbe.slotChoices),
        child: Obx(
          () {
            if (videoDetailController.showSteinEdgeInfo.value) {
              try {
                return Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      bottom: plPlayerController?.showControls.value == true
                          ? 75
                          : 16,
                    ),
                    child: Wrap(
                      spacing: 25,
                      runSpacing: 10,
                      children: videoDetailController
                          .steinEdgeInfo!
                          .edges!
                          .questions!
                          .first
                          .choices!
                          .map((item) {
                            return FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                shape: const RoundedRectangleBorder(
                                  borderRadius: .all(.circular(6)),
                                ),
                                backgroundColor: theme
                                    .colorScheme
                                    .secondaryContainer
                                    .withValues(alpha: 0.8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 15,
                                  vertical: 10,
                                ),
                                visualDensity: VisualDensity.compact,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                ugcIntroController.onChangeEpisode(
                                  item,
                                  isStein: true,
                                );
                                videoDetailController.getSteinEdgeInfo(
                                  item.id,
                                );
                              },
                              child: Text(item.option!),
                            );
                          })
                          .toList(),
                    ),
                  ),
                );
              } catch (e) {
                if (kDebugMode) debugPrint('build stein edges: $e');
                return const SizedBox.shrink();
              }
            }
            return const SizedBox.shrink();
          },
        ),
      ),
    ];
  }

  @override
  Widget intro(WatchLayoutContext ctx, {required bool withRelated}) =>
      videoIntro(
        width: ctx.slotWidth,
        height: ctx.slotHeight,
        isHorizontal: ctx.isHorizontal,
        needRelated: withRelated,
        needCtr: ctx.attachIntroController,
        isPortrait: ctx.isPortrait,
      );

  @override
  Widget related(WatchLayoutContext ctx) => KeepAliveWrapper(
    child: CustomScrollView(
      key: const PageStorageKey(CommonIntroController),
      controller: videoDetailController.shell.effectiveIntroScrollCtr,
      slivers: [
        RelatedVideoPanel(
          key: videoRelatedKey,
          heroTag: heroTag,
        ),
      ],
    ),
  );

  @override
  Widget comments(WatchLayoutContext ctx) =>
      videoReplyPanel(isNested: ctx.nested);

  @override
  Widget Function()? get commentsLabel =>
      videoDetailController.isFileSource ? null : _commentsLabel;

  Widget _commentsLabel() => Obx(() {
    final count = _videoReplyController.count.value;
    return Tab(
      child: Text(
        '评论${count == -1 ? '' : ' ${NumUtils.numFormat(count)}'}',
        softWrap: false,
        overflow: .visible,
      ),
    );
  });

  @override
  Widget playlist(WatchLayoutContext ctx) => seasonPanel;

  @override
  void onReselect(TabRole role) {
    if (videoDetailController.isFileSource ||
        role == TabRole.intro ||
        role == TabRole.related) {
      videoDetailController.shell.introScrollCtr?.animToTop();
    } else if (role == TabRole.comments) {
      _videoReplyController.animateToTop();
    }
  }

  Widget localIntroPanel({
    bool needCtr = true,
  }) {
    return CustomScrollView(
      controller: needCtr
          ? videoDetailController.shell.effectiveIntroScrollCtr
          : null,
      physics: !needCtr ? platformAlwaysClampingPhysics : null,
      key: const PageStorageKey(CommonIntroController),
      slivers: [
        // LibrePili: the intro saved with the download, as the online page
        Obx(() {
          final intro = localIntroController.intro.value;
          if (intro == null) return const SliverToBoxAdapter();
          return SliverMainAxisGroup(
            slivers: [
              LocalIntroHeader(
                key: ValueKey(intro),
                intro: intro,
                heroTag: heroTag,
              ),
              SliverToBoxAdapter(
                child: Divider(
                  height: 1,
                  indent: 12,
                  endIndent: 12,
                  color: colorScheme.outline.withValues(alpha: .08),
                ),
              ),
            ],
          );
        }),
        SliverPadding(
          padding: EdgeInsets.only(top: 7, bottom: padding.bottom + 100),
          sliver: LocalIntroPanel(
            key: videoRelatedKey,
            heroTag: heroTag,
          ),
        ),
      ],
    );
  }

  Widget videoIntro({
    double? width,
    double? height,
    bool? isHorizontal,
    bool needRelated = true,
    bool needCtr = true,
    required bool isPortrait,
  }) {
    if (videoDetailController.isFileSource) {
      return localIntroPanel(needCtr: needCtr);
    }

    Widget child = CustomScrollView(
      key: const PageStorageKey(CommonIntroController),
      controller: needCtr
          ? videoDetailController.shell.effectiveIntroScrollCtr
          : null,
      physics: !needCtr ? platformAlwaysClampingPhysics : null,
      slivers: [
        if (videoDetailController.isUgc) ...[
          UgcIntroPanel(
            key: videoIntroKey,
            heroTag: heroTag,
            showAiBottomSheet: showAiBottomSheet,
            showEpisodes: showEpisodes,
            onShowMemberPage: onShowMemberPage,
            isPortrait: isPortrait,
            isHorizontal: isHorizontal ?? width! / height! >= kScreenRatio,
          ),
          if (needRelated && videoDetailController.showRelatedVideo) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(
                  top: Style.safeSpace,
                ),
                child: Divider(
                  height: 1,
                  indent: 12,
                  endIndent: 12,
                  color: colorScheme.outline.withValues(alpha: .08),
                ),
              ),
            ),
            RelatedVideoPanel(key: videoRelatedKey, heroTag: heroTag),
          ],
        ] else
          PgcIntroPage(
            key: videoIntroKey,
            heroTag: heroTag,
            cid: videoDetailController.cid.value,
            showEpisodes: showEpisodes,
            showIntroDetail: showIntroDetail,
            maxWidth: width ?? maxWidth,
            isLandscape: !isPortrait,
          ),
        SliverToBoxAdapter(
          child: SizedBox(
            height:
                (videoDetailController.isPlayAll && !isPortrait
                    ? 80
                    : Style.safeSpace) +
                padding.bottom,
          ),
        ),
      ],
    );

    if (videoDetailController.isPlayAll) {
      child = IntroLayout(
        body: child,
        playlist: Padding(
          padding: .only(left: 12, right: 12, bottom: 12 + padding.bottom),
          child: Material(
            type: .transparency,
            child: InkWell(
              onTap: () => videoDetailController.showMediaListPanel(context),
              borderRadius: const .all(.circular(14)),
              child: Container(
                height: 54,
                padding: const .symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer.withValues(alpha: 0.95),
                  borderRadius: const .all(.circular(14)),
                ),
                child: Row(
                  spacing: 10,
                  children: [
                    const Icon(Icons.playlist_play, size: 24),
                    Expanded(
                      child: Text(
                        videoDetailController.watchLaterTitle,
                        style: TextStyle(
                          color: colorScheme.onSecondaryContainer,
                          fontWeight: .bold,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    const Icon(Icons.keyboard_arrow_up_rounded, size: 26),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return KeepAliveWrapper(child: child);
  }

  Widget get seasonPanel {
    final videoDetail = ugcIntroController.videoDetail.value;
    return KeepAliveWrapper(
      child: Column(
        children: [
          if ((videoDetail.pages?.length ?? 0) > 1)
            if (videoDetail.ugcSeason != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: PagesPanel(
                  heroTag: heroTag,
                  ugcIntroController: ugcIntroController,
                  bvid: ugcIntroController.bvid,
                  showEpisodes: showEpisodes,
                ),
              )
            else
              Expanded(
                child: Obx(
                  () => EpisodePanel(
                    heroTag: heroTag,
                    enableSlide: false,
                    ugcIntroController: videoDetailController.isUgc
                        ? ugcIntroController
                        : null,
                    type: EpisodeType.part,
                    list: [videoDetail.pages!],
                    cover: videoDetailController.cover.value,
                    bvid: videoDetailController.bvid,
                    aid: videoDetailController.aid,
                    cid: videoDetailController.cid.value,
                    isReversed: videoDetail.isPageReversed,
                    onChangeEpisode: videoDetailController.isUgc
                        ? ugcIntroController.onChangeEpisode
                        : pgcIntroController.onChangeEpisode,
                    showTitle: false,
                    isSupportReverse: videoDetailController.isUgc,
                    onReverse: () => onReversePlay(isSeason: false),
                  ),
                ),
              ),
          if (videoDetail.ugcSeason != null) ...[
            if ((videoDetail.pages?.length ?? 0) > 1) ...[
              const SizedBox(height: 8),
              Divider(
                height: 1,
                color: colorScheme.outline.withValues(alpha: 0.1),
              ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Obx(
                () => SeasonPanel(
                  key: ValueKey(introController.videoDetail.value),
                  heroTag: heroTag,
                  canTap: false,
                  showEpisodes: showEpisodes,
                  ugcIntroController: ugcIntroController,
                ),
              ),
            ),
            Expanded(
              child: Obx(
                () => EpisodePanel(
                  heroTag: heroTag,
                  enableSlide: false,
                  ugcIntroController: videoDetailController.isUgc
                      ? ugcIntroController
                      : null,
                  type: EpisodeType.season,
                  initialTabIndex: videoDetailController.seasonIndex.value,
                  cover: videoDetailController.cover.value,
                  seasonId: videoDetail.ugcSeason!.id,
                  list: videoDetail.ugcSeason!.sections!,
                  bvid: videoDetailController.bvid,
                  aid: videoDetailController.aid,
                  cid: videoDetailController.seasonCid ?? 0,
                  isReversed: ugcIntroController
                      .videoDetail
                      .value
                      .ugcSeason!
                      .sections![videoDetailController.seasonIndex.value]
                      .isReversed,
                  onChangeEpisode: videoDetailController.isUgc
                      ? ugcIntroController.onChangeEpisode
                      : pgcIntroController.onChangeEpisode,
                  showTitle: false,
                  isSupportReverse: videoDetailController.isUgc,
                  onReverse: () => onReversePlay(isSeason: true),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget videoReplyPanel({bool isNested = false}) =>
      videoDetailController.isFileSource
      ? switch (videoDetailController.localCommentsPath) {
          // keyed: reload when the offline playlist switches videos
          final path? => LocalReplyPanel(
            key: ValueKey(path),
            path: path,
            heroTag: heroTag,
          ),
          null => const SizedBox.shrink(),
        }
      : VideoReplyPanel(
          key: videoReplyPanelKey,
          isNested: isNested,
          heroTag: heroTag,
        );

  // ai总结
  void showAiBottomSheet() {
    videoDetailController.shell.showSheet(
      context,
      (context, {required inPage}) =>
          AiConclusionPanel(item: ugcIntroController.aiConclusionResult!),
      policy: SheetPolicy.alwaysInPage,
    );
  }

  void showIntroDetail(
    PgcInfoModel videoDetail,
    List<VideoTagItem>? videoTags,
  ) {
    videoDetailController.shell.showSheet(
      context,
      (context, {required inPage}) => PgcIntroPanel(
        item: videoDetail,
        videoTags: videoTags,
      ),
      policy: SheetPolicy.alwaysInPage,
    );
  }

  void showEpisodes([
    int? index,
    UgcSeason? season,
    List<ugc.BaseEpisodeItem>? episodes,
    String? bvid,
    int? aid,
    int? cid,
  ]) {
    assert((cid == null) == (bvid == null));
    if (cid == null) {
      videoDetailController.showMediaListPanel(context);
      return;
    }
    Widget listSheetContent({bool enableSlide = true}) => EpisodePanel(
      heroTag: heroTag,
      ugcIntroController: videoDetailController.isUgc
          ? ugcIntroController
          : null,
      type: season != null
          ? EpisodeType.season
          : episodes is List<Part>
          ? EpisodeType.part
          : EpisodeType.pgc,
      cover: videoDetailController.cover.value,
      enableSlide: enableSlide,
      initialTabIndex: index ?? 0,
      bvid: bvid!,
      aid: aid,
      cid: cid,
      seasonId: season?.id,
      list: season != null ? season.sections! : [episodes],
      isReversed: !videoDetailController.isUgc
          ? null
          : season != null
          ? ugcIntroController
                .videoDetail
                .value
                .ugcSeason!
                .sections![videoDetailController.seasonIndex.value]
                .isReversed
          : ugcIntroController.videoDetail.value.isPageReversed,
      isSupportReverse: videoDetailController.isUgc,
      onChangeEpisode: videoDetailController.isUgc
          ? ugcIntroController.onChangeEpisode
          : pgcIntroController.onChangeEpisode,
      onClose: Get.back,
      onReverse: () {
        Get.back();
        onReversePlay(isSeason: season != null);
      },
    );
    videoDetailController.shell.showSheet(
      context,
      (context, {required inPage}) => listSheetContent(enableSlide: inPage),
      theme: theme,
    );
  }

  void onReversePlay({required bool isSeason}) {
    if (isSeason && videoDetailController.isPlayAll) {
      SmartDialog.showToast('当前为播放全部，合集不支持倒序');
      return;
    }

    final videoDetail = ugcIntroController.videoDetail.value;
    if (isSeason) {
      // reverse season
      final item = videoDetail
          .ugcSeason!
          .sections![videoDetailController.seasonIndex.value];
      item
        ..isReversed = !item.isReversed
        ..episodes = item.episodes!.reversed.toList();

      if (!videoDetailController.plPlayerController.reverseFromFirst) {
        // keep current episode
        videoDetailController
          ..seasonIndex.refresh()
          ..cid.refresh();
      } else {
        // switch to first episode
        final episode = ugcIntroController
            .videoDetail
            .value
            .ugcSeason!
            .sections![videoDetailController.seasonIndex.value]
            .episodes!
            .first;
        if (episode.cid != videoDetailController.cid.value) {
          ugcIntroController.onChangeEpisode(episode);
          videoDetailController.seasonCid = episode.cid;
        } else {
          videoDetailController
            ..seasonIndex.refresh()
            ..cid.refresh();
        }
      }
    } else {
      // reverse part
      videoDetail
        ..isPageReversed = !videoDetail.isPageReversed
        ..pages = videoDetail.pages!.reversed.toList();
      if (!videoDetailController.plPlayerController.reverseFromFirst) {
        // keep current episode
        videoDetailController.cid.refresh();
      } else {
        // switch to first episode
        final episode = videoDetail.pages!.first;
        if (episode.cid != videoDetailController.cid.value) {
          ugcIntroController.onChangeEpisode(episode);
        } else {
          videoDetailController.cid.refresh();
        }
      }
    }
  }

  void showViewPoints() {
    videoDetailController.shell.showSheet(
      context,
      (context, {required inPage}) => ViewPointsPage(
        enableSlide: inPage,
        videoDetailController: videoDetailController,
        plPlayerController: plPlayerController,
      ),
      theme: theme,
    );
  }

  void onShowMemberPage(int? mid) {
    videoDetailController.shell.showSheet(
      context,
      (context, {required inPage}) {
        return HorizontalMemberPage(
          mid: mid,
          videoDetailController: videoDetailController,
          ugcIntroController: ugcIntroController,
        );
      },
      policy: SheetPolicy.alwaysInPage,
    );
  }
}
