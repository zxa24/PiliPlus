import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io' show Directory, File, HttpClient, HttpHeaders, HttpStatus;
import 'dart:math' show min;
import 'dart:ui';

import 'package:PiliPlus/common/widgets/dialog/failure_report.dart';
import 'package:PiliPlus/models/common/subtitle_source.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/pair.dart';
import 'package:PiliPlus/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:PiliPlus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pbenum.dart'
    show PlaylistSource;
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/action_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/post_segment_model.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_model.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_type.dart';
import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/media_list/media_list.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/models_new/video/video_pbp/data.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';
import 'package:PiliPlus/models_new/video/video_stein_edgeinfo/data.dart';
import 'package:PiliPlus/pages/audio/view.dart';
import 'package:PiliPlus/pages/common/publish/publish_route.dart';
import 'package:PiliPlus/pages/search/widgets/search_text.dart';
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/pages/video/download_panel/view.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/medialist/view.dart';
import 'package:PiliPlus/pages/video/note/view.dart';
import 'package:PiliPlus/pages/video/post_panel/view.dart';
import 'package:PiliPlus/pages/video/send_danmaku/view.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/local_documents.dart';
import 'package:PiliPlus/services/asr/asr_publish.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/asr/subtitle_punctuation.dart';
import 'package:PiliPlus/services/asr/model_guard.dart';
import 'package:PiliPlus/services/translate/caption_source.dart';
import 'package:PiliPlus/services/translate/translation_languages.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/services/translate/translation_track.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/local_player.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/login_policy.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/extension/nested_scroll_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/utils/cdn_probe.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart' show md5;
import 'package:dio/dio.dart' show Options;
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart'
    show ExtendedNestedScrollViewState;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' hide Subtitle;
import 'package:path/path.dart' as path;

class VideoDetailController extends GetxController
    with GetTickerProviderStateMixin, BlockMixin {
  /// 路由传参
  late final Map args;
  late String bvid;
  late int aid;
  late final RxInt cid;
  int? epId;
  int? seasonId;
  int? pgcType;
  late final String heroTag;
  late final RxString cover;

  // 视频类型 默认投稿视频
  late final VideoType videoType;
  @override
  late final isUgc = videoType == VideoType.ugc;
  VideoType? _actualVideoType;

  // 页面来源 稍后再看 收藏夹
  late bool isPlayAll;
  late SourceType sourceType;
  late BiliDownloadEntryInfo entry;
  late bool isFileSource;
  late bool _mediaDesc = false;
  late final RxList<MediaListItemModel> mediaList = <MediaListItemModel>[].obs;
  late String watchLaterTitle;

  /// tabs相关配置
  late TabController tabCtr;

  // 请求返回的视频信息
  late PlayUrlModel data;
  final RxBool videoState = false.obs;

  /// 播放器配置 画质 音质 解码格式
  final Rxn<VideoQuality> currentVideoQa = Rxn<VideoQuality>();
  AudioQuality? currentAudioQa;
  late VideoDecodeFormatType currentDecodeFormats;

  // 是否开始自动播放 存在多p的情况下，第二p需要为true
  final RxBool _autoPlay = Pref.autoPlayEnable.obs;

  final videoPlayerKey = GlobalKey();
  final childKey = GlobalKey<MiniScaffoldState>();

  final plPlayerController = PlPlayerController.getInstance()
    ..brightness.value = -1;
  bool get setSystemBrightness => plPlayerController.setSystemBrightness;
  bool get removeSafeArea => plPlayerController.removeSafeArea;
  double get uiScale => plPlayerController.uiScale;

  late VideoItem firstVideo;
  String? videoUrl;
  String? audioUrl;
  Duration? defaultST;
  Duration? playedTime;
  String playedTimePos(bool hasParams) {
    final pos = playedTime?.inMilliseconds;
    if (pos != null && pos > 0) {
      return '${hasParams ? '&' : '?'}t=${pos / 1000}';
    }
    return '';
  }

  // 亮度
  double? brightness;

  late final headerCtrKey = GlobalKey<TimeBatteryMixin>();

  Box setting = GStorage.setting;

  // 预设的解码格式
  late List<VideoDecodeFormatType> preferCodecs = Pref.preferCodecs;

  /// LibrePili: comments saved with a download, if any.
  String? localCommentsPath;

  bool get showReply => isFileSource
      ? localCommentsPath != null
      : isUgc
      ? plPlayerController.showVideoReply
      : plPlayerController.showBangumiReply;

  bool get showRelatedVideo =>
      isFileSource ? false : plPlayerController.showRelatedVideo;

  ScrollController? introScrollCtr;
  ScrollController get effectiveIntroScrollCtr =>
      introScrollCtr ??= ScrollController();

  int? seasonCid;
  late final RxInt seasonIndex = 0.obs;

  PlayerStatus? playerStatus;

  late final scrollKey = GlobalKey<ExtendedNestedScrollViewState>();
  late final RxBool isVertical;
  late final RxDouble scrollRatio = 0.0.obs;

  ScrollController? _scrollCtr;
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
        vsync: this,
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

  bool _needAnimOnDimensionChanged(bool isVertical) {
    if (isFullScreen) {
      if (PlatformUtils.isMobile) {
        plPlayerController.changeOrientation(isVertical: isVertical);
      }
      return false;
    }
    return true;
  }

  @pragma('vm:notify-debugger-on-exception')
  void _setVideoHeight() {
    try {
      var width = firstVideo.width;
      var height = firstVideo.height;
      if (width == null || height == null) {
        if (isUgc && !isFileSource) {
          final ugcIntroCtr = Get.find<UgcIntroController>(tag: heroTag);
          final cid = this.cid.value;
          final part = ugcIntroCtr.videoDetail.value.pages?.firstWhereOrNull(
            (e) => e.cid == cid,
          );
          if (part != null) {
            final dimension = part.dimension!;
            width = dimension.width!;
            height = dimension.height!;
          } else {
            return;
          }
        } else {
          return;
        }
      }
      final isVertical = height > width;
      if (_scrollCtr?.hasClients != true) {
        videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        if (this.isVertical.value != isVertical) {
          this.isVertical.value = isVertical;
          _needAnimOnDimensionChanged(isVertical);
        }
        return;
      }
      if (this.isVertical.value != isVertical) {
        this.isVertical.value = isVertical;
        double videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        if (this.videoHeight != videoHeight) {
          if (videoHeight > this.videoHeight) {
            // current minVideoHeight
            if (_needAnimOnDimensionChanged(isVertical)) {
              isExpanding = true;
              animationController.forward(
                from: (minVideoHeight - scrollCtr.offset) / maxVideoHeight,
              );
            }
            this.videoHeight = maxVideoHeight;
          } else {
            // current maxVideoHeight
            final currentHeight = (maxVideoHeight - scrollCtr.offset)
                .toPrecision(2);
            double minVideoHeightPrecise = minVideoHeight.toPrecision(2);
            if (currentHeight == minVideoHeightPrecise) {
              this.videoHeight = minVideoHeight;
              if (_needAnimOnDimensionChanged(isVertical)) {
                isExpanding = true;
                animationController.forward(from: 1);
              }
            } else if (currentHeight < minVideoHeightPrecise) {
              // expand
              if (_needAnimOnDimensionChanged(isVertical)) {
                isExpanding = true;
                animationController.forward(
                  from: currentHeight / minVideoHeight,
                );
              }
              this.videoHeight = minVideoHeight;
            } else {
              // collapse
              if (_needAnimOnDimensionChanged(isVertical)) {
                isCollapsing = true;
                animationController.forward(
                  from: scrollCtr.offset / (maxVideoHeight - minVideoHeight),
                );
              }
              this.videoHeight = minVideoHeight;
            }
          }
        }
      } else {
        if (scrollCtr.offset != 0) {
          isExpanding = true;
          animationController.forward(from: 1 - scrollCtr.offset / videoHeight);
        }
      }
    } catch (_) {}
  }

  final isLoginVideo = Accounts.get(AccountType.video).isLogin;

  late final watchProgress = GStorage.watchProgress;

  /// Plain local files all have cid 0: key their progress by path instead
  /// (hashed: Hive keys are ASCII, at most 255 chars).
  String get _progressKey {
    if (cid.value == 0) {
      // Android documents: the cache folder path is not stable, the
      // document is
      if (entry.playKey ?? entry.playUri case final doc?) {
        return 'u${md5.convert(utf8.encode(doc))}';
      }
      if (entry.mergedPath case final file?) {
        return 'f${md5.convert(utf8.encode(file))}';
      }
    }
    return cid.value.toString();
  }

  int _lastLocalSaveSec = 0;

  /// While playing: save the local resume point every 5 s, so it survives
  /// the process being killed.
  void onLocalPosition(Duration position) {
    if (!isFileSource || !plPlayerController.playerStatus.isPlaying) return;
    final sec = position.inSeconds;
    // 0: not yet at the resume point of a newly opened item
    if (sec > 0 && (sec - _lastLocalSaveSec).abs() >= 5) {
      _lastLocalSaveSec = sec;
      cacheLocalProgress();
    }
  }

  void cacheLocalProgress() {
    if (plPlayerController.playerStatus.isCompleted) {
      watchProgress.put(_progressKey, entry.totalTimeMilli);
    } else if (playedTime case final playedTime?) {
      watchProgress.put(_progressKey, playedTime.inMilliseconds);
    }
  }

  /// Side-file cache folder of the Android document this page was opened
  /// with: [entry] can later be replaced by a playlist item that has none,
  /// so the folder to release is kept here.
  String? _localMirror;

  void initFileSource(BiliDownloadEntryInfo entry, {bool isInit = true}) {
    this.entry = entry;
    if (entry.playUri != null && entry.entryDirPath != _localMirror) {
      // the page moved to another document: the folder it showed until now
      // is released here, or its count never reaches zero and the copied
      // side files stay in the temp dir for the rest of the session
      LocalPlayer.release(_localMirror);
      _localMirror = entry.entryDirPath;
      LocalPlayer.retain(_localMirror);
    }
    localCommentsPath = null;
    if (entry.mergedPath case final merged?) {
      final file = path.join(
        path.dirname(merged),
        '${path.basenameWithoutExtension(merged)}.comments.json',
      );
      if (File(file).existsSync()) localCommentsPath = file;
    }
    firstVideo = VideoItem(
      id: entry.preferedVideoQuality,
      quality: VideoQuality.fromCode(entry.preferedVideoQuality),
      width: entry.ep?.width ?? entry.pageData?.width ?? 1,
      height: entry.ep?.height ?? entry.pageData?.height ?? 1,
    );
    if (watchProgress.get(_progressKey) case final int progress?) {
      // duration unknown (plain local files): resume as is
      if (entry.totalTimeMilli > 0 && progress >= entry.totalTimeMilli - 400) {
        defaultST = Duration.zero;
      } else {
        defaultST = Duration(milliseconds: progress);
      }
    } else {
      defaultST = Duration.zero;
    }
    data = PlayUrlModel(timeLength: entry.totalTimeMilli);
    _setVideoHeight();
  }

  @override
  void onInit() {
    super.onInit();
    // the player cannot resolve another CDN itself: it has no play-url list
    plPlayerController
      ..onCdnFailover = switchToNextCdn
      ..onStreamCut = replaceCutStreams
      ..onStreamSlow = replaceSlowStreams
      ..onStreamRoomy = raiseQuality
      ..onReopen = _reopenAtCurrentPosition;
    args = Get.arguments;
    videoType = args['videoType'];
    if (videoType == VideoType.pgc) {
      if (!isLoginVideo) {
        _actualVideoType = VideoType.ugc;
      }
    } else if (args['pgcApi'] == true) {
      _actualVideoType = VideoType.pgc;
    }

    bvid = args['bvid'];
    aid = args['aid'];
    cid = RxInt(args['cid']);
    epId = args['epId'];
    seasonId = args['seasonId'];
    pgcType = args['pgcType'];
    heroTag = args['heroTag'];
    cover = RxString(args['cover'] ?? '');
    isVertical = RxBool(args['isVertical'] ?? false);

    sourceType = args['sourceType'] ?? SourceType.normal;
    isFileSource = sourceType == SourceType.file;
    isPlayAll = sourceType != SourceType.normal && !isFileSource;
    if (isFileSource) {
      initFileSource(args['entry']);
    } else if (isPlayAll) {
      watchLaterTitle = args['favTitle'];
      _mediaDesc = args['desc'];
      getMediaList();
    }

    tabCtr = TabController(
      length: 2,
      vsync: this,
      initialIndex: Pref.defaultShowComment ? 1 : 0,
    );
  }

  Future<void> getMediaList({
    bool isReverse = false,
    bool isLoadPrevious = false,
  }) async {
    final count = args['count'];
    if (!isReverse && count != null && mediaList.length >= count) {
      return;
    }
    final res = await UserHttp.getMediaList(
      type: args['mediaType'] ?? sourceType.mediaType,
      bizId: args['mediaId'] ?? -1,
      ps: 20,
      direction: isLoadPrevious ? true : false,
      oid: isReverse
          ? null
          : mediaList.isEmpty
          ? args['isContinuePlaying'] == true
                ? args['oid']
                : null
          : isLoadPrevious
          ? mediaList.first.aid
          : mediaList.last.aid,
      otype: isReverse
          ? null
          : mediaList.isEmpty
          ? null
          : isLoadPrevious
          ? mediaList.first.type
          : mediaList.last.type,
      desc: _mediaDesc,
      sortField: args['sortField'] ?? 1,
      withCurrent: mediaList.isEmpty && args['isContinuePlaying'] == true
          ? true
          : false,
    );
    if (res case Success(:final response)) {
      if (response.mediaList.isNotEmpty) {
        if (isReverse) {
          mediaList.value = response.mediaList;
          for (final item in mediaList) {
            if (item.cid != null) {
              try {
                Get.find<UgcIntroController>(
                  tag: heroTag,
                ).onChangeEpisode(item);
              } catch (_) {}
              break;
            }
          }
        } else if (isLoadPrevious) {
          mediaList.insertAll(0, response.mediaList);
        } else {
          mediaList.addAll(response.mediaList);
        }
      }
    } else {
      res.toast();
    }
  }

  void showMediaListPanel(BuildContext context) {
    if (mediaList.isNotEmpty) {
      Widget panel() => MediaListPanel(
        mediaList: mediaList,
        onChangeEpisode: (episode) {
          try {
            Get.find<UgcIntroController>(tag: heroTag).onChangeEpisode(episode);
          } catch (_) {}
        },
        panelTitle: watchLaterTitle,
        bvid: bvid,
        count: args['count'],
        loadMoreMedia: getMediaList,
        desc: _mediaDesc,
        onReverse: () {
          _mediaDesc = !_mediaDesc;
          getMediaList(isReverse: true);
        },
        loadPrevious: args['isContinuePlaying'] == true
            ? () => getMediaList(isLoadPrevious: true)
            : null,
        onDelete:
            sourceType == SourceType.watchLater ||
                (sourceType == SourceType.fav && args['isOwner'] == true)
            ? (item, index) async {
                if (sourceType == SourceType.watchLater) {
                  final res = await UserHttp.toViewDel(
                    aids: item.aid.toString(),
                  );
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                  }
                } else {
                  final res = await FavHttp.favVideo(
                    resources: '${item.aid}:${item.type}',
                    delIds: '${args['mediaId']}',
                  );
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                    SmartDialog.showToast('取消收藏');
                  } else {
                    res.toast();
                  }
                }
              }
            : null,
      );
      if (plPlayerController.isFullScreen.value || showVideoSheet) {
        PageUtils.showVideoBottomSheet(
          context,
          child: plPlayerController.darkVideoPage
              ? Theme(data: ThemeUtils.darkTheme, child: panel())
              : panel(),
        );
      } else {
        childKey.currentState?.showBottomSheet(
          constraints: const BoxConstraints(),
          (context) => panel(),
        );
      }
    } else {
      getMediaList();
    }
  }

  bool isPortrait = true;

  bool get horizontalScreen => plPlayerController.horizontalScreen;

  bool get showVideoSheet =>
      (!horizontalScreen && !isPortrait) || plPlayerController.isDesktopPip;

  @override
  late final RxString videoLabel = ''.obs;
  @override
  int? get timeLength => data.timeLength;
  @override
  BlockConfigMixin get blockConfig => plPlayerController;
  @override
  Player? get player => plPlayerController.videoPlayerController;
  @override
  bool get isFullScreen => plPlayerController.isFullScreen.value;
  @override
  bool get autoPlay => _autoPlay.value;
  set autoPlay(bool value) => _autoPlay.value = value;
  @override
  bool get preInitPlayer => plPlayerController.preInitPlayer;
  @override
  int get currPosInMilliseconds =>
      defaultST?.inMilliseconds ?? plPlayerController.positionInMilliseconds;
  @override
  Future<void> seekTo(Duration duration, {required bool isSeek}) =>
      plPlayerController.seekTo(duration, isSeek: isSeek);

  @override
  Widget buildItem(Object item, Animation<double> animation) {
    final theme = ThemeUtils.theme;
    return Align(
      alignment: Alignment.centerLeft,
      child: SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(-1.0, 0.0),
            end: Offset.zero,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: GestureDetector(
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              if (details.delta.dx < 0) {
                onRemoveItem(listData.indexOf(item), item);
              }
            },
            child: SearchText(
              bgColor: theme.colorScheme.secondaryContainer.withValues(
                alpha: 0.8,
              ),
              textColor: theme.colorScheme.onSecondaryContainer,
              padding: const .symmetric(horizontal: 8, vertical: 4),
              fontSize: 14,
              text: item is SegmentModel
                  ? '跳过: ${item.segmentType.shortTitle}'
                  : '上次看到第${(item as int) + 1}P，点击跳转',
              onTap: (_) {
                if (item is int) {
                  try {
                    UgcIntroController ugcIntroController =
                        Get.find<UgcIntroController>(tag: heroTag);
                    Part part =
                        ugcIntroController.videoDetail.value.pages![item];
                    ugcIntroController.onChangeEpisode(part);
                    SmartDialog.showToast('已跳至第${item + 1}P');
                  } catch (e) {
                    if (kDebugMode) debugPrint('$e');
                    SmartDialog.showToast('跳转失败');
                  }
                  onRemoveItem(listData.indexOf(item), item);
                } else if (item is SegmentModel) {
                  onSkip(item, isSeek: false);
                  onRemoveItem(listData.indexOf(item), item);
                }
              },
            ),
          ),
        ),
      ),
    );
  }

  ({int mode, int fontSize, Color color})? dmConfig;
  String? savedDanmaku;

  /// 发送弹幕
  Future<void> showShootDanmakuSheet() async {
    // also reached from the keyboard shortcut
    if (!LoginPolicy.canInteract || isFileSource) return;
    if (plPlayerController.dmState.contains(cid.value)) {
      SmartDialog.showToast('UP主已关闭弹幕');
      return;
    }
    final isPlaying =
        _autoPlay.value && plPlayerController.playerStatus.isPlaying;
    if (isPlaying) {
      await plPlayerController.pause();
    }
    await Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (buildContext, animation, secondaryAnimation) {
          final child = SendDanmakuPanel(
            cid: cid.value,
            bvid: bvid,
            progress: plPlayerController.positionInMilliseconds,
            initialValue: savedDanmaku,
            onSave: (danmaku) => savedDanmaku = danmaku,
            onSuccess: (danmakuModel) {
              savedDanmaku = null;
              plPlayerController.danmakuController?.addDanmaku(danmakuModel);
            },
            dmConfig: dmConfig,
            onSaveDmConfig: (dmConfig) => this.dmConfig = dmConfig,
          );
          if (plPlayerController.darkVideoPage) {
            return Theme(data: ThemeUtils.darkTheme, child: child);
          }
          return child;
        },
      ),
    );
    if (isPlaying) {
      plPlayerController.play();
    }
  }

  VideoItem findVideoByQa(int qa, {bool setCodecs = false}) {
    /// 根据currentVideoQa和currentDecodeFormats 重新设置videoUrl
    final videoList = data.dash!.video!.where((i) => i.id == qa).toList();

    final currentCodes = currentDecodeFormats.codes;
    VideoItem? bestVideo;
    int bestIndex = preferCodecs.length;
    for (final video in videoList) {
      final c = video.codecs!;
      if (currentCodes.any(c.startsWith)) {
        return video;
      }
      for (int i = 0; i < bestIndex; i++) {
        if (preferCodecs[i].codes.any(c.startsWith)) {
          bestIndex = i;
          bestVideo = video;
          break;
        }
      }
    }

    if (setCodecs) {
      if (bestIndex < preferCodecs.length) {
        currentDecodeFormats = preferCodecs[bestIndex];
      } else {
        currentDecodeFormats = VideoDecodeFormatType.fromString(
          videoList.first.codecs!,
        );
      }
    }

    return bestVideo ?? videoList.first;
  }

  /// The audio stream currently chosen, kept so a re-select can reach its
  /// list of CDN URLs.
  AudioItem? _currentAudio;

  /// Moves to the next CDN and resumes where playback was.
  ///
  /// The order matters and is deliberate: **exhaust the CDNs before touching
  /// the quality**. A stall usually means one host will not serve, not that
  /// the connection is too slow, and dropping to 480p for a dead CDN would
  /// degrade the picture without fixing anything. Automatic quality switching
  /// (see TODO) is the *second* step and must run only once this returns
  /// false.
  ///
  /// Returns false when there is nothing left to try.
  bool switchToNextCdn() {
    if (isFileSource) return false;
    if (_hostOf(videoUrl) case final current?) _triedHosts.add(current);
    // the fastest measured first (see [_hostSpeeds]); those never measured
    // after them, in Bilibili's order
    final left = _byMeasuredSpeed([
      for (final url in VideoUtils.cdnCandidates(firstVideo.playUrls))
        if (!_triedHosts.contains(_hostOf(url))) url,
    ]);
    if (left.isEmpty) return false;

    videoUrl = left.first;
    if (_currentAudio case final audio?) {
      audioUrl = _onHost(audio.playUrls, _hostOf(left.first)) ?? audioUrl;
    }
    EventLog.add('player', 'cdn failover -> ${Uri.tryParse(videoUrl!)?.host}');
    // silent: the viewer is told only when no host is left (the player's
    // own toast when this returns false)
    _reopenAtCurrentPosition();
    return true;
  }

  /// Streams from another CDN for those of the current source that stop at
  /// byte [cutAt] (see [PlPlayerController.onStreamCut]): each current URL
  /// is asked for the byte there, and a cut one is replaced by the first
  /// other host that has it. [videoUrl] and [audioUrl] follow, so a later
  /// reopen does not go back to the broken copy.
  Future<({String? video, String? audio})?> replaceCutStreams(
    int cutAt,
  ) async {
    final video = videoUrl;
    final audio = audioUrl;
    if (isFileSource || video == null) return null;
    final (videoOk, audioOk) = await (
      servesAt(video, cutAt),
      audio == null ? Future.value(true) : servesAt(audio, cutAt),
    ).wait;
    // both answer: not a broken copy, and a reopen is the safe way on
    if (videoOk && audioOk) return null;
    // the fastest other host that has the byte: measured from it, which
    // is also the check that it is there (a copy cut before it drops the
    // connection)
    Future<String?> another(Iterable<String> urls, String current) async {
      final host = _hostOf(current);
      final others = [
        for (final url in VideoUtils.cdnCandidates(urls))
          if (_hostOf(url) != host) url,
      ];
      final speeds = await _measure(others, offset: cutAt);
      final best = CdnProbe.pick(speeds);
      return best == null
          ? null
          : others.firstWhere((url) => _hostOf(url) == best);
    }

    final newVideo = videoOk ? null : await another(firstVideo.playUrls, video);
    final newAudio = audioOk || _currentAudio == null
        ? null
        : await another(_currentAudio!.playUrls, audio!);
    if ((!videoOk && newVideo == null) || (!audioOk && newAudio == null)) {
      return null;
    }
    if (videoUrl != video || audioUrl != audio) return null;
    if (newVideo != null) {
      if (_hostOf(video) case final cut?) _triedHosts.add(cut);
      videoUrl = newVideo;
    }
    if (newAudio != null) audioUrl = newAudio;
    return (video: newVideo, audio: newAudio);
  }

  /// Hosts given up on for this part.
  final _triedHosts = <String>{};

  /// Bytes per second each host was last measured at, for this part (null
  /// for one that did not deliver).
  final _hostSpeeds = <String, double?>{};

  static String? _hostOf(String? url) =>
      url == null ? null : Uri.tryParse(url)?.host;

  /// The URL among [urls] on [host], if any.
  static String? _onHost(Iterable<String> urls, String? host) {
    for (final url in urls) {
      if (_hostOf(url) == host) return url;
    }
    return null;
  }

  /// [urls] with the fastest measured host first; the order is kept among
  /// hosts measured alike, and those never measured come last.
  List<String> _byMeasuredSpeed(List<String> urls) {
    double rank(String url) => _hostSpeeds[_hostOf(url)] ?? -1;
    final indexed = [for (final (i, url) in urls.indexed) (i, url)]
      ..sort((a, b) {
        final byspeed = rank(b.$2).compareTo(rank(a.$2));
        return byspeed != 0 ? byspeed : a.$1.compareTo(b.$1);
      });
    return [for (final (_, url) in indexed) url];
  }

  /// Measures [urls] at once (see [CdnProbe.speed]), keeping the results in
  /// [_hostSpeeds]. By host.
  Future<Map<String, double?>> _measure(
    List<String> urls, {
    int offset = 0,
    int length = 384 << 10,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final speeds = await Future.wait([
      for (final url in urls)
        CdnProbe.speed(
          url,
          offset: offset,
          length: length,
          timeout: timeout,
        ),
    ]);
    final byHost = <String, double?>{};
    for (final (i, url) in urls.indexed) {
      if (_hostOf(url) case final host?) byHost[host] = speeds[i];
    }
    _hostSpeeds.addAll(byHost);
    EventLog.add(
      'player',
      'cdn speeds: ${byHost.entries.map((e) => '${e.key} ${e.value == null ? '-' : '${(e.value! * 8 / 1e6).toStringAsFixed(1)} Mbps'}').join(', ')}',
    );
    return byHost;
  }

  /// The bitrate the current streams need together, bits per second.
  int? get _streamBitrate {
    final video = firstVideo.bandWidth;
    if (video == null) return null;
    return video + (_currentAudio?.bandWidth ?? 0);
  }

  /// Picks the fastest host for the streams about to be played, before the
  /// player opens them. Only when the host is left to Bilibili's list (the
  /// default 备用URL): a host chosen in the settings is the viewer's.
  /// Bounded so a slow answer cannot hold the video up for long.
  Future<void> _pickFastestHost() async {
    if (isFileSource || VideoUtils.cdnService != CDNService.backupUrl) return;
    // the self-test's broken copy is to be played, not measured away
    if (VideoUtils.debugWrapVideoUrl != null) return;
    final video = videoUrl;
    if (video == null) return;
    final candidates = VideoUtils.cdnCandidates(firstVideo.playUrls);
    if (candidates.length < 2) return;
    final part = cid.value;
    final speeds = await _measure(
      candidates.take(4).toList(),
      timeout: const Duration(milliseconds: 1500),
    );
    if (isClosed || cid.value != part || videoUrl != video) return;
    final best = CdnProbe.pick(speeds, current: _hostOf(video));
    if (best == null || best == _hostOf(video)) return;
    videoUrl = _onHost(candidates, best) ?? video;
    if (_currentAudio case final audio?) {
      audioUrl = _onHost(audio.playUrls, best) ?? audioUrl;
    }
  }

  /// Streams from a faster host, when playback is not keeping up (see
  /// [PlPlayerController.onStreamSlow]): every host of the current video is
  /// measured, and one clearly faster than the current and fast enough for
  /// the stream is moved to. Null when there is none — then only a lower
  /// quality would help.
  Future<({String? video, String? audio})?> replaceSlowStreams() async {
    final video = videoUrl;
    if (isFileSource || video == null) return null;
    final candidates = VideoUtils.cdnCandidates(firstVideo.playUrls);
    // long enough to be compared with the bitrate
    final speeds = await _measure(
      candidates.take(4).toList(),
      length: 1 << 20,
      timeout: const Duration(seconds: 4),
    );
    if (videoUrl != video) return null;
    // another host, where the host is left to Bilibili's list: a host chosen
    // in the settings is the viewer's
    if (VideoUtils.cdnService == CDNService.backupUrl && !debugNoHostSwitch) {
      final current = _hostOf(video);
      final best = CdnProbe.pick(speeds, current: current, keepRatio: 1 / 1.3);
      if (best != null &&
          best != current &&
          CdnProbe.keepsUp(speeds[best], _streamBitrate)) {
        final newVideo = _onHost(candidates, best);
        if (newVideo != null) {
          videoUrl = newVideo;
          return (video: newVideo, audio: null);
        }
      }
    }
    // no host keeps up: a lower quality does
    return _stepQuality(down: true, speeds: speeds);
  }

  /// There has been room to spare for a while (see
  /// [PlPlayerController.onStreamRoomy]): one quality up, on the same host,
  /// if what the network has delivered while playing keeps up with it with
  /// room to spare (see [PlPlayerController.observedBytesPerSecond]) and it
  /// is not above the quality the video opened at. Not on a probe: 1 MB
  /// said a host was fast enough for 1080P, and it was not.
  Future<({String? video, String? audio})?> raiseQuality() async {
    final video = videoUrl;
    if (isFileSource || video == null || _qualityChosen) return null;
    final delivered = plPlayerController.observedBytesPerSecond;
    final host = _hostOf(video);
    if (delivered == null || host == null) return null;
    return _stepQuality(down: false, speeds: {host: delivered});
  }

  /// For the self-test (`--no-host-switch`): as if no other host were
  /// faster, so that the quality is what changes. Nothing else sets it.
  static bool debugNoHostSwitch = false;

  /// The viewer picked a quality: nothing changes it by itself for this
  /// part.
  var _qualityChosen = false;

  /// The quality the part opened at: stepping back up stops there.
  int? _qualityCeiling;

  void userChoseQuality() => _qualityChosen = true;

  /// One quality down or up, in the codec being played, from the fastest
  /// host measured in [speeds] (bytes per second by host). Going up needs
  /// that host at 1.5x the higher stream's bitrate.
  ({String? video, String? audio})? _stepQuality({
    required bool down,
    required Map<String, double?> speeds,
  }) {
    if (_qualityChosen || isFileSource) return null;
    final videos = data.dash?.video;
    if (videos == null || videos.isEmpty) return null;
    // best first
    final codes = {for (final v in videos) v.id}.toList()
      ..sort((a, b) => b.compareTo(a));
    final at = codes.indexOf(currentVideoQa.value?.code ?? -1);
    if (at == -1) return null;
    final next = down ? at + 1 : at - 1;
    if (next < 0 || next >= codes.length) return null;
    if (!down) {
      final ceiling = codes.indexOf(_qualityCeiling ?? codes.first);
      if (ceiling != -1 && next < ceiling) return null;
    }
    final item = findVideoByQa(codes[next]);
    final best = CdnProbe.pick(speeds);
    if (!down) {
      final bitrate = (item.bandWidth ?? 0) + (_currentAudio?.bandWidth ?? 0);
      if (!CdnProbe.keepsUp(speeds[best], bitrate, margin: 1.5)) return null;
    }
    final candidates = VideoUtils.cdnCandidates(item.playUrls);
    final url =
        _onHost(candidates, best) ?? VideoUtils.getCdnUrl(item.playUrls);
    firstVideo = item;
    _setVideoHeight();
    videoUrl = url;
    final quality = VideoQuality.fromCode(codes[next]);
    currentVideoQa.value = quality;
    plPlayerController.streamBitrate = _streamBitrate;
    // not announced: the network is what it is, and this is the app
    // working around it
    EventLog.add(
      'player',
      'quality ${down ? 'down' : 'up'} to ${quality.desc}',
    );
    return (video: url, audio: null);
  }

  /// Whether [url] hands over the byte at [offset], asked as the player asks
  /// (its user agent and referer, no cookies). A copy cut short before it
  /// drops the connection; one shorter than [offset] answers 416, which is
  /// not a cut of this stream.
  static Future<bool> servesAt(String url, int offset) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..userAgent = BrowserUa.pc;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers
        ..set(HttpHeaders.refererHeader, HttpString.baseUrl)
        ..set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + 1}');
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await response.drain<void>();
        return true;
      }
      var length = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 4))) {
        length += chunk.length;
      }
      return response.statusCode == HttpStatus.partialContent && length > 0;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Re-opens the player with whatever [videoUrl] / [audioUrl] now hold,
  /// continuing from the current position. Shared by the CDN failover and by
  /// quality changes so both keep the same resume behaviour.
  void _reopenAtCurrentPosition() {
    _autoPlay.value = true;
    playedTime = plPlayerController.resumePosition;
    plPlayerController
      ..isBuffering.value = false
      ..buffered.value = 0;
    playerInit();
  }

  /// 更新画质、音质
  void updatePlayer() {
    final currentVideoQa = this.currentVideoQa.value;
    if (currentVideoQa == null) return;
    _autoPlay.value = true;
    playedTime = plPlayerController.videoPlayerController?.state.position;
    plPlayerController
      ..isBuffering.value = false
      ..buffered.value = 0;

    firstVideo = findVideoByQa(currentVideoQa.code, setCodecs: true);
    videoUrl = VideoUtils.getCdnUrl(firstVideo.playUrls);

    /// 根据currentAudioQa 重新设置audioUrl
    if (currentAudioQa != null) {
      final firstAudio = data.dash!.audio!.firstWhere(
        (i) => i.id == currentAudioQa!.code,
        orElse: () => data.dash!.audio!.first,
      );
      _currentAudio = firstAudio;
      audioUrl = VideoUtils.getCdnUrl(firstAudio.playUrls, isAudio: true);
    }

    playerInit();
  }

  Future<void>? _initPlayerIfNeeded(bool autoFullScreenFlag) {
    if (_autoPlay.value ||
        (plPlayerController.preInitPlayer && !plPlayerController.processing) &&
            (isFileSource
                ? true
                : videoPlayerKey.currentState?.mounted == true)) {
      return playerInit(
        autoFullScreenFlag: autoFullScreenFlag && _autoPlay.value,
      );
    }
    return null;
  }

  Future<void> playerInit({
    bool? autoplay,
    bool autoFullScreenFlag = false,
  }) async {
    Duration? seek = defaultST ?? playedTime;
    if (seek == .zero) seek = null;
    seek ??= getFirstSegment();
    // a new part, whose subtitle list is only asked for once the player is
    // up (see [_holdForSubtitles])
    if (vttSubtitlesIndex.value == -1) _holdForSubtitles();
    final play = autoplay ?? _autoPlay.value;
    // the gate hides the player, and playback waits behind it too
    final held = asrPending.value;
    if (held) _playOnRelease = play;
    final DataSource source = isFileSource
        ? FileSource(
            dir: args['dirPath'],
            typeTag: entry.streamTypeTag,
            isMp4: entry.mediaType == 1,
            hasDashAudio: entry.hasDashAudio,
            mergedPath: entry.mergedPath,
            uri: entry.playUri,
          )
        : NetworkSource(
            videoSource: videoUrl!,
            audioSource: audioUrl,
          );
    _ownSource = source;
    // the player is shared: a page opened over this one and closed again
    // took these with it
    plPlayerController
      ..onCdnFailover = switchToNextCdn
      ..onStreamCut = replaceCutStreams
      ..onStreamSlow = replaceSlowStreams
      ..onStreamRoomy = raiseQuality
      ..onReopen = _reopenAtCurrentPosition
      ..streamBitrate = _streamBitrate;
    _loadingSource = true;
    await plPlayerController.setDataSource(
      source,
      seekTo: seek,
      duration: data.timeLength == null
          ? null
          : Duration(milliseconds: data.timeLength!),
      isVertical: isVertical.value,
      aid: aid,
      bvid: bvid,
      cid: cid.value,
      autoplay: play && !held,
      epid: isUgc ? null : epId,
      seasonId: isUgc ? null : seasonId,
      pgcType: isUgc ? null : pgcType,
      videoType: videoType,
      onInit: () {
        _watchPlayback();
        videoState.value = true;
        _applySubtitle(vttSubtitlesIndex.value);
      },
      width: firstVideo.width,
      height: firstVideo.height,
      volume: volume,
      autoFullScreenFlag: autoFullScreenFlag,
    );
    _loadingSource = false;
    // the gate may have let go while the source was loading
    _resumeHeldPlayback();

    if (isClosed) return;

    if (!isFileSource) {
      if (plPlayerController.enableBlock) {
        initSkip();
      }

      if (vttSubtitlesIndex.value == -1) {
        _queryPlayInfo();
      } else {
        // subtitles were settled on an earlier pass (a quality switch, say);
        // the source is only known now, so this is where auto-start can fire
        _maybeAutoTranscribe();
      }

      if (plPlayerController.showDmChart && dmTrend.value == null) {
        _getDmTrend();
      }
    } else {
      await _loadLocalSubtitles();
      _maybeAutoTranscribe(opening: true);
    }

    defaultST = null;
  }

  /// LibrePili: subtitles saved next to a downloaded video
  /// (`<base>.<lan>.srt` in the video's folder), loaded without network.
  Future<void> _loadLocalSubtitles() async {
    // Read in full before the list is touched. A transcript or translation
    // publish landing mid-read would otherwise add its track at whatever
    // index the half-built list had reached, and the next file read into
    // that slot — or that track into a file's.
    final saved = <({String lan, String text})>[];
    final merged = entry.mergedPath;
    if (merged != null) {
      final dir = Directory(path.dirname(merged));
      final base = path.basenameWithoutExtension(merged);
      if (dir.existsSync()) {
        final files = dir.listSync().whereType<File>().where((f) {
          final name = path.basename(f.path);
          return name.startsWith('$base.') && name.endsWith('.srt');
        }).toList()..sort((a, b) => a.path.compareTo(b.path));
        for (final f in files) {
          final name = path.basename(f.path);
          final lan = name.substring(base.length + 1, name.length - 4);
          saved.add((lan: lan, text: await f.readAsString()));
        }
      }
    }
    // tracks made on the device, including ones stopped and kept in the
    // menu: those have no session left to rebuild them from
    final made = <String, ({bool isData, String id})>{
      for (var i = 0; i < subtitles.length; i++)
        if (subtitles[i].source == SubtitleSource.device)
          subtitles[i].lan: ?vttSubtitles[i],
    };
    // from here until the tracks are all in place, nothing is awaited
    vttSubtitles.clear();
    subtitles.clear();
    vttSubtitlesIndex.value = 0;
    // the tracks made on the device went with the list: their indexes would
    // now point at a saved file's, or at nothing (see
    // [_restoreGeneratedTracks])
    _asrTrackIndex = null;
    _translationTrackIndex = null;
    for (final (:lan, :text) in saved) {
      vttSubtitles[subtitles.length] = (isData: true, id: text);
      subtitles.add(Subtitle(lan: lan, lanDoc: lan));
    }
    _restoreGeneratedTracks(made);
    if (isClosed) return;
    if (saved.isNotEmpty) {
      await _setSubtitle(subtitles.toList());
    } else {
      // the player was handed the choice from before the rebuild — the
      // translation, say — which no longer matches the list; off, as the
      // index now says
      await _applyOwnSubtitle(0);
    }
  }

  /// Puts the transcript and translation made for this part back after the
  /// saved subtitles, when [_loadLocalSubtitles] runs again for a player made
  /// anew (coming back to the page). They are on no disk to be found, and a
  /// finished one is never published again. Not selected: the list was just
  /// chosen from afresh.
  ///
  /// [made] is what the list held before, by language: one the viewer
  /// stopped has no session any more and comes back as it was, kept in the
  /// menu as the stop left it.
  void _restoreGeneratedTracks(Map<String, ({bool isData, String id})> made) {
    if (isClosed) return;
    final cues = asrSession.value?.cues;
    if (cues != null && cues.isNotEmpty) {
      final index = _asrTrackIndex = subtitles.length;
      vttSubtitles[index] = (isData: true, id: _transcriptVtt(cues));
      subtitles.add(
        Subtitle(
          lan: 'asr',
          lanDoc: onDeviceLabel(null),
          source: SubtitleSource.device,
        ),
      );
    } else if (made['asr'] case final track?) {
      vttSubtitles[subtitles.length] = track;
      subtitles.add(
        Subtitle(
          lan: 'asr',
          lanDoc: onDeviceLabel(null),
          source: SubtitleSource.device,
        ),
      );
    }
    final live = translation.currentVtt;
    final kept = made['asr-translated'];
    if (live != null || kept != null) {
      final index = subtitles.length;
      if (live != null) {
        _translationTrackIndex = index;
        vttSubtitles[index] = (isData: true, id: live);
      } else {
        vttSubtitles[index] = kept!;
      }
      subtitles.add(
        Subtitle(
          lan: 'asr-translated',
          lanDoc: onDeviceLabel(translation.into ?? AsrService.appLanguage),
          source: SubtitleSource.device,
        ),
      );
    }
  }

  bool isQuerying = false;

  final languages = Rxn<List<LanguageItem>>();
  final currLang = Rxn<String>();
  void setLanguage(String language) {
    if (currLang.value == language) return;
    if (!isLoginVideo) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    currLang.value = language;
    queryVideoUrl(fromReset: true);
  }

  Future<LoadingState<PlayUrlModel>> _getVideoUrl(int quality) {
    return VideoHttp.videoUrl(
      cid: cid.value,
      bvid: bvid,
      qn: quality,
      epid: epId,
      seasonId: seasonId,
      tryLook: plPlayerController.tryLook,
      videoType: _actualVideoType ?? videoType,
      language: currLang.value,
      voiceBalance: plPlayerController.enableAudioNormalization,
    );
  }

  Future<void> _supplementVideoQualities() async {
    final quality = data.missingVideoQualityBelowHighest;
    if (quality == -1) return;
    final result = await _getVideoUrl(quality);
    if (result case Success(:final response)) {
      data.dash!.video!.merge(response.dash?.video);
    }
  }

  Volume? volume;

  // 视频链接
  /// TODO: merge [DownloadHttp.getVideoUrl].
  Future<void> queryVideoUrl({
    bool fromReset = false,
    bool autoFullScreenFlag = false,
  }) async {
    if (isFileSource) {
      return _initPlayerIfNeeded(autoFullScreenFlag);
    }
    if (isQuerying) {
      // an episode picked while the previous round trip runs must not be
      // dropped: its answer is fetched as soon as that one is in
      _pendingQuery = (fromReset, autoFullScreenFlag);
      return;
    }
    isQuerying = true;
    try {
      await _queryVideoUrl(fromReset, autoFullScreenFlag);
      while (_pendingQuery != null) {
        final pending = _pendingQuery!;
        _pendingQuery = null;
        await _queryVideoUrl(pending.$1, pending.$2);
      }
    } finally {
      _pendingQuery = null;
      isQuerying = false;
    }
  }

  /// A [queryVideoUrl] call that arrived while one was in flight.
  (bool, bool)? _pendingQuery;

  @pragma('vm:prefer-inline')
  Future<void> _queryVideoUrl(bool fromReset, bool autoFullScreenFlag) async {
    // the episode this answer belongs to: `onChangeEpisode` can move the
    // page on while the play URL is being fetched, and applying the old
    // episode's stream would play it under the new episode's header
    final queryCid = cid.value;
    if (plPlayerController.enableSponsorBlock && isBlock && !fromReset) {
      querySponsorBlock(bvid: bvid, cid: cid.value);
    }
    if (plPlayerController.cacheVideoQa == null) {
      final isWiFi = await ConnectivityUtils.isWiFi;
      plPlayerController
        ..cacheVideoQa = isWiFi
            ? Pref.defaultVideoQa
            : Pref.defaultVideoQaCellular
        ..cacheAudioQa = isWiFi
            ? Pref.defaultAudioQa
            : Pref.defaultAudioQaCellular;
      preferCodecs = isWiFi ? Pref.preferCodecs : Pref.preferCodecsCellular;
    }

    final result = await _getVideoUrl(VideoQuality.hdrVivid.code);

    // superseded meanwhile: the queued request fetches the current episode
    if (cid.value != queryCid) {
      return;
    }

    if (result case Success(:final response)) {
      data = response;
      if (data.dash != null) await _supplementVideoQualities();

      languages.value = data.language?.items;
      currLang.value = data.curLanguage;

      volume = data.volume;

      if (!fromReset) {
        final progress = args.remove('progress');
        if (progress != null) {
          defaultST = Duration(milliseconds: progress);
        } else {
          defaultST = Duration(milliseconds: data.lastPlayTime);
        }
      }

      if (!isUgc && !fromReset && plPlayerController.enablePgcSkip) {
        if (data.clipInfoList case final clipInfoList?) {
          resetBlock();
          handleSBData(clipInfoList);
        }
      }

      if (data.acceptDesc?.contains('试看') == true) {
        SmartDialog.showToast(
          '该视频为专属视频，仅提供试看',
          displayTime: const Duration(seconds: 3),
        );
      }
      if (data.dash == null) {
        if (data.durl case final durl?) {
          // it will cause all files to be opened simultaneously
          if (durl.length > 1) {
            // TODO: refa
            final sb = StringBuffer('edl://!no_chapters;');
            for (var i in durl) {
              final video = VideoUtils.getCdnUrl(i.playUrls);
              sb.write('%${video.length}%$video,length=${i.length! / 1000};');
            }
            videoUrl = sb.toString();
          } else {
            videoUrl = VideoUtils.getCdnUrl(durl.single.playUrls);
          }

          audioUrl = '';

          // 实际为FLV/MP4格式，但已被淘汰，这里仅做兜底处理
          final videoQuality = VideoQuality.fromCode(data.quality!);
          firstVideo = VideoItem(
            id: data.quality!,
            baseUrl: videoUrl,
            codecs: 'avc1',
            quality: videoQuality,
          );
          _setVideoHeight();
          currentDecodeFormats = VideoDecodeFormatType.AVC;
          currentVideoQa.value = videoQuality;
          await _initPlayerIfNeeded(autoFullScreenFlag);
          return;
        } else {
          SmartDialog.showToast('视频资源不存在');
          _autoPlay.value = false;
          videoState.value = false;
          if (plPlayerController.isFullScreen.value) {
            plPlayerController.triggerFullScreen(status: false);
          }
          return;
        }
      }

      // if (kDebugMode) debugPrint("allVideosList:${allVideosList}");
      final cacheVideoQa = plPlayerController.cacheVideoQa!;
      final targetVideoQa = data.findAvailableVideoQuality(cacheVideoQa);
      currentVideoQa.value = VideoQuality.fromCode(targetVideoQa);
      _qualityCeiling = targetVideoQa;

      /// 优先顺序 设置中指定解码格式 -> 当前可选的首个解码格式
      final supportFormats = data.supportFormats!;

      // 根据画质选编码格式
      currentDecodeFormats = VideoUtils.selectCodec(
        supportFormats
            .firstWhere(
              (e) => e.quality == targetVideoQa,
              orElse: () => supportFormats.first,
            )
            .codecs!,
        preferCodecs,
      );

      /// 取出符合当前画质的videoList
      final videosList = data.dash!.video!
          .where((e) => e.quality.code == targetVideoQa)
          .toList();

      /// 取出符合当前解码格式的videoItem
      firstVideo = videosList.firstWhere(
        (e) => currentDecodeFormats.codes.any(e.codecs!.startsWith),
        orElse: () => videosList.first,
      );
      _setVideoHeight();

      videoUrl = VideoUtils.getCdnUrl(firstVideo.playUrls);

      /// 优先顺序 设置中指定质量 -> 当前可选的最高质量
      AudioItem? firstAudio;
      final audioList = data.dash?.audio;
      if (audioList != null && audioList.isNotEmpty) {
        final audioIds = audioList.map((map) => map.id).toList();
        int closestNumber = audioIds.findClosestTarget(
          (e) => e <= plPlayerController.cacheAudioQa,
          (a, b) => a > b ? a : b,
        );
        if (!audioIds.contains(plPlayerController.cacheAudioQa) &&
            audioIds.any((e) => e > plPlayerController.cacheAudioQa)) {
          closestNumber = AudioQuality.k192.code;
        }
        firstAudio = audioList.firstWhere(
          (e) => e.id == closestNumber,
          orElse: () => audioList.first,
        );
        _currentAudio = firstAudio;
        audioUrl = VideoUtils.getCdnUrl(firstAudio.playUrls, isAudio: true);
        currentAudioQa = AudioQuality.fromCode(firstAudio.id);
      } else {
        audioUrl = '';
      }
      await _pickFastestHost();
      await _initPlayerIfNeeded(autoFullScreenFlag);
    } else {
      _autoPlay.value = false;
      videoState.value = false;
      if (plPlayerController.isFullScreen.value) {
        plPlayerController.triggerFullScreen(status: false);
      }
      result.toast();
    }
  }

  late final List<PostSegmentModel> postList = <PostSegmentModel>[];
  void onBlock(BuildContext context) {
    if (postList.isEmpty) {
      postList.add(
        PostSegmentModel(
          segment: Pair(
            first: 0,
            second: plPlayerController.positionInMilliseconds / 1000,
          ),
          category: SegmentType.sponsor,
          actionType: ActionType.skip,
        ),
      );
    }
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      final child = PostPanel(
        enableSlide: false,
        videoDetailController: this,
        plPlayerController: plPlayerController,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage
            ? Theme(data: ThemeUtils.darkTheme, child: child)
            : child,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        constraints: const BoxConstraints(),
        (context) => PostPanel(
          videoDetailController: this,
          plPlayerController: plPlayerController,
        ),
      );
    }
  }

  RxList<Subtitle> subtitles = RxList<Subtitle>();
  final Map<int, ({bool isData, String id})> vttSubtitles = {};
  late final vttSubtitlesIndex = (-1).obs;
  late final showVP = true.obs;
  late final viewPointList = <ViewPointSegment>[].obs;

  /// The viewer picked a subtitle themselves — off, or a track — for this
  /// part. From then on nothing automatic changes which one is shown: not a
  /// transcript or translation arriving, finishing or failing. Turning them
  /// off does not stop either; they keep their tracks current, and picking
  /// one again shows it as it stands.
  var _viewerChoseSubtitle = false;

  // 设定字幕轨道
  /// The viewer's choice (see [_viewerChoseSubtitle]); automatic changes go
  /// through [_applySubtitle].
  Future<void> setSubtitle(int index) {
    _viewerChoseSubtitle = true;
    _wantedOnDevice = null;
    // a generated track kept running while hidden: bring its data up to date
    final picked = index - 1;
    if (picked >= 0 && picked == _translationTrackIndex) {
      if (translation.currentVtt case final vtt?) {
        vttSubtitles[picked] = (isData: true, id: vtt);
      }
    } else if (picked >= 0 && picked == _asrTrackIndex) {
      final cues = asrSession.value?.cues;
      if (cues != null && cues.isNotEmpty) {
        vttSubtitles[picked] = (isData: true, id: _transcriptVtt(cues));
      }
    }
    return _applySubtitle(index);
  }

  /// A change of subtitle the page makes by itself. The player is one for
  /// the whole app: while another page's video is on it, this page's tracks
  /// do not go there — the choice is only kept, for [playerInit] to hand the
  /// player when this page has it again.
  Future<void> _applyOwnSubtitle(int index) async {
    if (_ownsPlayer) return _applySubtitle(index);
    vttSubtitlesIndex.value = index;
  }

  Future<void> _applySubtitle(int index) async {
    if (index <= 0) {
      await plPlayerController.videoPlayerController?.setSubtitleTrack(.no());
      vttSubtitlesIndex.value = index;
      return;
    }

    Future<void> setSub(({bool isData, String id}) subtitle) async {
      final sub = subtitles[index - 1];

      String subUri = subtitle.id;
      if (subtitle.isData) {
        subUri = 'memory://$subUri';
      }
      await plPlayerController.videoPlayerController?.setSubtitleTrack(
        SubtitleTrack(subUri, sub.lanDoc, sub.lan, uri: true),
      );
      vttSubtitlesIndex.value = index;
    }

    var subtitle = vttSubtitles[index - 1];
    if (subtitle == null) {
      final result = await VideoHttp.getSubtitles(
        subtitles[index - 1].subtitleUrl!,
      );
      if (!isClosed && result != null) {
        subtitle = (isData: true, id: result);
        vttSubtitles[index - 1] = subtitle;
      } else {
        return;
      }
    }
    await setSub(subtitle);
  }

  // ---------------------------------------------------- LibrePili: 自动转录

  /// The transcription running for this part, if any. Reactive so the menu
  /// entry can watch it: an `Obx` that reads nothing observable is an error
  /// in GetX, and a null session used to make that entry throw and render as
  /// a grey error box in release builds.
  final asrSession = Rxn<AsrSession>();

  /// Whether transcription still owes the page its first subtitles.
  ///
  /// Transcription is treated as a peer of the video and audio streams: a
  /// video that is going to be watched with generated subtitles is not ready
  /// until they have started, the same way it is not ready until the stream
  /// has. Only an automatic run started with the page holds this — a manual
  /// start in the middle of playback must not blank out the player.
  final asrPending = false.obs;
  Timer? _asrGate;
  StreamSubscription<void>? _asrCueSub;
  Worker? _asrStateWorker;
  int? _asrTrackIndex;
  Timer? _asrRefresh;

  /// The translation of the transcript, when the speech is in a language the
  /// app is not. A peer of the transcript: an automatic run that is going to
  /// be translated holds the page until the first translated line, not the
  /// first recognised one.
  late final translation = TranslationTrack(
    // the player counts whole seconds
    position: () => plPlayerController.position.value.toDouble(),
    ownsPlayer: () => _ownsPlayer,
    onPublish: _publishTranslation,
    onReady: _closeAsrGate,
    // not over another video's page: this one's menu says it when it is back
    onFailed: (message) {
      if (_ownsPlayer) FailureReport.show('翻译失败', message);
    },
  );
  int? _translationTrackIndex;

  /// The gate waits for [translation] rather than for the transcript.
  var _gateOnTranslation = false;

  /// The user asked for a translation of this run from the menu.
  var _translationRequested = false;

  /// Bumped by [stopTranslation], so a start waiting on a fetch can tell.
  var _translationStops = 0;

  /// The translation running is of the transcript, not of captions.
  var _translatingTranscript = false;

  /// Automatic translation has run for this part, or the user stopped one:
  /// only the menu starts another. A quality switch or CDN failover comes
  /// back through [_maybeAutoTranscribe], and must not undo a stop.
  var _autoTranslateOff = false;

  /// Playback of this part has started. Only the page opening may hold the
  /// page behind the loading gate; an automatic check from a later pass — a
  /// quality switch, a CDN failover — comes with playback under way, and the
  /// gate must not open then whether or not it ever did before.
  var _pastOpening = false;

  /// Where the playhead stood, in whole seconds, when the player was first
  /// shown for this part. The player is shown before the subtitle request
  /// that may open the gate has even been sent, so being shown alone cannot
  /// close the opening; the playhead moving on from here can — past that the
  /// viewer is watching, and whichever request answers late may not blank
  /// the player out.
  int? _shownAt;

  /// The playhead has moved on from [_shownAt]. A latch, set by watching the
  /// playhead rather than read from it when the gate is asked for: a seek
  /// back to where playback started must not make it false again.
  var _playbackUnderway = false;
  Worker? _underwayWorker;

  /// Called when the player is shown; only the first time counts.
  void _watchPlayback() {
    if (_shownAt != null) return;
    final shownAt = _shownAt = plPlayerController.position.value;
    _underwayWorker = ever<int>(plPlayerController.position, (position) {
      if (position <= shownAt) return;
      _playbackUnderway = true;
      _stopWatchingPlayback();
    });
  }

  void _stopWatchingPlayback() {
    _underwayWorker?.dispose();
    _underwayWorker = null;
  }

  /// What libmpv should decode for transcription. The audio stream on its own
  /// where there is one — feeding it the player's `edl://` would pull video
  /// headers as well for no benefit.
  String? get _asrSource {
    if (isFileSource) return entry.mergedPath ?? entry.playUri;
    if (audioUrl case final audio? when audio.isNotEmpty) return audio;
    return videoUrl;
  }

  bool get canTranscribe => _asrSource?.isNotEmpty == true;

  Future<void> startAsr({bool auto = false}) async {
    var source = _asrSource;
    if (source == null || source.isEmpty) {
      SmartDialog.showToast('没有可转录的音频');
      return;
    }
    // an automatic start takes over the hold for the subtitle list rather
    // than letting the player go in between (see [_holdForSubtitles])
    final holding = auto && _holdingForSubtitles;
    _holdingForSubtitles = false;
    // a document opened through Android's picker has no path, only a content
    // URI, and the descriptor the player holds is its own — transcription
    // needs a second one, which mpv closes itself via `fdclose://`
    if (source.startsWith('content://')) {
      final fd = await LocalDocuments.openFd(source);
      if (fd == null) {
        if (holding) _closeAsrGate();
        SmartDialog.showToast('无法读取该视频文件');
        return;
      }
      // closed meanwhile: nothing will hand the descriptor to mpv to close
      if (isClosed) {
        LocalDocuments.closeFd(fd);
        return;
      }
      source = 'fdclose://$fd';
    }
    await stopAsr(keepGate: holding);
    // closed meanwhile: no gate for a page that is gone, and no start that
    // would end whichever transcription is running now
    if (isClosed) return;
    if (auto) _openAsrGate();
    final service = AsrService.to;
    final session = await service.start(
      key: '$cid',
      source: source,
      referer: isFileSource ? null : HttpString.baseUrl,
      userAgent: isFileSource ? null : BrowserUa.pc,
      auto: auto,
      // Runs from where the viewer is (research/chunked-transcription-
      // design-2026-09-25.md) need a source that can be started from a
      // position: not a document read once through its descriptor, nor the
      // durl/FLV fallback, which has no index to seek by. Those keep the
      // one run from 0.
      seekable:
          !source.startsWith('fdclose://') &&
          (isFileSource || (audioUrl?.isNotEmpty ?? false)),
      // only while the player is this page's: another page's position
      // says nothing about where this video's viewer is
      playhead: () =>
          _ownsPlayer ? plPlayerController.position.value.toDouble() : null,
      duration: () => _ownsPlayer && plPlayerController.duration.value > 0
          ? plPlayerController.duration.value.toDouble()
          : null,
      // the stream URL the page has now: it replaces an expired one when
      // it fails over or refreshes for its own playback
      refresh: ({bool expired = false}) async {
        final now = _asrSource;
        return now == null || now.isEmpty || now.startsWith('content://')
            ? null
            : now;
      },
    );
    // closed meanwhile: onClose found no session to stop, and nothing else
    // would ever stop this one
    if (isClosed) {
      AsrService.to.stop(only: session);
      return;
    }
    asrSession.value = session;

    // cues stream in; rebuilding the track on every batch would restart the
    // renderer constantly, so coalesce into one refresh a few seconds
    _asrRefresh = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _publishAsrSubtitle(),
    );
    // the first cues are what the page has been waiting for — unless they
    // are about to be translated, in which case it waits for that
    _asrCueSub = session.cues.listen((_) {
      if (!_gateOnTranslation) _closeAsrGate();
      _publishAtNewPosition(session);
    });
    _asrStateWorker = ever(session.state, (state) {
      // the language is known from the first segment on
      if (state.language != null) {
        // a corrected language can turn out to be the user's own
        if (_translatingTranscript &&
            !TranslationService.to.needed(
              state.language,
              // the language it is being translated into, which is not the
              // app's when picked from the menu (Chinese speech in
              // Traditional Chinese is still to be converted)
              into: translation.into,
            )) {
          _stopTranscriptTranslation();
        }
        _maybeTranslate(session, auto: auto);
      }
      switch (state.stage) {
        case AsrStage.done:
          if (!_gateOnTranslation) _closeAsrGate();
          // a translation, if there is one, is what the viewer is reading
          _publishAsrSubtitle(
            select: translation.session.value == null,
            isFinal: true,
          );
        case AsrStage.failed:
          _closeAsrGate();
          _stopTranscriptTranslation();
          // errors are the one thing still worth interrupting for: everything
          // else about a transcription is visible in the subtitle menu, and a
          // toast per stage turned a background job into a stream of popups.
          // Not over another video's page, whose transcription this may be
          // the one displaced by
          if (_ownsPlayer) {
            FailureReport.show('转录失败', state.message ?? '未知原因');
          }
        case AsrStage.idle:
          _closeAsrGate();
          // stopped before its track comes off, or it would put it back
          _stopTranscriptTranslation(always: true);
          // the service gave up on its own — an automatic run that turned out
          // to be in the user's own language. Take the half-finished track
          // back off the menu; a *manual* stop keeps what was recognised.
          _removeAsrTrack();
        case _:
          break;
      }
    });
  }

  /// The page is being held until the subtitle list is known.
  var _holdingForSubtitles = false;

  /// Holds a new part's page, when automatic translation could apply, until
  /// its subtitle list is known. The list is asked for only after the player
  /// is up, and an answer arriving once playback had shown could no longer
  /// hold the page for a translation of the captions it names — the
  /// playhead counts whole seconds, so a first second of playback went by
  /// unnoticed. Decided before the player is shown instead: whatever holds
  /// the page takes this over when the list comes, and otherwise it is let
  /// go at once (see [_releaseSubtitleHold]).
  void _holdForSubtitles() {
    if (_autoTranslateOff || !Get.isRegistered<TranslationService>()) return;
    if (!TranslationService.to.shouldAutoTranslate) return;
    _openAsrGate();
    _holdingForSubtitles = asrPending.value;
  }

  /// The subtitle list is known, or will not be: the hold for it ends,
  /// unless a translation of the captions or an automatic transcription has
  /// taken it over.
  void _releaseSubtitleHold() {
    if (!_holdingForSubtitles) return;
    _holdingForSubtitles = false;
    if (!_gateOnTranslation) _closeAsrGate();
  }

  /// Starts transcription by itself when the user has said it should and the
  /// video has nothing of its own. Never asks anything here: an automatic run
  /// that popped a dialog would be worse than no automatic run.
  ///
  /// [opening] is the check made as the part is first loaded.
  void _maybeAutoTranscribe({bool opening = false}) {
    try {
      _autoTranscribe(opening: opening);
    } finally {
      _releaseSubtitleHold();
    }
  }

  void _autoTranscribe({required bool opening}) {
    if (!opening) _pastOpening = true;
    // a video with captions in a language the user does not read has them
    // translated instead; transcription is for videos with none
    _maybeAutoTranslateCaptions();
    if (!Get.isRegistered<AsrService>()) return;
    // the source is resolved by queryVideoUrl, the subtitles by
    // _queryPlayInfo: whichever finishes last is the one that starts this
    if (asrSession.value != null || !canTranscribe) return;
    if (!AsrService.to.shouldAutoStart(hasSubtitles: subtitles.isNotEmpty)) {
      return;
    }
    startAsr(auto: true);
  }

  /// Holds the page in its loading state until transcription has produced
  /// something, with a cap so a decoder that never delivers cannot wedge it.
  void _openAsrGate() {
    // past the opening, playback has started (see [_pastOpening])
    if (_pastOpening || _playbackUnderway) return;
    _asrGate?.cancel();
    asrPending.value = true;
    _asrGate = Timer(const Duration(seconds: 30), _closeAsrGate);
    _holdPlayback();
  }

  void _closeAsrGate() {
    _asrGate?.cancel();
    _asrGate = null;
    // nothing waits for the translation once the gate is down
    _gateOnTranslation = false;
    if (asrPending.value) {
      asrPending.value = false;
      // the player has been released: the gate had its one chance
      _pastOpening = true;
      _resumeHeldPlayback();
    }
  }

  /// Playback the gate is holding back, to go on when it lets go. The player
  /// is hidden behind the gate, and a video playing on unseen would spend its
  /// opening — the stretch the gate waits to have subtitles for — with no
  /// picture at all.
  var _playOnRelease = false;
  Worker? _gatePlaybackWorker;

  /// [plPlayerController.setDataSource] is under way for this page.
  var _loadingSource = false;

  /// The source this page last handed the player: its token of ownership.
  DataSource? _ownSource;

  /// The player is one for the whole app, and still playing what this page
  /// gave it. The very source object, not its cid: every ordinary local file
  /// has cid 0, and another page opening another one would look like this.
  bool get _ownsPlayer {
    final own = _ownSource;
    return own != null && identical(plPlayerController.dataSource, own);
  }

  /// Keeps playback paused while the gate is up: whatever starts it then —
  /// an autoplay already in flight — is paused again at once.
  void _holdPlayback() {
    _gatePlaybackWorker ??= ever<PlayerStatus>(
      plPlayerController.playerStatus,
      (status) {
        if (!asrPending.value) return;
        // another page has the player now: what it plays is not this gate's
        if (!_ownsPlayer) {
          _releaseHold();
        } else if (status.isPlaying) {
          _pauseForGate();
        }
      },
    );
    if (_ownsPlayer && plPlayerController.playerStatus.isPlaying) {
      _pauseForGate();
    }
  }

  void _pauseForGate() {
    _playOnRelease = true;
    plPlayerController.pause();
  }

  /// Stops touching the player at all: nothing is paused or resumed for this
  /// page any more.
  void _releaseHold() {
    _playOnRelease = false;
    _gatePlaybackWorker?.dispose();
    _gatePlaybackWorker = null;
    _stopWaitingForReturn();
  }

  /// Waits for the app to be back in view, when the gate let go while it
  /// was away.
  AppLifecycleListener? _returnListener;

  void _stopWaitingForReturn() {
    _returnListener?.dispose();
    _returnListener = null;
  }

  /// Another page is open over this one. The gate hides only the player, so
  /// the viewer can open an uploader's page or a search meanwhile; the gate
  /// letting go then would play this video's sound under that page.
  var _covered = false;

  /// Told by the page as another is pushed over it and popped again: held
  /// playback goes on at the return, like one released with the app away.
  void setCovered(bool covered) {
    _covered = covered;
    if (!covered) _resumeHeldPlayback();
  }

  /// Lets held-back playback go on, once the gate is down and the player has
  /// this part loaded.
  void _resumeHeldPlayback() {
    if (!_playOnRelease || asrPending.value || _loadingSource) return;
    if (isClosed || !_ownsPlayer) {
      _releaseHold();
      return;
    }
    if (_covered) return;
    // The gate can let go with the app away — the model guard stopping the
    // run, the cap, a late subtitle list — and the player view pauses only
    // as the app leaves, when the gate had it paused already. Playing now
    // would play to nobody, with 后台播放 off; it waits for the return.
    if (!plPlayerController.continuePlayInBackground.value &&
        isAppAway(WidgetsBinding.instance.lifecycleState)) {
      _returnListener ??= AppLifecycleListener(
        onStateChange: (state) {
          if (isAppAway(state)) return;
          _stopWaitingForReturn();
          _resumeHeldPlayback();
        },
      );
      return;
    }
    _stopWaitingForReturn();
    _playOnRelease = false;
    PlPlayerController.playIfExists();
  }

  /// Stops transcription, and the translation made from it. A translation of
  /// the video's own captions has nothing to do with the transcript and goes
  /// on, unless the part or the page is [leaving].
  Future<void> stopAsr({bool keepGate = false, bool leaving = false}) async {
    if (!keepGate) {
      _holdingForSubtitles = false;
      _closeAsrGate();
    }
    _gateOnTranslation = false;
    _translationRequested = false;
    final stopsTranslation = leaving || _translatingTranscript;
    if (stopsTranslation) _translatingTranscript = false;
    // the transcript's listeners go before anything is awaited: a part
    // switch does not wait for this, and a progress event from the old run
    // in the meantime would start translating it all over again
    _asrRefresh?.cancel();
    _asrRefresh = null;
    _asrStateWorker?.dispose();
    _asrStateWorker = null;
    // cancelled at once, awaited after: no event arrives past the call
    final cueSub = _asrCueSub?.cancel();
    _asrCueSub = null;
    // let go of before anything is awaited as well: the translation can take
    // seconds to release its model, and a part switch or another page may
    // start a transcription meanwhile — which is not this one to stop
    final session = asrSession.value;
    asrSession.value = null;
    _asrTrackIndex = null;
    if (stopsTranslation) {
      // what was translated stays in the menu, without its waiting marks,
      // unless the part it belongs to is going away
      final stopped = translation.stop(finish: !leaving);
      _translationTrackIndex = null;
      await stopped;
    }
    await cueSub;
    if (session != null && Get.isRegistered<AsrService>()) {
      await AsrService.to.stop(only: session);
    }
  }

  /// Drops the transcription track again, but only while it is still the last
  /// one: anything else would shift the indexes [vttSubtitles] is keyed by.
  void _removeAsrTrack() {
    _asrRefresh?.cancel();
    _asrRefresh = null;
    // the translation is made from the transcript and goes with it; it sits
    // after it, so it comes off first
    final translated = _translationTrackIndex;
    if (translated != null && translated == subtitles.length - 1) {
      _translationTrackIndex = null;
      subtitles.removeLast();
      vttSubtitles.remove(translated);
      if (vttSubtitlesIndex.value == translated + 1) _applyOwnSubtitle(0);
    }
    final index = _asrTrackIndex;
    if (index == null || index != subtitles.length - 1) return;
    _asrTrackIndex = null;
    subtitles.removeLast();
    vttSubtitles.remove(index);
    if (vttSubtitlesIndex.value == index + 1) _applyOwnSubtitle(0);
  }

  /// Starts translating [session] once its language is known, if it should
  /// be: automatically when the user chose that, or because they asked from
  /// the menu. Never for speech already in the app's language.
  void _maybeTranslate(AsrSession session, {required bool auto}) {
    // isActive, not session: a start in progress has no session yet
    if (translation.isActive || isClosed) return;
    if (!Get.isRegistered<TranslationService>()) return;
    final service = TranslationService.to;
    final language = session.state.value.language;
    // picked from the menu before the language was known, and the speech
    // turns out to be in it: what was picked is the transcript
    if (_translationRequested &&
        language != null &&
        !service.needed(language, into: _requestedInto) &&
        _wantedOnDevice != null &&
        _wantedOnDevice != 'asr') {
      _translationRequested = false;
      _wantedOnDevice = 'asr';
      SmartDialog.showToast(
        '原声即为${translationLanguageLabel(_requestedInto ?? AsrService.appLanguage)}',
      );
      _publishAsrSubtitle(select: true, isFinal: true);
      return;
    }
    // asked from the menu, which has already offered the download: the
    // session fetches the model itself, into the language picked there
    final requested =
        _translationRequested && service.needed(language, into: _requestedInto);
    final wanted =
        requested || (!_autoTranslateOff && service.shouldAutoStart(language));
    if (!wanted) return;
    _autoTranslateOff = true;
    _translatingTranscript = true;
    // an automatic run holds the page until the translation has a line
    if (auto && asrPending.value) _gateOnTranslation = true;
    _startUnawaited(
      translation.start(session, into: requested ? _requestedInto : null),
    );
  }

  /// A translation start nobody awaits. What it throws — a fetch, a model
  /// that would not let go — is reported like any other failure, and a gate
  /// waiting for it lets go rather than sitting out its cap.
  void _startUnawaited(Future<Object?> start) {
    start.then<void>(
      (_) {},
      onError: (Object e) {
        if (isClosed) return;
        _closeAsrGate();
        FailureReport.show('翻译失败', '$e');
      },
    );
  }

  /// Ends a translation of the transcript once the transcript has stopped
  /// short of done, or is in the user's own language after all. It would
  /// otherwise wait for the rest forever, with the model loaded.
  ///
  /// One that has finished or failed is left for the menu to show, unless
  /// [always]: its track is about to come off, and its refresh timer would
  /// put it back.
  void _stopTranscriptTranslation({bool always = false}) {
    final ended = translation.session.value != null && !translation.isRunning;
    if (!_translatingTranscript || !translation.isActive) return;
    if (ended && !always) return;
    _translatingTranscript = false;
    // one whose track is about to come off has nothing to leave behind
    translation.stop(finish: !always);
    _stopGatingOnTranslation();
  }

  /// A translation the gate was waiting for will now never be ready: the
  /// gate goes back to waiting for the transcript, which may have lines by
  /// now — and its cue listener only lets go while nothing is translated.
  void _stopGatingOnTranslation() {
    if (!_gateOnTranslation) return;
    _gateOnTranslation = false;
    if (asrSession.value?.cues.isNotEmpty ?? false) _closeAsrGate();
  }

  /// The video's own track to translate, if one should be: none is in the
  /// app's language, and one is in another (see [pickCaptionToTranslate]).
  int? get captionToTranslate => captionToTranslateInto(null);

  /// The video's own track to translate into [into] (the app's language by
  /// default), if there is one to.
  int? captionToTranslateInto(String? into) => pickCaptionToTranslateInto(
    [
      for (final s in subtitles)
        (
          // tracks made on the device are not the video's own
          language: s.source == SubtitleSource.device ? '' : s.lan,
          generated: s.isAi,
        ),
    ],
    into: into ?? AsrService.appLanguage,
  );

  /// Translates the video's own foreign captions by itself when the user
  /// chose automatic translation. Holds the page like an automatic
  /// transcription does.
  void _maybeAutoTranslateCaptions() {
    if (translation.isActive || _autoTranslateOff || isClosed) return;
    if (!Get.isRegistered<TranslationService>()) return;
    if (!TranslationService.to.shouldAutoTranslate) return;
    final index = captionToTranslate;
    if (index == null) return;
    _autoTranslateOff = true;
    _openAsrGate();
    // past the opening no gate opens, and nothing is to wait for this
    if (asrPending.value) _gateOnTranslation = true;
    _startUnawaited(_translateCaptions(index));
  }

  /// Fetches track [index] if need be and translates it, into [into] (the
  /// app's language by default).
  Future<bool> _translateCaptions(int index, {String? into}) async {
    var content = vttSubtitles[index]?.id;
    if (content == null) {
      // a part switch reuses this controller: the answer may belong to the
      // part before, and must not land in this one's tracks
      final part = cid.value;
      final stops = _translationStops;
      final url = subtitles[index].subtitleUrl;
      content = url == null ? null : await VideoHttp.getSubtitles(url);
      // gone, or stopped while fetching: nothing more to do, and above all
      // no falling back to transcription
      if (isClosed) return true;
      if (stops != _translationStops) {
        _closeAsrGate();
        return true;
      }
      // nothing more to do for a part that is no longer playing
      if (cid.value != part) return true;
      if (content != null) vttSubtitles[index] = (isData: true, id: content);
    }
    final cues = content == null ? const <AsrCue>[] : parseCaptionCues(content);
    if (cues.isEmpty) {
      _closeAsrGate();
      return false;
    }
    _translatingTranscript = false;
    await translation.startCaptions(
      cues,
      into: into,
      from: captionLanguage(subtitles[index].lan),
    );
    return true;
  }

  /// Translates from the menu: the video's own captions when they are in a
  /// language the user does not read, otherwise the transcript — now if one
  /// is running or finished, else as soon as transcription has found the
  /// language.
  ///
  /// [mayTranscribe] asks whether falling back to transcription may fetch
  /// the recogniser's models; without it, missing models are not fetched.
  Future<void> startTranslation({
    Future<bool> Function()? mayTranscribe,
  }) async {
    final into = _requestedInto;
    if (asrSession.value == null) {
      if (captionToTranslateInto(into) case final index?) {
        if (await _translateCaptions(index, into: into)) return;
      }
    }
    _translationRequested = true;
    final session = asrSession.value;
    if (session == null || session.state.value.stage == AsrStage.failed) {
      // captions that could not be fetched land here too, and the menu has
      // not asked about the recogniser's download for them
      if (!AsrService.to.modelsReady &&
          (mayTranscribe == null || !await mayTranscribe())) {
        return;
      }
      if (isClosed) return;
      await startAsr();
      _translationRequested = true;
      return;
    }
    if (session.state.value.language == null) return;
    if (!TranslationService.to.needed(
      session.state.value.language,
      into: into,
    )) {
      // the transcript is already in that language, and is what is shown
      SmartDialog.showToast(
        '原声即为${translationLanguageLabel(into ?? AsrService.appLanguage)}',
      );
      if (_wantedOnDevice != null) await showTranscript();
      return;
    }
    // a finished or failed translation is started over (重新翻译, 点击重试):
    // _maybeTranslate leaves any existing one alone
    if (!translation.isRunning) await translation.stop();
    _maybeTranslate(session, auto: false);
  }

  /// Stops translating; what has been translated stays in the menu, in the
  /// entry a restart then refreshes rather than adding another beside it.
  Future<void> stopTranslation() async {
    _translationStops++;
    _translationRequested = false;
    // nor does automatic translation start it again for this part
    _autoTranslateOff = true;
    await translation.stop(finish: true);
  }

  /// Which on-device subtitle the viewer picked from the menu: `asr` for
  /// the transcript, or the language of a translation. Shown as soon as it
  /// exists, and kept current while it grows; any other pick ends it.
  String? _wantedOnDevice;

  /// The language a translation asked for from the menu is into: the app's
  /// when null.
  String? _requestedInto;

  int? _deviceTrack(String lan) {
    final index = subtitles.indexWhere(
      (s) => s.source == SubtitleSource.device && s.lan == lan,
    );
    return index == -1 ? null : index;
  }

  /// The on-device subtitle on screen: `asr`, the language of the
  /// translation, or null.
  String? get onDeviceShown {
    final shown = vttSubtitlesIndex.value - 1;
    if (shown < 0) return null;
    if (shown == _deviceTrack('asr')) return 'asr';
    if (shown == _deviceTrack('asr-translated')) {
      return translation.into ?? AsrService.appLanguage;
    }
    return null;
  }

  /// The on-device subtitle the menu shows as picked: the one on screen, or
  /// the one picked and not there yet.
  String? get onDevicePicked => onDeviceShown ?? _wantedOnDevice;

  /// Whether transcription or translation is at work, for the menu's stop.
  bool get onDeviceBusy =>
      (asrSession.value?.state.value.isBusy ?? false) ||
      (translation.session.value?.isActive ?? false);

  /// A word for the menu on where the on-device subtitle [code] — `asr`, or
  /// a language — stands; null with nothing to say.
  String? onDeviceStatus(String code) {
    final asr = asrSession.value?.state.value;
    String? asrStatus() => switch (asr?.stage) {
      AsrStage.models => asr!.message ?? '准备模型',
      AsrStage.extracting || AsrStage.transcribing => '生成中',
      AsrStage.failed => '失败，点击重试',
      _ => null,
    };
    if (code == 'asr') return asrStatus();
    final state = translation.session.value?.state.value;
    if (state != null && (translation.into ?? AsrService.appLanguage) == code) {
      return switch (state.stage) {
        TranslationStage.loading => state.message ?? '准备模型',
        TranslationStage.translating || TranslationStage.waiting => '生成中',
        TranslationStage.paused => '已暂停',
        TranslationStage.failed => '失败，点击重试',
        _ => null,
      };
    }
    // picked and waiting for the transcript it is to be made from
    if (_wantedOnDevice == code && _translationRequested) {
      return asrStatus() ?? '准备中';
    }
    return null;
  }

  /// Whether a transcript can be shown without starting one.
  bool get hasTranscript => _deviceTrack('asr') != null;

  /// Whether a translation into [into] can be shown without starting one.
  bool hasTranslationInto(String into) =>
      _deviceTrack('asr-translated') != null &&
      (translation.into ?? AsrService.appLanguage) == into &&
      translation.session.value?.state.value.stage != TranslationStage.failed;

  /// Shows the transcript, starting transcription if there is none to show
  /// (or the last one failed).
  Future<void> showTranscript() async {
    final index = _deviceTrack('asr');
    if (index != null) {
      await setSubtitle(index + 1);
    } else {
      _viewerChoseSubtitle = true;
    }
    _wantedOnDevice = 'asr';
    final session = asrSession.value;
    if ((index == null && session == null) ||
        session?.state.value.stage == AsrStage.failed) {
      await startAsr();
    }
  }

  /// Shows the translation into [into], starting it if there is none — a
  /// running one into another language is replaced.
  Future<void> showTranslation(
    String into, {
    Future<bool> Function()? mayTranscribe,
  }) async {
    if (hasTranslationInto(into)) {
      await setSubtitle(_deviceTrack('asr-translated')! + 1);
      _wantedOnDevice = into;
      return;
    }
    _viewerChoseSubtitle = true;
    _wantedOnDevice = into;
    if (translation.isActive) {
      _translationStops++;
      await translation.stop();
    }
    _requestedInto = into == AsrService.appLanguage ? null : into;
    await startTranslation(mayTranscribe: mayTranscribe);
  }

  /// The menu's 停止端侧生成: both, what they made stays in the menu.
  Future<void> stopOnDevice() async {
    await stopTranslation();
    await stopAsr();
  }

  void _publishTranslation(String vtt, {required bool first}) {
    if (isClosed) return;
    // stopAsr lets go of the entry but leaves it in the menu (停止转录 keeps
    // what was made); a restart — 重新转录, a retry, a switch from captions
    // to the transcript — refreshes that one rather than adding a second
    var index =
        _translationTrackIndex ??
        subtitles.indexWhere(
          (s) => s.source == SubtitleSource.device && s.lan == 'asr-translated',
        );
    // named for the language it is in, which a restart can change
    final label = onDeviceLabel(translation.into ?? AsrService.appLanguage);
    if (index == -1) {
      index = subtitles.length;
      subtitles.add(
        Subtitle(
          lan: 'asr-translated',
          lanDoc: label,
          source: SubtitleSource.device,
        ),
      );
    } else if (subtitles[index].lanDoc != label) {
      subtitles[index].lanDoc = label;
      subtitles.refresh();
    }
    _translationTrackIndex = index;
    vttSubtitles[index] = (isData: true, id: vtt);
    // shown the first time — it is what the translation was started for —
    // unless the viewer has picked a subtitle, and refreshed while shown;
    // and shown when it is the language picked from the menu. Nor onto
    // another page's video: the player is one for the app, and a
    // translation replaced by that page's own still hands over its last track
    final wanted =
        _wantedOnDevice != null && _wantedOnDevice == translation.into;
    if (((first && !_viewerChoseSubtitle) ||
            wanted ||
            vttSubtitlesIndex.value == index + 1) &&
        _ownsPlayer) {
      _applySubtitle(index + 1);
    }
  }

  /// Puts what has been recognised so far into the subtitle list, adding the
  /// track the first time and replacing its data afterwards.
  /// How far the published track reaches, so a refresh that would gain the
  /// viewer nothing can be skipped: stretch by stretch of the transcript,
  /// read at the playhead (see [PublishedReach]).
  PublishedReach _asrPublished = PublishedReach.none;

  /// The transcript as shown: with the punctuation its language shows in
  /// subtitles (see punctuateForDisplay).
  String _transcriptVtt(List<AsrCue> cues) =>
      cues.forDisplay(asrSession.value?.state.value.language).toVtt();

  /// Text has come for where the viewer is, and the track on screen has
  /// none there — the first cues of a run started for a jump: handed over
  /// at once, as the first cues ever are, not at the next refresh.
  void _publishAtNewPosition(AsrSession session) {
    if (_asrTrackIndex == null) return;
    final position = plPlayerController.position.value.toDouble();
    if (_asrPublished.at(position) > position) return;
    final span = coveredSpanOf(session.transcript.covered, position);
    if (span.from <= position && span.to > position) {
      _publishAsrSubtitle(isFinal: true);
    }
  }

  void _publishAsrSubtitle({bool select = false, bool isFinal = false}) {
    final session = asrSession.value;
    if (session == null || isClosed) return;
    final cues = session.cues;
    if (cues.isEmpty) return;

    // Handing mpv a rebuilt track reloads it, and the line on screen blinks.
    // While the transcript already runs well ahead of the playhead there is
    // nothing to gain by paying that.
    // the player counts whole seconds
    final position = plPlayerController.position.value;
    if (!shouldPublishAsr(
      publishedTo: Duration(
        milliseconds: (_asrPublished.at(position.toDouble()) * 1000).round(),
      ),
      position: Duration(seconds: position),
      isFirst: _asrTrackIndex == null,
      isFinal: isFinal || select,
    )) {
      return;
    }
    final vtt = _transcriptVtt(cues);
    _asrPublished = PublishedReach.of(cues, session.transcript.covered);

    var index = _asrTrackIndex;
    if (index == null) {
      index = subtitles.length;
      _asrTrackIndex = index;
      subtitles.add(
        Subtitle(
          lan: 'asr',
          lanDoc: onDeviceLabel(null),
          source: SubtitleSource.device,
        ),
      );
      select = true;
    }
    vttSubtitles[index] = (isData: true, id: vtt);
    // reselect so mpv picks up the longer text; only when this track is the
    // one being shown or the one picked from the menu, otherwise the user's
    // choice would be overridden
    if ((select && !_viewerChoseSubtitle) ||
        _wantedOnDevice == 'asr' ||
        vttSubtitlesIndex.value == index + 1) {
      _applyOwnSubtitle(index + 1);
    }
  }

  // interactive video
  int? graphVersion;
  EdgeInfoData? steinEdgeInfo;
  late final RxBool showSteinEdgeInfo = false.obs;

  Future<void> getSteinEdgeInfo([int? edgeId]) async {
    steinEdgeInfo = null;
    try {
      final res = await Request().get(
        '/x/stein/edgeinfo_v2',
        queryParameters: {
          'bvid': bvid,
          'graph_version': graphVersion,
          'edge_id': ?edgeId,
        },
      );
      if (res.data['code'] == 0) {
        steinEdgeInfo = EdgeInfoData.fromJson(res.data['data']);
      } else {
        if (kDebugMode) {
          debugPrint('getSteinEdgeInfo error: ${res.data['message']}');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('getSteinEdgeInfo: $e');
    }
  }

  late bool continuePlayingPart = Pref.continuePlayingPart;

  Future<void> _queryPlayInfo() async {
    vttSubtitles.clear();
    vttSubtitlesIndex.value = 0;
    if (plPlayerController.showViewPoints) {
      viewPointList.clear();
    }
    // a part switch reuses this controller: an answer for the part before
    // would put its subtitles — and a translation of them — on this one,
    // which has its own query on the way
    final part = cid.value;
    final res = await VideoHttp.playInfo(
      bvid: bvid,
      cid: part,
      seasonId: seasonId,
      epId: epId,
    );
    if (cid.value != part) return;
    if (res case Success(:final response)) {
      // interactive video
      late final introCtr = Get.find<UgcIntroController>(tag: heroTag);
      if (isUgc && graphVersion == null) {
        try {
          if (introCtr.videoDetail.value.rights?.isSteinGate == 1) {
            graphVersion = response.interaction?.graphVersion;
            getSteinEdgeInfo();
          }
        } catch (e) {
          if (kDebugMode) debugPrint('handle stein: $e');
        }
      }

      if (isUgc && continuePlayingPart) {
        continuePlayingPart = false;
        final lastCid = response.lastPlayCid;
        if (lastCid != null && lastCid != 0 && lastCid != cid.value) {
          try {
            final pages = introCtr.videoDetail.value.pages;
            if (pages != null && pages.length > 1) {
              final index = pages.indexWhere((item) => item.cid == lastCid);
              if (index != -1) {
                onAddItem(index);
              }
            }
          } catch (_) {}
        }
      }

      if (plPlayerController.showViewPoints &&
          response.viewPoints?.firstOrNull?.type == 2) {
        try {
          viewPointList.value = response.viewPoints!.map((item) {
            final end = (item.to! / (data.timeLength! / 1000)).clamp(0.0, 1.0);
            return ViewPointSegment(
              end: end,
              title: item.content,
              url: item.imgUrl,
              from: item.from,
              to: item.to,
            );
          }).toList();
        } catch (_) {}
      }

      if (response.subtitle?.subtitles case final sub? when (sub.isNotEmpty)) {
        _setSubtitle(sub);
      } else if (!Accounts.main.isLogin) {
        final res = await DmGrpc.dmView(aid, part);
        if (cid.value != part) return;
        if (res case Success(:final response)) {
          if (response.hasSubtitle() &&
              response.subtitle.subtitles.isNotEmpty) {
            _setSubtitle(
              response.subtitle.subtitles
                  .map(
                    (i) => Subtitle(
                      lan: i.lan,
                      lanDoc: i.lanDoc,
                      subtitleUrl: i.subtitleUrl.replaceFirst(
                        RegExp('^https?:'),
                        '',
                      ),
                      isAi: i.type == .AI,
                    ),
                  )
                  .toList()
                ..sort(),
            );
          }
        } else {
          res.toast();
        }
      }
      // LibrePili: nothing of its own to show — offer the device's own ears
      _maybeAutoTranscribe(opening: true);
    } else {
      // no list is coming
      _releaseSubtitleHold();
    }
  }

  Future<void> _setSubtitle(List<Subtitle> sub) async {
    subtitles.value = sub;
    final idx = switch (Pref.subtitlePreferenceV2) {
      .off => 0,
      .on => 1,
      .withoutAi => sub.first.lan.startsWith('ai') ? 0 : 1,
      .auto =>
        !sub.first.lan.startsWith('ai') ||
                (PlatformUtils.isMobile &&
                    (await FlutterVolumeController.getVolume() ?? 0.0) <= 0.0)
            ? 1
            : 0,
    };
    await _applyOwnSubtitle(idx);
  }

  void updateMediaListHistory(int aid) {
    if (args['sortField'] != null) {
      VideoHttp.medialistHistory(
        desc: _mediaDesc ? 1 : 0,
        oid: aid,
        upperMid: args['mediaId'],
      );
    }
  }

  void makeHeartBeat() {
    if (plPlayerController.enableHeart &&
        !plPlayerController.playerStatus.isCompleted &&
        playedTime != null) {
      try {
        plPlayerController.makeHeartBeat(
          data.timeLength != null
              ? (data.timeLength! - playedTime!.inMilliseconds).abs() <= 1000
                    ? -1
                    : playedTime!.inSeconds
              : playedTime!.inSeconds,
          type: HeartBeatType.completed,
          isManual: true,
          aid: aid,
          bvid: bvid,
          cid: cid.value,
          epid: isUgc ? null : epId,
          seasonId: isUgc ? null : seasonId,
          pgcType: isUgc ? null : pgcType,
          videoType: videoType,
        );
      } catch (_) {}
    }
  }

  @override
  void onClose() {
    _stopWatchingPlayback();
    if (_ownsPlayer || plPlayerController.processing) {
      plPlayerController.dropPendingSeek();
    }
    cid.close();
    if (isFileSource) {
      cacheLocalProgress();
      LocalPlayer.release(_localMirror);
    }
    introScrollCtr?.dispose();
    introScrollCtr = null;
    tabCtr.dispose();
    _scrollCtr?.dispose();
    animController
      ?..removeListener(_animListener)
      ..dispose();
    subtitles.clear();
    vttSubtitles.clear();
    // the gate coming down on the way out must not start the player again
    _releaseHold();
    stopAsr(leaving: true);
    if (plPlayerController.onCdnFailover == switchToNextCdn) {
      plPlayerController.onCdnFailover = null;
    }
    if (plPlayerController.onStreamCut == replaceCutStreams) {
      plPlayerController.onStreamCut = null;
    }
    if (plPlayerController.onStreamSlow == replaceSlowStreams) {
      plPlayerController.onStreamSlow = null;
    }
    if (plPlayerController.onStreamRoomy == raiseQuality) {
      plPlayerController.onStreamRoomy = null;
    }
    if (plPlayerController.onReopen == _reopenAtCurrentPosition) {
      plPlayerController.onReopen = null;
    }
    super.onClose();
  }

  void onReset({bool isStein = false}) {
    if (isFileSource) {
      cacheLocalProgress();
    }

    _lastLocalSaveSec = 0;
    playedTime = null;
    defaultST = null;
    // a seek made on the part being left is not one for the next
    plPlayerController.dropPendingSeek();
    videoUrl = null;
    audioUrl = null;
    _triedHosts.clear();
    _hostSpeeds.clear();
    _qualityChosen = false;
    _qualityCeiling = null;
    _currentAudio = null;

    // danmaku
    savedDanmaku = null;

    // subtitle
    subtitles.clear();
    vttSubtitlesIndex.value = -1;
    vttSubtitles.clear();
    // a transcription belongs to the part it was started for; the next part
    // plays as its own opening decides, not as this one's gate held back
    _playOnRelease = false;
    stopAsr(leaving: true);
    // and so do the once-per-part automatic translation and loading gate,
    // and the viewer's pick of subtitle
    _autoTranslateOff = false;
    _viewerChoseSubtitle = false;
    _wantedOnDevice = null;
    _requestedInto = null;
    _pastOpening = false;
    _stopWatchingPlayback();
    _shownAt = null;
    _playbackUnderway = false;

    if (!isFileSource) {
      // language
      languages.value = null;
      currLang.value = null;

      // dm trend
      if (plPlayerController.showDmChart) {
        dmTrend.value = null;
      }

      // view point
      if (plPlayerController.showViewPoints) {
        viewPointList.clear();
      }

      // sponsor block
      if (blockConfig.enableBlock) {
        resetBlock();
      }

      // interactive video
      if (!isStein) {
        graphVersion = null;
      }
      steinEdgeInfo = null;
      showSteinEdgeInfo.value = false;
    }
  }

  late final Rx<LoadingState<List<double>>?> dmTrend =
      Rx<LoadingState<List<double>>?>(null);
  late final RxBool showDmTrendChart = true.obs;

  Future<void> _getDmTrend() async {
    dmTrend.value = LoadingState<List<double>>.loading();
    try {
      final res = await Request().get(
        'https://bvc.bilivideo.com/pbp/data',
        queryParameters: {
          'aid': aid,
          'bvid': bvid,
          'cid': cid.value,
          'r': 'loader',
        },
        options: Options(
          headers: {
            'user-agent': BrowserUa.pc,
            'origin': 'https://www.bilibili.com',
            'referer': 'https://www.bilibili.com/video/$bvid',
          },
        ),
      );
      dynamic json;
      try {
        json = (res.data['modules'] as List).first['params']['data'];
      } catch (_) {
        json = res.data;
      }
      final data = PbpData.fromJson(json);
      final stepSec = data.stepSec ?? 0;
      if (stepSec != 0 && data.events?.eDefault?.isNotEmpty == true) {
        dmTrend.value = Success(data.events!.eDefault!);
        return;
      }
      dmTrend.value = const Error(null);
    } catch (e) {
      dmTrend.value = const Error(null);
      if (kDebugMode) debugPrint('_getDmTrend: $e');
    }
  }

  void showNoteList(BuildContext context) {
    String? title;
    try {
      title = Get.find<UgcIntroController>(
        tag: heroTag,
      ).videoDetail.value.title;
    } catch (_) {}
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      final child = NoteListPage(
        oid: aid,
        enableSlide: false,
        heroTag: heroTag,
        isStein: graphVersion != null,
        title: title,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage
            ? Theme(data: ThemeUtils.darkTheme, child: child)
            : child,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        constraints: const BoxConstraints(),
        (context) => NoteListPage(
          oid: aid,
          heroTag: heroTag,
          isStein: graphVersion != null,
          title: title,
        ),
      );
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  bool onSkipSegment() {
    try {
      if (plPlayerController.enableBlock) {
        if (listData.lastOrNull case final SegmentModel item) {
          onSkip(item, isSeek: false);
          onRemoveItem(listData.indexOf(item), item);
          return true;
        }
      }
    } catch (e, s) {
      Utils.reportError(e, s);
    }
    return false;
  }

  void toAudioPage() {
    int? id;
    int? extraId;
    PlaylistSource from = PlaylistSource.UP_ARCHIVE;
    if (isPlayAll) {
      id = args['mediaId'];
      extraId = sourceType.extraId;
      from = sourceType.playlistSource!;
    } else if (isUgc) {
      try {
        final ctr = Get.find<UgcIntroController>(tag: heroTag);
        id = ctr.videoDetail.value.ugcSeason?.id;
        if (id != null) {
          extraId = 8;
          from = PlaylistSource.MEDIA_LIST;
        }
      } catch (_) {}
    }
    AudioPage.toAudioPage(
      itemType: 1,
      id: id,
      oid: aid,
      subId: [cid.value],
      from: from,
      heroTag: _autoPlay.value ? heroTag : null,
      start: playedTime,
      audioUrl: audioUrl,
      extraId: extraId,
    );
  }

  Future<void> onDownload(BuildContext context) async {
    VideoDetailData? videoDetail;
    List<ugc.BaseEpisodeItem>? episodes;
    UgcIntroController? ugcIntroController;
    PgcInfoModel? pgcItem;
    if (isUgc) {
      try {
        ugcIntroController = Get.find<UgcIntroController>(tag: heroTag);
        videoDetail = ugcIntroController.videoDetail.value;
        if (videoDetail.ugcSeason?.sections case final sections?) {
          episodes = <ugc.BaseEpisodeItem>[];
          for (final i in sections) {
            if (i.episodes case final e?) {
              episodes.addAll(e);
            }
          }
        } else {
          episodes = videoDetail.pages;
        }
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('download ugc: $e\n\n$s');
        }
      }
    } else {
      try {
        pgcItem = Get.find<PgcIntroController>(tag: heroTag).pgcItem;
        episodes = pgcItem.episodes;
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('download pgc: $e\n\n$s');
        }
      }
    }
    if (episodes != null && episodes.isNotEmpty) {
      final downloadService = Get.find<DownloadService>();
      await downloadService.waitForInitialization;
      if (!context.mounted) {
        return;
      }
      final Set<int> cidSet = downloadService.downloadList
          .followedBy(downloadService.waitDownloadQueue)
          .map((e) => e.cid)
          .toSet();
      final index = episodes.indexWhere(
        (e) => e.cid == (seasonCid ?? cid.value),
      );

      showModalBottomSheet(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxWidth: min(640, context.mediaQueryShortestSide),
        ),
        builder: (context) {
          final maxChildSize =
              PlatformUtils.isMobile && !context.mediaQuerySize.isPortrait
              ? 1.0
              : 0.7;
          return DraggableScrollableSheet(
            snap: true,
            expand: false,
            minChildSize: 0,
            snapSizes: [maxChildSize],
            maxChildSize: maxChildSize,
            initialChildSize: maxChildSize,
            builder: (context, scrollController) => DownloadPanel(
              index: index,
              videoDetail: videoDetail,
              pgcItem: pgcItem,
              episodes: episodes!,
              scrollController: scrollController,
              videoDetailController: this,
              heroTag: heroTag,
              ugcIntroController: ugcIntroController,
              cidSet: cidSet,
            ),
          );
        },
      );
    }
  }

  void editPlayUrl() {
    String videoUrl = this.videoUrl ?? '';
    String audioUrl = this.audioUrl ?? '';
    Widget textField({
      required String label,
      required String initialValue,
      required ValueChanged<String> onChanged,
    }) => TextFormField(
      minLines: 1,
      maxLines: 3,
      onChanged: onChanged,
      initialValue: initialValue,
      decoration: InputDecoration(
        label: Text(label),
        border: const OutlineInputBorder(),
      ),
    );
    showDialog(
      context: Get.context!,
      builder: (context) => AlertDialog(
        constraints: Style.dialogFixedConstraints,
        title: const Text('播放地址'),
        content: Column(
          spacing: 20,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            textField(
              label: 'Video Url',
              initialValue: videoUrl,
              onChanged: (value) => videoUrl = value,
            ),
            textField(
              label: 'Audio Url',
              initialValue: audioUrl,
              onChanged: (value) => audioUrl = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
              this.videoUrl = videoUrl;
              this.audioUrl = audioUrl;
              playerInit();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> onCast() async {
    SmartDialog.showLoading();
    final res = await VideoHttp.tvPlayUrl(
      cid: cid.value,
      objectId: epId ?? aid,
      playurlType: epId != null ? 2 : 1,
      qn: currentVideoQa.value?.code,
    );
    SmartDialog.dismiss();
    if (res case Success(:final response)) {
      final first = response.durl?.firstOrNull;
      if (first == null || first.playUrls.isEmpty) {
        SmartDialog.showToast('不支持投屏');
        return;
      }
      final url = VideoUtils.getCdnUrl(first.playUrls);

      String? title;
      try {
        if (isUgc) {
          title = Get.find<UgcIntroController>(
            tag: heroTag,
          ).videoDetail.value.title;
        } else {
          title = Get.find<PgcIntroController>(
            tag: heroTag,
          ).videoDetail.value.title;
        }
      } catch (_) {}
      if (kDebugMode) {
        debugPrint(title);
      }
      Get.toNamed(
        '/dlna',
        parameters: {
          'url': url,
          'title': ?title,
        },
      );
    } else {
      res.toast();
    }
  }
}
