/// LibrePili — YouTube, stage 2: playing what the stage-1 data layer resolves.
///
/// Deliberately its own page rather than a branch inside the bilibili video
/// page. That page carries aid/bvid/cid, danmaku, the reply tree, history
/// reporting and the rest of a bilibili video everywhere; threading a second
/// platform through it would touch every one of those. A platform is its own
/// mode here, which is also where the interface is going.
library;

import 'dart:async';
import 'dart:io' show HttpException, Platform;

import 'package:PiliPlus/common/widgets/dialog/failure_report.dart';
import 'package:PiliPlus/models/common/subtitle_source_preference.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_publish.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/asr/model_guard.dart';
import 'package:PiliPlus/services/asr/model_store.dart'
    show AsrCancelToken, AsrCancelled;
import 'package:PiliPlus/services/background_transfer.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_choice.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_menu.dart';
import 'package:PiliPlus/pages/video/widgets/subtitle_gate.dart';
import 'package:PiliPlus/pages/video/widgets/translate_entry.dart';
import 'package:PiliPlus/pages/youtube/comments/yt_comments_controller.dart';
import 'package:PiliPlus/services/translate/caption_source.dart';
import 'package:PiliPlus/services/translate/translation_languages.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/services/translate/translation_track.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/local_history.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart'
    show shutdownTimerService;
import 'package:PiliPlus/services/youtube/invidious_instances.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_tracks.dart';
import 'package:PiliPlus/services/youtube/yt_download.dart';
import 'package:PiliPlus/services/youtube/yt_subscriptions.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/cdn_probe.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart' show AndroidHelper;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, BuildContext, WidgetsBinding;
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart' show SubtitleTrack;

enum YtPageStage { loading, ready, failed }

class YtVideoController extends GetxController
    with YtCommentsMixin
    implements SubtitleMenuHost {
  YtVideoController({required this.videoId, YouTubeVideoSource? source})
    : router = YtSourceRouter(source ?? YtDirectSource.create()) {
    play = YtSourceRouter(
      router.direct,
      // a source passed in (a test's) is the only one
      fallback: source == null ? YtInvidiousSource.shared : null,
      mode: source == null ? debugSourceMode : YtSourceMode.directOnly,
      health: source == null ? YtSourceRouter.sharedHealth : null,
    );
    YtInvidiousSource.log ??= (line) => EventLog.add('invidious', line);
    YtStreamRelay.log ??= (line) => EventLog.add('relay', line);
  }

  final String videoId;

  /// The direct source alone: related videos and comments, which only it
  /// answers.
  @override
  final YtSourceRouter router;

  /// The video, its streams and captions: the direct source, and the public
  /// Invidious instances when YouTube refuses this network.
  late final YtSourceRouter play;

  /// `--yt-source invidious|direct`: one source only.
  static YtSourceMode debugSourceMode = YtSourceMode.auto;

  /// Who served the video's detail: its captions are fetched from the same.
  YouTubeVideoSource? _detailSource;

  /// The viewer has been told once that YouTube refused or did not answer
  /// this network and the video came from Invidious.
  static bool _toldFallback = false;

  final plPlayerController = PlPlayerController.getInstance();

  final stage = YtPageStage.loading.obs;
  final detail = Rxn<YtVideoDetail>();
  final message = ''.obs;

  /// The failure was YouTube refusing this network (its bot wall): the page
  /// offers the browser and an Invidious instance instead.
  final blocked = false.obs;

  /// Looking for an Invidious instance that answers.
  final findingInvidious = false.obs;

  /// Caption tracks offered by YouTube, plus the one currently shown.
  final captions = <YtCaptionTrack>[].obs;
  final captionIndex = (-1).obs;

  /// Each track's text, by its URL: by list index, a 重载视频 that brought
  /// another list showed the old track's text under the new one's name.
  final _captionCache = <String, String>{};

  YtStreamPair? _streams;

  @override
  void onInit() {
    super.onInit();
    _historyWorkers = [
      ever<int>(plPlayerController.position, (sec) {
        if (!_ownsPlayer) return;
        _historySec = sec;
        final saved = _historySavedSec;
        if (saved == null || (sec - saved).abs() >= 10) _saveHistory();
      }),
      ever<PlayerStatus>(plPlayerController.playerStatus, (status) {
        if (!_ownsPlayer || status.isPlaying) return;
        _saveHistory(completed: status.isCompleted);
        if (status.isCompleted) _onCompleted();
      }),
    ];
    unawaited(load());
  }

  /// The video played to its end, as on the bilibili page: the sleep
  /// timer waiting for it (额外等待视频播放完毕) goes off, or 播放顺序 is
  /// followed — there is no list here to go on to — and full screen is left
  /// (自动退出全屏).
  void _onCompleted() {
    if (shutdownTimerService.isWaiting) {
      shutdownTimerService.handleWaiting();
    } else if (plPlayerController.playRepeat == PlayRepeat.singleCycle) {
      plPlayerController.play(repeat: true);
      return;
    }
    if (plPlayerController.autoExitFullscreen) {
      plPlayerController.triggerFullScreen(status: false);
      if (plPlayerController.controlsLock.value) {
        plPlayerController.onLockControl(false);
      }
    } else if (plPlayerController.controlsLock.value &&
        (!Platform.isAndroid || !AndroidHelper.isPipMode)) {
      plPlayerController.onLockControl(false);
    }
  }

  // ------------------------------------------- other pages over this one

  /// Whether this page's video was playing when another page opened over it.
  var _playingWhenCovered = false;

  /// Another page is over this one.
  var _covered = false;

  /// The first open, held back while the page was covered (see [load]).
  ({YtStreamPair pair, Duration? seekTo})? _openWhenUncovered;

  /// Another page opened over this one (the bilibili page's didPushNext):
  /// where it was is saved, and its video pauses.
  void onCovered() {
    _covered = true;
    _playingWhenCovered =
        _ownsPlayer && plPlayerController.playerStatus.isPlaying;
    if (!_ownsPlayer) return;
    _saveHistory();
    if (_playingWhenCovered) plPlayerController.pause();
  }

  /// The page is going: its video does not play on with no page to it.
  void onPopped() {
    if (_ownsPlayer && plPlayerController.playerStatus.isPlaying) {
      plPlayerController.pause();
    }
  }

  /// Back on top (didPopNext). A page that opened its own video on the
  /// player left that one on it: this video is opened again where it was,
  /// and a transcription that page's took the place of starts again (a
  /// parked translation goes on by itself once the player is this page's).
  Future<void> onUncovered() async {
    _covered = false;
    final held = _openWhenUncovered;
    _openWhenUncovered = null;
    if (isClosed || plPlayerController.isCloseAll) return;
    final play = _playingWhenCovered;
    _playingWhenCovered = false;
    final pair = _streams;
    if (held != null) {
      // the first open, as [load] would have made it
      await _open(held.pair, seekTo: held.seekTo);
    } else if (_ownsPlayer) {
      if (play) {
        plPlayerController.play();
      } else if (plPlayerController.playerStatus.isPlaying) {
        plPlayerController.pause();
      }
    } else if (pair != null && stage.value == YtPageStage.ready) {
      final sec = _historySec;
      await _open(
        pair,
        seekTo: sec == null ? null : Duration(seconds: sec),
        play: play,
      );
    }
    if (isClosed) return;
    _restartDisplaced();
    translation.retryAfterReturn();
  }

  /// See [VideoDetailController._restartDisplaced].
  void _restartDisplaced() {
    final session = asrSession.value;
    final wanted = _wantedOnDevice;
    if (session == null || !session.wasDisplaced || wanted == null) return;
    if (!_ownsPlayer || !canTranscribe) return;
    if (wanted == 'asr') {
      startAsr();
    } else {
      showTranslation(wanted);
    }
  }

  // ------------------------------------------------ local watch history

  List<Worker> _historyWorkers = const [];

  /// The position (s) last seen while this page had the player, and the one
  /// last saved to the local history.
  int? _historySec;
  int? _historySavedSec;

  /// Quitting the app (the window closed, the sleep timer): where this video
  /// is, saved first ([ShutdownTimerService.saveOpenVideo]).
  void saveHistoryOnExit() => _saveHistory();

  /// Saves where this video is to the local watch history, the same list the
  /// bilibili videos go to: every 10 s of playback, on a pause or the end,
  /// and on leaving.
  void _saveHistory({bool completed = false}) {
    final info = detail.value;
    final sec = _historySec;
    if (info == null || sec == null || sec <= 0) return;
    _historySavedSec = sec;
    final duration = info.duration.inMilliseconds;
    unawaited(
      LocalHistory.record(
        LocalWatchVisit(
          key: LocalHistory.ytKey(videoId),
          platform: LocalHistoryPlatform.yt,
          ytId: videoId,
          title: info.title,
          cover: info.thumbnails.lastOrNull?.url,
          author: info.author,
          channelId: info.channelId,
          partId: LocalHistory.ytPart,
        ),
        progress: completed && duration > 0 ? duration : sec * 1000,
        duration: duration,
      ),
    );
  }

  Future<void> load() async {
    stage.value = YtPageStage.loading;
    message.value = '';
    blocked.value = false;

    // the id goes into file names (the download's folder, the transcript's
    // scratch): only the 11 characters an id is made of
    if (!isYouTubeVideoId(videoId)) {
      stage.value = YtPageStage.failed;
      message.value = '无效的视频 ID';
      commentsBootstrapFailed(message.value);
      return;
    }

    final info = await play.run((s) => s.detail(videoId));
    if (isClosed) return;
    if (!info.ok || info.value == null) {
      _fail(info.verdict);
      return;
    }
    _detailSource = info.source;
    _noteSource(info.source);
    detail.value = info.value;
    _captionCache.clear();
    captions.value = info.value!.captionTracks;
    _refreshSubscribed();
    refreshFav();

    final streams = await play.run((s) => s.streams(videoId));
    if (isClosed) return;
    if (!streams.ok || streams.value == null) {
      _fail(streams.verdict);
      return;
    }
    _streams = streams.value;
    // where this device's history left it (YouTube has no other)
    final resume = LocalHistory.resumePoint(
      LocalHistory.ytKey(videoId),
      LocalHistory.ytPart,
    );
    final seekTo = resume == null ? null : Duration(milliseconds: resume);
    if (_covered) {
      // another page opened over this one while it loaded: the player is
      // that page's, and this opens when the page is back on top
      _openWhenUncovered = (pair: streams.value!, seekTo: seekTo);
    } else {
      await _open(streams.value!, seekTo: seekTo);
    }
    unawaited(_loadRelated());
  }

  /// [play]: whether it plays once open, in place of what [_open] decides.
  Future<void> _open(YtStreamPair pair, {Duration? seekTo, bool? play}) async {
    // The player is shared with the bilibili page. Sending bilibili's
    // Referer to googlevideo would tell Google which bilibili client is
    // watching — exactly the cross-site linkage this app exists to avoid:
    // a source marked `youtube` is opened, and handed over, without it.
    var videoUrl = _videoUrlOf(pair);
    var audioUrl = pair.audioUrl;
    if (debugRefuseFirstOpen && _ownSource == null) {
      // self-test: a URL YouTube refuses (403), as a fresh one once was
      debugRefuseFirstOpen = false;
      String spoil(String url) => url.replaceFirstMapped(
        RegExp(r'expire=(\d+)'),
        (m) => 'expire=${int.parse(m[1]!) + 1}',
      );
      videoUrl = spoil(videoUrl);
      audioUrl = spoil(audioUrl);
    }
    // an Invidious instance's streams through the app's relay, every hop
    // and address checked; googlevideo's from the direct source as they are
    final raw = (videoUrl, audioUrl);
    videoUrl = await _playable(pair, videoUrl);
    audioUrl = await _playable(pair, audioUrl);
    if (isClosed) return;
    final source = NetworkSource(
      videoSource: videoUrl,
      audioSource: audioUrl,
      youtube: true,
    );
    // the player's own autoplay calls a hook only the bilibili page sets:
    // here it never played by itself (2026-10-01, it sat paused with the
    // stream loaded). The first open follows 自动播放; a later one (another
    // quality, new URLs) plays on if it was playing
    final playAfter =
        play ??
        (_ownSource == null
            ? Pref.autoPlayEnable
            : plPlayerController.playerStatus.isPlaying);
    _ownSource = source;
    // mpv keeps an added subtitle track with the file it was added to: a new
    // one — a quality change, fresh streams — starts without the transcript
    // or translation that was on screen, which is only handed over again
    // when it has something new, and a finished or stopped one never is
    final generated = captionIndex.value == -2 ? _generatedTrack : null;
    // and a caption track the same: new streams after a long pause came
    // back without the captions on screen (2026-10-01)
    final caption = captionIndex.value;
    // The player is shared: the bilibili page sets its own, and a bilibili
    // page under this one left its hooks on it — a slow stream here would
    // have asked that page for bilibili streams to put in place of these.
    plPlayerController
      ..onSourceExpired = _renewStreams
      ..onStreamSlow = _streamSlow
      ..onStreamRoomy = _streamRoomy
      // one host per URL: a cut stream is new URLs, as a failover is
      ..onStreamCut = null
      ..onCdnFailover = _failover
      ..onReopen = _reopenHere
      ..onStepUpDropped = _dropStepUp;
    _heightCeiling ??= pair.video == null ? null : ytShortSide(pair.video!);
    openedHeight.value = pair.video == null ? null : ytShortSide(pair.video!);
    // what the buffer is sized by: without it mpv got the 4 MiB setting, 5 s
    // of a 1080p60 stream against the 30 s asked for, and every seek 10 s on
    // waited (2026-10-01) — or the bitrate of the bilibili video before
    plPlayerController.streamBitrate = _bitrateOf(pair);
    await plPlayerController.setDataSource(
      source,
      seekTo: seekTo,
      duration: detail.value?.duration,
      width: pair.video?.width,
      height: pair.video?.height,
      isVertical:
          (pair.video?.height ?? 0) > (pair.video?.width ?? 0) &&
          pair.video != null,
      // no aid/bvid/cid: nothing here is reported to bilibili
      videoType: null,
      onInit: () {
        _watchPlayback();
        stage.value = YtPageStage.ready;
        if (generated != null) {
          plPlayerController.setSubtitle(generated);
        } else if (caption >= 0) {
          _showCaption(caption);
        }
        // a loading gate up meanwhile pauses it again and plays on release
        if (playAfter) plPlayerController.play();
      },
    );
    if (!isClosed) {
      stage.value = YtPageStage.ready;
      // the notification and lock screen say what plays, and their buttons
      // reach it: only the bilibili pages gave the media session an item
      videoPlayerServiceHandler?.onVideoDetailChange(
        detail.value,
        0,
        _mediaTag,
      );
    }
    // what the relay still fetches for the streams played before is let go
    _relay?.retain([raw.$1, raw.$2]);
    _maybeAutoTranscribe();
  }

  /// The relay of this page's Invidious streams ([YtStreamRelay]): made at
  /// the first one, closed with the page.
  YtStreamRelay? _relay;

  /// [url], one of [pair]'s streams, as the player and this page's own
  /// probes ask for it: an Invidious instance's through [_relay] (user
  /// 2026-10-19: mpv followed its redirects unchecked, and looked the name
  /// up again itself); googlevideo's from the direct source as it is.
  Future<String> _playable(YtStreamPair pair, String url) async {
    if (pair.sourceId != YtInvidiousSource.shared.id) return url;
    return (_relay ??= YtStreamRelay()).wrap(url);
  }

  /// This page's entry in the media session, removed as it closes.
  late final String _mediaTag = 'yt:$videoId:${identityHashCode(this)}';

  /// The source captions come from: the one that listed them.
  YouTubeVideoSource get _captionsFrom => _detailSource ?? router.direct;

  /// The URLs Invidious resolved for this video are not to be handed out
  /// again: they are why new ones are asked for.
  void _forgetResolved() {
    if (_streams?.sourceId == YtInvidiousSource.shared.id) {
      YtInvidiousSource.shared.forget(videoId);
    }
  }

  /// In the event log which source served the video, and once on screen: a
  /// switch nobody sees is how a broken client stays broken.
  void _noteSource(YouTubeVideoSource? source) {
    if (source == null || source.id == router.direct.id) return;
    EventLog.add(
      'youtube',
      '$videoId from ${source.label}: '
          '${play.mode == YtSourceMode.fallbackOnly ? 'the only source asked' : play.activeOverrideReason ?? 'the direct source was not asked'}',
    );
    if (!_toldFallback) {
      _toldFallback = true;
      SmartDialog.showToast('$_whyFallback改由 ${source.label} 提供');
    }
  }

  /// Why the video is on the fallback, as the toast and a failure put it:
  /// YouTube not answering is not YouTube refusing this network.
  String get _whyFallback => play.mode == YtSourceMode.fallbackOnly
      ? ''
      : play.fellThroughFor == YtCause.transient
      ? 'YouTube 暂时连不上，'
      : 'YouTube 拒绝了当前网络，';

  /// The UI's reading of a verdict. Kept here rather than in the data layer,
  /// which stays free of presentation — and the diagnostic signal is appended
  /// so a report says which of the four causes fired.
  String _messageFor(YtVerdict verdict) => switch (verdict.cause) {
    // the fallback could not serve either: say so, not 网络错误
    YtCause.transient when verdict.signal.startsWith('invidious:') =>
      '$_whyFallback备用线路（Invidious）现在也都不可用，可稍后重试，或在浏览器中打开',
    YtCause.ok => '',
    YtCause.contentUnavailable => '该视频无法播放（已删除、私有、年龄限制或地区限制）',
    YtCause.ipBlocked => 'YouTube 暂时拒绝了当前网络，可稍后重试，或在浏览器、Invidious 中打开',
    YtCause.transient => '网络错误，请重试',
    YtCause.clientBroken => 'YouTube 接口已变化，应用需要更新（${verdict.signal}）',
  };

  void _fail(YtVerdict verdict) {
    if (isClosed) return;
    stage.value = YtPageStage.failed;
    message.value = _messageFor(verdict);
    blocked.value =
        verdict.cause == YtCause.ipBlocked ||
        verdict.signal.startsWith('invidious:');
    // the related request, which carries the comments' token, is not made
    // when the video fails to load: the 评论 tab waited for it for ever
    commentsBootstrapFailed(message.value);
    // in the event log too: a page that failed said nothing there
    EventLog.add('failure', 'youtube $videoId: $verdict');
    if (kDebugMode) debugPrint('youtube: $verdict');
  }

  /// The viewer picked a subtitle themselves — off, or a caption track. From
  /// then on nothing automatic changes which one is shown: not a transcript
  /// or translation arriving, finishing or failing. Turning them off does not
  /// stop either; picking one from the menu shows it as it stands.
  var _viewerChose = false;

  /// Shows a caption track, or hides captions when [index] is negative: the
  /// viewer's choice (see [_viewerChose]).
  Future<void> setCaption(int index) {
    _viewerChose = true;
    _wantedOnDevice = null;
    return _showCaption(index);
  }

  /// Bumped by every change of what subtitle is shown: a caption still
  /// being fetched when another is picked (or a transcript or translation
  /// put up) is not put back over it.
  var _captionTurn = 0;

  Future<void> _showCaption(int index) async {
    final player = plPlayerController.videoPlayerController;
    if (player == null) return;
    final turn = ++_captionTurn;
    if (index < 0 || index >= captions.length) {
      await plPlayerController.setSubtitle(SubtitleTrack.no());
      captionIndex.value = -1;
      return;
    }

    final track = captions[index];
    var content = _captionCache[track.baseUrl];
    if (content == null) {
      final result = await _captionsFrom.captionContent(track);
      if (!result.ok || result.value == null) {
        message.value = _messageFor(result.verdict);
        return;
      }
      // YouTube hands back WebVTT already; nothing to convert
      content = result.value!;
      _captionCache[track.baseUrl] = content;
    }
    if (isClosed || turn != _captionTurn) return;
    await plPlayerController.setSubtitle(
      SubtitleTrack(
        'memory://$content',
        track.name.isEmpty ? track.languageCode : track.name,
        track.languageCode,
        uri: true,
      ),
    );
    captionIndex.value = index;
  }

  // -------------------------------------------------------- page metadata

  /// Publish date, exact view count, channel avatar and subscriber count.
  ///
  /// These used to cost a separate channel `browse` request, made after the
  /// video was already playing. They are all in the `next` response that the
  /// related shelf fetches anyway — so the request is gone, and the page
  /// gained the publish date it never had.
  final extra = Rxn<YtVideoExtra>();

  // ------------------------------------------------------------- quality

  /// Cap on the shorter side, as [YtFormatPreference.maxHeight] means it.
  /// 0 is "no cap".
  final maxHeight = 1080.obs;

  /// The short side of the video stream open now, for the quality button:
  /// the cap read 1080P on a video that has 720P at most.
  final openedHeight = RxnInt();

  /// The heights actually on offer for this video, best first: each one a
  /// cap the selection reaches (it picks the height before the codec), by
  /// the short side as the cap is — a portrait 1080x1920 is 1080P.
  List<int> get availableHeights {
    final heights = <int>{
      for (final format in detail.value?.formats ?? const <YtFormat>[])
        if (format.isVideo && format.isPlayable && ytShortSide(format) > 0)
          ytShortSide(format),
    }.toList()..sort((a, b) => b.compareTo(a));
    return heights;
  }

  /// Bumped by every pick: only the latest one opens, or puts the cap back.
  var _heightPick = 0;

  /// The cap of the streams open, from before the picks still out: what a
  /// failed pick puts back (a pick made while another was out had that
  /// one's cap as its "before", which never opened).
  ({int cap, bool chosen})? _capBeforePicks;

  Future<void> setMaxHeight(int height) async {
    if (maxHeight.value == height) return;
    final pick = ++_heightPick;
    _capBeforePicks ??= (cap: maxHeight.value, chosen: _heightChosen);
    // the viewer's: nothing changes it by itself from now on
    _heightChosen = true;
    maxHeight.value = height;
    // not mpv's own position: it reads 0 while a source is opening
    final position = plPlayerController.resumePosition;
    final streams = await play.run(
      (s) => s.streams(
        videoId,
        preference: YtFormatPreference(maxHeight: height),
      ),
    );
    if (isClosed) return;
    // another height was picked meanwhile: that pick is the one that opens
    // (or puts the cap back), not this older one
    if (pick != _heightPick) return;
    final before = _capBeforePicks!;
    _capBeforePicks = null;
    if (streams.ok && streams.value != null) {
      _streams = streams.value;
      await _open(streams.value!, seekTo: position);
    } else if (stage.value != YtPageStage.ready) {
      _fail(streams.verdict);
    } else {
      // the video playing now goes on: a failed pick put the error panel
      // in place of a player that worked. The cap stays as it was
      maxHeight.value = before.cap;
      _heightChosen = before.chosen;
      SmartDialog.showToast('切换画质失败：${_messageFor(streams.verdict)}');
      EventLog.add('failure', 'youtube $videoId quality: ${streams.verdict}');
    }
  }

  /// The stream URLs expired (a long pause): new ones, at the height asked
  /// for, opened at [at] — the same as a quality change does — playing as
  /// the player says (a paused video stays paused, and a pause made during
  /// the fetch holds: see [PlPlayerController.renewalPlays]).
  Future<void> _renewStreams(Duration at) async {
    _forgetResolved();
    final streams = await play.run(
      (s) => s.streams(
        videoId,
        preference: YtFormatPreference(maxHeight: maxHeight.value),
      ),
    );
    if (isClosed) return;
    if (streams.ok && streams.value != null) {
      _streams = streams.value;
      await _open(
        streams.value!,
        seekTo: at,
        play: plPlayerController.renewalPlays,
      );
    } else {
      _fail(streams.verdict);
    }
  }

  /// A single muxed stream for a TV: an adaptive video-only URL would cast
  /// without sound.
  String? get castUrl {
    final formats = detail.value?.formats ?? const <YtFormat>[];
    final muxed = [
      for (final format in formats)
        if (format.isPlayable &&
            format.mimeType.contains('video/') &&
            format.mimeType.contains('mp4a'))
          format,
    ]..sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
    return muxed.isEmpty ? null : muxed.first.url;
  }

  // ------------------------------------------------------------ subscription

  /// Followed locally; YouTube is never told. There is no account here.
  // ------------------------------------------------------------- download

  /// Downloading is its own path rather than the bilibili download queue:
  /// that queue is built around an on-disk entry with aid/cid, danmaku and a
  /// cover, none of which describes a YouTube video. What it shares is the
  /// remuxer, so the result is the same thing — one finished mp4.
  final downloading = false.obs;
  YtDownloadToken? _downloadToken;

  Future<void> download(BuildContext context) async {
    if (downloading.value) {
      _downloadToken?.cancel();
      return;
    }
    var pair = _streams;
    if (pair == null) {
      SmartDialog.showToast('还没有可下载的流');
      return;
    }
    final token = _downloadToken = YtDownloadToken();
    downloading.value = true;
    SmartDialog.showLoading(
      msg: '准备下载',
      onDismiss: token.cancel,
    );
    try {
      if (!YtDownloader.remuxable(pair)) {
        // what plays (VP9 above 1080p, say) is WebM, which the remuxer cannot
        // read: an MP4 pair of its own, as close to the cap as MP4 goes
        final mp4 = await play.run(
          (s) => s.streams(
            videoId,
            preference: YtFormatPreference.mp4Download(maxHeight.value),
          ),
        );
        if (token.isCancelled) throw const YtDownloadCancelled();
        if (!mp4.ok || mp4.value == null) {
          throw mp4.verdict.signal.endsWith('no-playable-pair')
              ? const YtDownloadNotMp4()
              : _messageFor(mp4.verdict);
        }
        pair = mp4.value!;
      }
      String? shownMsg;
      String? shownStage;
      DateTime? shownAt;
      void showProgress(double fraction, String stage) {
        if (isClosed) return;
        // every received chunk rebuilt the overlay: only a new figure, and
        // no more often than a few times a second, except a new stage
        final msg =
            '$stage ${(fraction * 100).clamp(0, 100).toStringAsFixed(0)}%';
        final now = DateTime.now();
        if (msg == shownMsg ||
            (stage == shownStage &&
                shownAt != null &&
                now.difference(shownAt!) < const Duration(milliseconds: 250))) {
          return;
        }
        shownMsg = msg;
        shownStage = stage;
        shownAt = now;
        SmartDialog.showLoading(msg: msg, onDismiss: token.cancel);
      }

      final title = detail.value?.title ?? videoId;
      final streams = pair;
      // the formats' own sizes, which the job's notification counts
      // against; without one, bitrate × duration. None at all: no job, the
      // download runs as it did before
      int sizeOf(YtFormat? f) {
        if (f == null) return 0;
        final length = f.contentLength;
        if (length != null && length > 0) return length;
        final rate = f.averageBitrate ?? f.bitrate;
        final ms = f.approxDurationMs ?? 0;
        return rate > 0 && ms > 0 ? rate * ms ~/ 8000 : 0;
      }

      final bytes =
          sizeOf(streams.video) +
          (streams.videoUrl == streams.audioUrl ? 0 : sizeOf(streams.audio));
      if (bytes <= 0 && Platform.isAndroid) {
        EventLog.add(
          'transfer',
          'no background job for "$title": size unknown, downloading '
              'in-process',
        );
      }
      // inside a user-initiated job, as model downloads are: on Android 15
      // the network goes ~5 s after the screen locks (oct-pass3-D8)
      final file = await BackgroundTransfer.instance.run(
        title: '下载 $title',
        bytes: bytes,
        token: _YtJobToken(token),
        body: (keepAlive) async {
          try {
            return await YtDownloader.download(
              pair: streams,
              videoId: videoId,
              title: title,
              token: token,
              onProgress: (fraction, stage) {
                keepAlive((
                  label: 'YouTube 视频',
                  received: (fraction.clamp(0, 1) * bytes).round(),
                  total: bytes,
                  verifying: false,
                ));
                showProgress(fraction, stage);
              },
            );
          } on YtDownloadCancelled {
            // the job ends as cancelled, not as failed
            throw const AsrCancelled();
          }
        },
      );
      SmartDialog.dismiss(status: SmartStatus.loading);
      SmartDialog.showToast('已保存到 $file');
    } on YtDownloadCancelled {
      SmartDialog.dismiss(status: SmartStatus.loading);
      SmartDialog.showToast('已取消下载');
    } on AsrCancelled {
      SmartDialog.dismiss(status: SmartStatus.loading);
      SmartDialog.showToast('已取消下载');
    } on YtDownloadNotMp4 catch (e) {
      SmartDialog.dismiss(status: SmartStatus.loading);
      SmartDialog.showToast('$e');
    } catch (e) {
      SmartDialog.dismiss(status: SmartStatus.loading);
      // not the URL: googlevideo's carries the viewer's address and a
      // signature, and HttpException's words quote it whole
      final why = e is HttpException ? e.message : EventLog.withoutQuery('$e');
      SmartDialog.showToast('下载失败: $why');
    } finally {
      downloading.value = false;
      _downloadToken = null;
    }
  }

  // ----------------------------------------------------------- favourites

  /// Favourites live in the same local folders bilibili videos do — there is
  /// no account on either side here, and one 收藏夹 that holds both is the
  /// point of a single app rather than two behind one icon.
  final isFav = false.obs;

  String get favKey => LocalLibrary.ytFavKey(videoId);

  Map<String, dynamic> get favData {
    final video = detail.value;
    return LocalLibrary.buildYtFavData(
      videoId: videoId,
      title: video?.title ?? videoId,
      cover: video?.thumbnails.lastOrNull?.url,
      durationSec: video?.duration.inSeconds,
      author: video?.author,
      channelId: video?.channelId,
    );
  }

  void refreshFav() => isFav.value = LocalLibrary.isFav(favKey);

  final subscribed = false.obs;

  void _refreshSubscribed() {
    subscribed.value = YtSubscriptions.isFollowed(detail.value?.channelId);
  }

  Future<void> toggleSubscribe() async {
    final info = detail.value;
    final channelId = info?.channelId;
    if (info == null || channelId == null || channelId.isEmpty) return;
    final now = await YtSubscriptions.toggle(
      channelId,
      name: info.author,
      // the channel's own avatar, from the watch page's `next` response:
      // the video's thumbnail was stored as it, and the 订阅 list showed
      // the video's picture as the channel. None yet: none kept
      avatar: extra.value?.ownerAvatar?.url,
    );
    subscribed.value = now;
    SmartDialog.showToast(now ? '已订阅 ${info.author}' : '已取消订阅');
  }

  // ------------------------------------------------ related and comments

  final related = <YtSearchItem>[].obs;

  /// Why the related shelf is not here, when it is not — and whether it is
  /// still on its way. Without these the shelf said 「暂无相关视频」 while
  /// loading and again when the request had failed: three states, one
  /// sentence.
  final relatedError = RxnString();
  final _relatedDone = false.obs;

  bool get relatedPending => related.isEmpty && !_relatedDone.value;

  Future<void> reloadRelated() {
    relatedError.value = null;
    _relatedDone.value = false;
    return _loadRelated();
  }

  Future<void> _loadRelated() async {
    final result = await router.run(
      (s) => (s as YtDirectSource).related(videoId),
    );
    if (isClosed) return;
    if (!result.ok || result.value == null) {
      _relatedDone.value = true;
      relatedError.value = _messageFor(result.verdict);
      // the comments' token comes with it: their tab says so too, and its
      // 重试 asks again (see [retryComments])
      commentsBootstrapFailed(relatedError.value!);
      return;
    }
    _relatedDone.value = true;
    relatedError.value = null;
    related.value = result.value!.related;
    commentsToken = result.value!.commentsToken;
    final info = result.value!.extra;
    if (!info.isEmpty) extra.value = info;
    // Comments start with the video rather than with the tab: the bilibili
    // page has them ready by the time you scroll to them, and a list that
    // begins loading when you look at it always looks slow.
    //
    // It has to be here, not beside the call above: the token that fetches
    // them only exists once this response has landed. Starting earlier
    // found no token, did nothing, and marked the comments as started — so
    // opening the tab never loaded them at all.
    ensureCommentsStarted();
  }

  // the comment section itself is [YtCommentsMixin]'s, shared with a post's

  @override
  String get commentsKey => 'yt:$videoId';

  @override
  String commentsMessageFor(YtVerdict verdict) => _messageFor(verdict);

  @override
  Future<YtRoutedResult<String?>> fetchCommentsBootstrap() async {
    final result = await router.run(
      (s) => (s as YtDirectSource).related(videoId),
    );
    return YtRoutedResult(
      result.ok && result.value != null
          ? YtResult.ok(result.value!.commentsToken)
          : YtResult.failed(result.verdict),
      result.source,
    );
  }

  @override
  Future<YtResult<YtPage<YtComment>>> fetchCommentsPage(
    YouTubeVideoSource source,
    String token,
  ) => (source as YtDirectSource).comments(token);

  // ------------------------------------------------- on-device transcription

  /// A YouTube video that carries no captions of its own is exactly what the
  /// recogniser is for — and, since most of what has none here is in another
  /// language, the case the "外语视频自动转录" setting was written around.
  final asrSession = Rxn<AsrSession>();

  /// See [VideoDetailController.asrPending]: transcription is a peer of the
  /// video stream, so an automatic run holds the page in loading until its
  /// first cues exist.
  final asrPending = false.obs;
  Timer? _asrGate;
  Timer? _asrRefresh;
  Worker? _asrStateWorker;
  StreamSubscription<void>? _asrCueSub;

  /// See [VideoDetailController.translation]. This page has no track list,
  /// so while a translation runs it is the subtitle shown, in place of the
  /// transcript; the dual display (设置 → 双语字幕) keeps both on screen.
  late final translation = TranslationTrack(
    // the player counts whole seconds
    position: () => plPlayerController.position.value.toDouble(),
    ownsPlayer: () => _ownsPlayer,
    onPublish: _publishTranslation,
    onReady: _closeAsrGate,
    onFailed: (message) {
      // not over another video's page (see VideoDetailController)
      if (_ownsPlayer) FailureReport.show('翻译失败', message);
      _showUntranslated();
    },
  );

  /// The caption track being translated, when it is the video's own.
  int? _translatedCaption;

  /// The player is one for the whole app (see
  /// [PlPlayerController.getInstance]): with another page opened over this
  /// one it is playing that page's video, and this page's subtitles do not
  /// go on it. A translation replaced by that page's own is the case that
  /// reaches here, and this page's transcript refresh keeps running under it.
  ///
  /// Owned while the player still has the very source this page gave it: the
  /// same video opened on another page has the same URL, but not the same
  /// source object.
  bool get _ownsPlayer {
    final own = _ownSource;
    return own != null && identical(plPlayerController.dataSource, own);
  }

  /// The source this page last handed the player: its token of ownership.
  DataSource? _ownSource;

  /// Back to what was there before the translation took its place: the
  /// caption track it was made from, or the transcript. Only while the
  /// translation is still what is shown — the viewer may have turned
  /// subtitles off or picked a track meanwhile.
  void _showUntranslated() {
    if (!_ownsPlayer || _viewerChose || captionIndex.value != -2) return;
    if (_translatedCaption case final index?) {
      _showCaption(index);
    } else {
      _publishAsrSubtitle(isFinal: true);
    }
  }

  var _gateOnTranslation = false;
  var _translationRequested = false;

  /// Bumped by [stopTranslation], so a start waiting on a fetch can tell.
  var _translationStops = 0;

  /// See [VideoDetailController._openApplied]; here a stream refresh is
  /// what comes back through [_maybeAutoTranscribe].
  var _openApplied = false;

  /// How many automatic checks this page has had: the first is the page
  /// opening, and only it may open the loading gate (see
  /// [VideoDetailController._pastOpening]). Later ones come from a stream
  /// refresh, with playback under way.
  var _autoChecks = 0;

  /// See [VideoDetailController._shownAt].
  int? _shownAt;

  /// The loading gate has closed once: the player has been released.
  var _released = false;

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

  /// A translation is what is on screen: running, or finished.
  bool get _showingTranslation {
    final state = translation.session.value?.state.value.stage;
    return state != null && state != TranslationStage.failed;
  }

  /// The audio stream on its own: handing the recogniser the video as well
  /// would download it a second time for nothing.
  ///
  /// An Invidious instance's through the relay, as the player has it
  /// ([_playable]); none while the relay is not running, rather than the
  /// instance's URL unchecked.
  String? get asrSource {
    final pair = _streams;
    if (pair == null) return null;
    if (pair.sourceId != YtInvidiousSource.shared.id) return pair.audioUrl;
    return _relay?.wrapNow(pair.audioUrl);
  }

  @override
  bool get canTranscribe => asrSource?.isNotEmpty == true;

  Future<void> startAsr({bool auto = false}) async {
    final source = asrSource;
    if (source == null || source.isEmpty) {
      SmartDialog.showToast('没有可转录的音频');
      return;
    }
    await stopAsr();
    // see [VideoDetailController.startAsr]
    if (isClosed) return;
    if (auto) _openAsrGate();
    // no Referer, no UA: googlevideo does not need them and sending
    // bilibili's would link the two sites (see [_open])
    final session = await AsrService.to.start(
      key: 'yt:$videoId',
      source: source,
      // see [VideoDetailController.startAsr]; itag 140/251 are indexed and
      // start from a position
      playhead: () =>
          _ownsPlayer ? plPlayerController.position.value.toDouble() : null,
      duration: () => _ownsPlayer && plPlayerController.duration.value > 0
          ? plPlayerController.duration.value.toDouble()
          : null,
      refresh: ({bool expired = false}) async {
        final now = asrSource;
        return now == null || now.isEmpty ? null : now;
      },
      cache: SubtitleCacheKey.youtube(videoId),
    );
    // see [VideoDetailController.startAsr]
    if (isClosed) {
      AsrService.to.stop(only: session);
      return;
    }
    asrSession.value = session;
    _asrCueSub = session.cues.listen((_) {
      if (!_gateOnTranslation) _closeAsrGate();
      _publishAtNewPosition(session);
    });
    _asrRefresh = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _publishAsrSubtitle(),
    );
    _asrStateWorker = ever(session.state, (state) {
      // see VideoDetailController: a translation asked for does not wait
      // for the language, and one under way goes on whatever it turns out
      // to be
      _maybeTranslate(session, auto: auto);
      switch (state.stage) {
        case AsrStage.done:
          if (!_gateOnTranslation) _closeAsrGate();
          _publishAsrSubtitle(isFinal: true);
        case AsrStage.failed:
          _closeAsrGate();
          _stopTranscriptTranslation();
          // only errors interrupt; progress lives in the subtitle menu. Not
          // over another video's page (see VideoDetailController)
          if (_ownsPlayer) {
            FailureReport.show('转录失败', state.message ?? '未知原因');
          }
        case AsrStage.idle:
          _closeAsrGate();
          _stopTranscriptTranslation();
        case _:
          break;
      }
    });
  }

  void _openAsrGate() {
    // past the opening, playback has started (see [_autoChecks])
    if (_autoChecks > 1 || _released || _playbackUnderway) return;
    _asrGate?.cancel();
    if (!asrPending.value) {
      _startGateSkipTimer();
      EventLog.add('gate', 'loading gate up: waiting for the subtitles');
    }
    asrPending.value = true;
    _asrGate = Timer(const Duration(seconds: 30), () {
      EventLog.add('gate', 'loading gate reached its 30 s cap');
      _closeAsrGate();
    });
    _holdPlayback();
  }

  void _closeAsrGate() {
    _asrGate?.cancel();
    _asrGate = null;
    _stopGateSkipTimer();
    // nothing waits for the translation once the gate is down
    final onTranslation = _gateOnTranslation;
    _gateOnTranslation = false;
    if (asrPending.value) {
      final opened = gateOpenedAt;
      EventLog.add(
        'gate',
        'loading gate down'
            '${opened == null ? '' : ' after ${(DateTime.now().difference(opened).inMilliseconds / 1000).toStringAsFixed(1)} s'}'
            '${onTranslation ? ' (was waiting for the translation too)' : ''}',
      );
      asrPending.value = false;
      // the player has been released: the gate had its one chance
      _released = true;
      _resumeHeldPlayback();
    }
  }

  /// See [VideoDetailController.asrGateSkippable]. The loading gate has been up for [subtitleGateSkipAfter]: the page
  /// offers 先播放视频 (see [skipSubtitleGate]).
  final asrGateSkippable = false.obs;
  Timer? _gateSkipTimer;

  /// When the gate went up, and when it offered to be skipped: for the
  /// self-test's loading probe.
  DateTime? gateOpenedAt;
  DateTime? gateSkippableAt;

  /// 先播放视频: the viewer would rather watch now. Playback goes on
  /// without the subtitles, which keep being made and come in when ready.
  void skipSubtitleGate() {
    if (!asrPending.value) return;
    EventLog.add('gate', 'viewer chose 先播放视频');
    _closeAsrGate();
  }

  void _startGateSkipTimer() {
    _gateSkipTimer?.cancel();
    gateOpenedAt = DateTime.now();
    gateSkippableAt = null;
    _gateSkipTimer = Timer(subtitleGateSkipAfter, () {
      if (!asrPending.value) return;
      gateSkippableAt = DateTime.now();
      asrGateSkippable.value = true;
    });
  }

  void _stopGateSkipTimer() {
    _gateSkipTimer?.cancel();
    _gateSkipTimer = null;
    asrGateSkippable.value = false;
  }

  /// See [VideoDetailController._playOnRelease]. Here the gate opens once the
  /// stream is loaded, with its autoplay already started or on its way.
  var _playOnRelease = false;
  Worker? _gatePlaybackWorker;

  /// See [VideoDetailController._holdPlayback].
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

  /// See [VideoDetailController._releaseHold].
  void _releaseHold() {
    _playOnRelease = false;
    _gatePlaybackWorker?.dispose();
    _gatePlaybackWorker = null;
    _stopWaitingForReturn();
  }

  /// See [VideoDetailController._returnListener].
  AppLifecycleListener? _returnListener;

  void _stopWaitingForReturn() {
    _returnListener?.dispose();
    _returnListener = null;
  }

  /// See [VideoDetailController._resumeHeldPlayback]: a gate let go with the
  /// app away waits for it to be back in view.
  void _resumeHeldPlayback() {
    if (!_playOnRelease || asrPending.value) return;
    if (isClosed || !_ownsPlayer) {
      _releaseHold();
      return;
    }
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
    plPlayerController.play();
  }

  /// See [VideoDetailController.stopAsr]: a translation of the video's own
  /// captions goes on unless the page is [leaving].
  Future<void> stopAsr({bool leaving = false}) async {
    _closeAsrGate();
    _gateOnTranslation = false;
    _translationRequested = false;
    final stopsTranslation = leaving || _translatedCaption == null;
    // the transcript's listeners go before anything is awaited: the
    // translation can take seconds to release its model, and meanwhile the
    // refresh would put the old transcript back on screen and a state event
    // would start translating it again
    _asrRefresh?.cancel();
    _asrRefresh = null;
    _asrStateWorker?.dispose();
    _asrStateWorker = null;
    // cancelled at once, awaited after: no event arrives past the call
    final cueSub = _asrCueSub?.cancel();
    _asrCueSub = null;
    // and let go of: another page may start a transcription meanwhile,
    // which is not this one to stop
    final session = asrSession.value;
    asrSession.value = null;
    _asrPublished = false;
    if (stopsTranslation) {
      _translatedCaption = null;
      // what was translated stays on screen, without its waiting marks,
      // unless the page is going away
      await translation.stop(finish: !leaving);
    }
    await cueSub;
    if (session != null && Get.isRegistered<AsrService>()) {
      await AsrService.to.stop(only: session);
    }
  }

  /// Shows what has been recognised so far. The page has no track list of its
  /// own to insert into, so the transcript simply becomes the shown subtitle.
  /// How far the published track reaches; see [shouldPublishAsr] and
  /// [PublishedReach].
  PublishedReach _asrPublishedReach = PublishedReach.none;

  /// This run's transcript has been put on screen once.
  var _asrPublished = false;

  /// See [VideoDetailController._publishAtNewPosition].
  void _publishAtNewPosition(AsrSession session) {
    if (!_asrPublished) return;
    final position = plPlayerController.position.value.toDouble();
    if (_asrPublishedReach.at(position) > position) return;
    final span = coveredSpanOf(session.transcript.covered, position);
    if (span.from <= position && span.to > position) {
      _publishAsrSubtitle(isFinal: true);
    }
  }

  void _publishAsrSubtitle({bool isFinal = false}) {
    final session = asrSession.value;
    final player = plPlayerController.videoPlayerController;
    if (session == null || player == null || session.cues.isEmpty) return;
    if (!_ownsPlayer) return;
    if (_wantedOnDevice == 'asr') {
      // picked from the menu: shown whatever else is going on, and kept
      // current until something else is picked
      final shown = onDeviceShown == 'asr';
      if (!shown) isFinal = true;
    } else {
      if (_viewerChose || _wantedOnDevice != null) return;
      // one subtitle at a time here, and a translation takes the place
      if (_showingTranslation) return;
      // shown the first time; after that refreshed only while it is still
      // what is shown — the viewer may have turned subtitles off or picked a
      // track
      if (_asrPublished && captionIndex.value != -2) return;
    }
    // each of these reloads the track and blinks whatever is on screen
    // the player counts whole seconds
    final position = plPlayerController.position.value;
    if (!shouldPublishAsr(
      publishedTo: Duration(
        milliseconds: (_asrPublishedReach.at(position.toDouble()) * 1000)
            .round(),
      ),
      position: Duration(seconds: position),
      isFirst: !_asrPublished,
      isFinal: isFinal,
    )) {
      return;
    }
    _asrPublishedReach = PublishedReach.of(
      session.cues,
      session.transcript.covered,
    );
    _showGeneratedTrack(
      SubtitleTrack(
        'memory://${session.forDisplay(session.cues).toVtt()}',
        onDeviceLabel(null),
        'asr',
        uri: true,
      ),
    );
    _asrPublished = true;
  }

  /// The transcript or translation last handed to the player, for [_open] to
  /// hand the next file.
  SubtitleTrack? _generatedTrack;

  void _showGeneratedTrack(SubtitleTrack track) {
    _captionTurn++;
    _generatedTrack = track;
    plPlayerController.setSubtitle(track);
    captionIndex.value = -2;
  }

  /// See [VideoDetailController._maybeTranslate].
  void _maybeTranslate(AsrSession session, {required bool auto}) {
    if (translation.isActive || isClosed) return;
    if (!Get.isRegistered<TranslationService>()) return;
    // see VideoDetailController: the switch or the menu asked for it
    if (!_translationRequested) return;
    // a transcript's translation, not a caption track's
    _translatedCaption = null;
    if (auto && asrPending.value) _gateOnTranslation = true;
    _startUnawaited(translation.start(session, into: _requestedInto));
  }

  /// See [VideoDetailController._startUnawaited].
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

  /// See [VideoDetailController._stopTranscriptTranslation]. The transcript
  /// goes back on screen if the translation was what was shown.
  Future<void> _stopTranscriptTranslation() async {
    // one that has finished or failed is left for the menu to show
    final ended = translation.session.value != null && !translation.isRunning;
    if (_translatedCaption != null || !translation.isActive || ended) return;
    final stopped = translation.stop();
    _stopGatingOnTranslation();
    await stopped;
    if (!isClosed && captionIndex.value == -2) _showUntranslated();
  }

  /// See [VideoDetailController._stopGatingOnTranslation].
  void _stopGatingOnTranslation() {
    if (!_gateOnTranslation) return;
    _gateOnTranslation = false;
    if (asrSession.value?.cues.isNotEmpty ?? false) _closeAsrGate();
  }

  /// See [VideoDetailController.captionToTranslate].
  int? get captionToTranslate => captionToTranslateInto(null);

  /// See [VideoDetailController.captionToTranslateInto].
  @override
  int? captionToTranslateInto(String? into) =>
      captionToTranslateFor(platformTracks, into ?? AsrService.appLanguage);

  /// See [VideoDetailController.platformTracks]. YouTube lists no machine
  /// translations: its translated captions are asked for per language, not
  /// offered as tracks.
  ///
  /// With dubbed audio, only the automatic track in the original audio's
  /// language is the speech; the others are the dubs' (see yt_tracks.dart).
  @override
  List<PlatformTrack> get platformTracks {
    final original = ytOriginalAudioLanguage(
      detail.value?.formats ?? const [],
    );
    return [
      for (final c in captions)
        (language: c.languageCode, kind: ytTrackKind(c, original)),
    ];
  }

  /// Whether the remembered language can be made without downloading
  /// anything: the model is here, or it is 繁体中文 made by conversion alone
  /// (oct-pass1-D2, see [TranslateEntry.needsNoModel]).
  bool get _translateReady {
    if (!Get.isRegistered<TranslationService>()) return false;
    if (TranslationService.to.readyToStart) return true;
    final code = SubtitleChoice.codeOf(Pref.subtitleChoice);
    return code != null &&
        TranslationService.supported &&
        TranslateEntry.needsNoModel(this, code);
  }

  /// See [VideoDetailController._openPlan].
  OpenPlan _openPlan() => decideOnOpen(
    choice: Pref.subtitleChoice,
    tracks: platformTracks,
    source: Pref.subtitleSource,
    canTranscribe: canTranscribe,
    asrReady: Get.isRegistered<AsrService>() && AsrService.to.modelsReady,
    translateReady: _translateReady,
  );

  /// See [VideoDetailController.planFor].
  @override
  OpenPlan planFor(String code, {SubtitleSourcePreference? via}) =>
      decideOnOpen(
        choice: SubtitleChoice.fromCode(code),
        tracks: platformTracks,
        source: via ?? Pref.subtitleSource,
        canTranscribe: canTranscribe,
        asrReady: true,
        translateReady: TranslationService.supported,
      );

  /// See [VideoDetailController._startOnDevice].
  Future<void> _startOnDevice(String code, {required bool auto}) async {
    _wantedOnDevice = code;
    if (code == 'asr') {
      await startAsr(auto: auto);
      return;
    }
    final into = _requestedInto = code == AsrService.appLanguage ? null : code;
    if (captionToTranslateInto(code) case final index?) {
      if (auto) {
        _openAsrGate();
        // past the opening no gate opens, and nothing is to wait for this
        if (asrPending.value) _gateOnTranslation = true;
      }
      _startUnawaited(() async {
        if (await _translateCaptions(index, into: into)) return;
        if (isClosed || !canTranscribe || !AsrService.to.modelsReady) return;
        await startAsr(auto: auto);
        _translationRequested = true;
      }());
      return;
    }
    await startAsr(auto: auto);
    _translationRequested = true;
  }

  Future<bool> _translateCaptions(int index, {String? into}) async {
    final track = captions[index];
    var content = _captionCache[track.baseUrl];
    if (content == null) {
      final stops = _translationStops;
      final result = await _captionsFrom.captionContent(track);
      // gone, or stopped while fetching: nothing more to do, and above all
      // no falling back to transcription
      if (isClosed) return true;
      if (stops != _translationStops) {
        _closeAsrGate();
        return true;
      }
      content = result.ok ? result.value : null;
      if (content != null) _captionCache[track.baseUrl] = content;
    }
    final cues = content == null ? const <AsrCue>[] : parseCaptionCues(content);
    if (cues.isEmpty) {
      _closeAsrGate();
      return false;
    }
    _translatedCaption = index;
    await translation.startCaptions(
      cues,
      into: into,
      from: captionLanguage(track.languageCode),
    );
    return true;
  }

  /// See [VideoDetailController.startTranslation].
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
    // see VideoDetailController.startTranslation: an ended one is not
    // waited on
    if (session == null || session.hasEnded) {
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
    // a finished or failed translation is started over
    if (!translation.isRunning) await translation.stop();
    _maybeTranslate(session, auto: false);
  }

  /// Stops translating and goes back to what was shown before.
  Future<void> stopTranslation() async {
    _translationStops++;
    _translationRequested = false;
    await translation.stop();
    _showUntranslated();
    _translatedCaption = null;
  }

  void _publishTranslation(String vtt, {required bool first}) {
    final player = plPlayerController.videoPlayerController;
    if (player == null || isClosed || !_ownsPlayer) return;
    final into = translation.into ?? AsrService.appLanguage;
    if (_wantedOnDevice != into) {
      if (_viewerChose || _wantedOnDevice != null) return;
      // shown the first time; after that refreshed only while it is still
      // what is shown — the viewer may have turned subtitles off or picked a
      // track
      if (!first && captionIndex.value != -2) return;
    }
    _showGeneratedTrack(
      SubtitleTrack(
        'memory://$vtt',
        onDeviceLabel(into),
        'asr-translated',
        uri: true,
      ),
    );
  }

  /// See [VideoDetailController._wantedOnDevice].
  String? _wantedOnDevice;

  /// See [VideoDetailController._requestedInto].
  String? _requestedInto;

  /// See [VideoDetailController.onDeviceShown].
  String? get onDeviceShown {
    if (captionIndex.value != -2) return null;
    return switch (_generatedTrack?.language) {
      'asr' => 'asr',
      'asr-translated' => translation.into ?? AsrService.appLanguage,
      _ => null,
    };
  }

  /// See [VideoDetailController.onDevicePicked].
  String? get onDevicePicked => onDeviceShown ?? _wantedOnDevice;

  /// See [VideoDetailController.onDeviceBusy].
  bool get onDeviceBusy =>
      (asrSession.value?.state.value.isBusy ?? false) ||
      (translation.session.value?.isActive ?? false);

  /// See [VideoDetailController.hasTranscript].
  bool get hasTranscript => asrSession.value?.cues.isNotEmpty ?? false;

  /// See [VideoDetailController.hasTranslationInto].
  @override
  bool hasTranslationInto(String into) =>
      (translation.into ?? AsrService.appLanguage) == into &&
      translation.currentVtt != null &&
      translation.session.value?.state.value.stage != TranslationStage.failed;

  // ------------------------------------------------ the subtitle menu

  /// See [VideoDetailController._menuPick].
  String? _menuPick;
  var _menuPicked = false;

  @override
  String? get menuPicked =>
      _menuPicked ? _menuPick : SubtitleChoice.codeOf(Pref.subtitleChoice);

  @override
  int? get shownPlatformTrack {
    final index = captionIndex.value;
    return index >= 0 && index < captions.length ? index : null;
  }

  @override
  SubtitleSourcePreference? get menuActive {
    if (shownPlatformTrack != null) return SubtitleSourcePreference.platform;
    if (onDeviceShown != null) return SubtitleSourcePreference.device;
    return null;
  }

  @override
  List<String> get platformTrackNames => [
    for (final c in captions) c.displayName,
  ];

  @override
  List<String> get spoken => spokenOf(asrSession.value, platformTracks);

  @override
  bool get hasTranscription => asrSession.value != null;

  /// See [VideoDetailController.menuStatus].
  @override
  SubtitleStatus? menuStatus(String code) {
    final session = asrSession.value;
    final transcript = transcriptStatus(
      state: session?.state.value,
      covered: session?.transcript.covered ?? const [],
      duration: session?.duration,
      playhead: plPlayerController.position.value.toDouble(),
    );
    final waiting = menuPicked == code && menuActive == null;
    if (code == 'asr') {
      if (session == null && waiting && !AsrService.to.modelsReady) {
        return const SubtitleStatus('需要下载模型');
      }
      return transcript;
    }
    final state = translation.session.value?.state.value;
    if (state != null && (translation.into ?? AsrService.appLanguage) == code) {
      return translationStatus(
        state: state,
        transcript: _translatedCaption == null ? transcript : null,
      );
    }
    if (_wantedOnDevice == code && _translationRequested) {
      return transcript ?? const SubtitleStatus('准备中', busy: true);
    }
    if (waiting &&
        !translation.isActive &&
        TranslationService.supported &&
        !TranslationService.to.modelReady) {
      return const SubtitleStatus('需要下载模型');
    }
    return null;
  }

  /// See [VideoDetailController.showTranscript].
  Future<void> showTranscript() async {
    _resumeOnDevice();
    _viewerChose = true;
    _wantedOnDevice = 'asr';
    final session = asrSession.value;
    // an ended (failed) one starts again
    if (session == null || session.hasEnded) {
      await startAsr();
      return;
    }
    // what there is is shown now; the rest follows as it is recognised
    _publishAsrSubtitle(isFinal: true);
  }

  /// See [VideoDetailController.showTranslation].
  Future<void> showTranslation(
    String into, {
    Future<bool> Function()? mayTranscribe,
  }) async {
    _resumeOnDevice();
    _viewerChose = true;
    _wantedOnDevice = into;
    if (hasTranslationInto(into)) {
      if (translation.currentVtt case final vtt?) {
        _publishTranslation(vtt, first: false);
      }
      return;
    }
    if (translation.isActive) {
      _translationStops++;
      await translation.stop();
    }
    _requestedInto = into == AsrService.appLanguage ? null : into;
    await startTranslation(mayTranscribe: mayTranscribe);
  }

  /// See [VideoDetailController._resumeOnDevice].
  void _resumeOnDevice() {
    final session = asrSession.value;
    if (session != null && session.isSwitchedOff) session.resumeOn();
  }

  /// See [VideoDetailController.chooseOff].
  @override
  Future<void> chooseOff() async {
    _menuPick = null;
    _menuPicked = true;
    await GStorage.setting.put(
      SettingBoxKey.subtitleChoice,
      SubtitleChoice.off,
    );
    await setCaption(-1);
    await _switchOffOnDevice();
  }

  /// See [VideoDetailController.chooseLanguage].
  @override
  Future<void> chooseLanguage(
    String code,
    OpenPlan plan, {
    Future<bool> Function()? mayTranscribe,
  }) async {
    _menuPick = code;
    _menuPicked = true;
    await GStorage.setting.put(
      SettingBoxKey.subtitleChoice,
      SubtitleChoice.fromCode(code),
    );
    switch (plan.action) {
      case OpenAction.platform:
        await _showPlatformTrack(plan.track!);
      case OpenAction.onDevice:
        if (code == 'asr') {
          await showTranscript();
        } else {
          await showTranslation(code, mayTranscribe: mayTranscribe);
        }
      case OpenAction.none:
        SmartDialog.showToast('这个视频无法生成该字幕');
    }
  }

  /// See [VideoDetailController.choosePlatformTrack].
  @override
  Future<void> choosePlatformTrack(int index) async {
    _menuPick = pickedTrack;
    _menuPicked = true;
    await _showPlatformTrack(index);
  }

  Future<void> _showPlatformTrack(int index) async {
    await setCaption(index);
    await _switchOffOnDevice();
  }

  /// See [VideoDetailController._switchOffOnDevice].
  Future<void> _switchOffOnDevice() async {
    _closeAsrGate();
    _translationRequested = false;
    _translationStops++;
    asrSession.value?.windDown();
    if (translation.isActive) {
      _translatedCaption = null;
      await translation.stop(finish: true);
    }
  }

  /// Does what the subtitle switch asks of this video (see
  /// [VideoDetailController._maybeAutoTranscribe]), once: a stream refresh
  /// comes back here with the viewer's own picks since then to keep.
  void _maybeAutoTranscribe() {
    _autoChecks++;
    if (_openApplied || isClosed || !Get.isRegistered<AsrService>()) return;
    _openApplied = true;
    final plan = _openPlan();
    switch (plan.action) {
      case OpenAction.platform:
        // new here: this page used to show none of YouTube's own by itself
        if (!_viewerChose) _showCaption(plan.track!);
      case OpenAction.onDevice:
        _startOnDevice(plan.code!, auto: true);
      case OpenAction.none:
        break;
    }
  }

  // ------------------------------------------- the player's hooks (see _open)

  /// The viewer picked a height: nothing changes it by itself.
  var _heightChosen = false;

  /// The height the video opened at: stepping back up stops there.
  int? _heightCeiling;

  /// When a slow spell was last let be (see [_stepHeight]).
  DateTime? _slowKeptAt;

  /// When the height last went up by itself, and until when it may not again.
  DateTime? _steppedUpAt;
  DateTime? _noStepUpUntil;

  Future<({String? video, String? audio})?> _streamSlow() =>
      _stepHeight(down: true);

  Future<({String? video, String? audio})?> _streamRoomy() =>
      _stepHeight(down: false);

  /// One height down, or up to [_heightCeiling] when what the network has
  /// delivered while playing keeps up with the higher stream with room to
  /// spare — as the bilibili page steps its quality. YouTube played on a
  /// throttled stream, three seconds then a 5-14 s stall, for good: nothing
  /// here stepped down (2026-10-02).
  Future<({String? video, String? audio})?> _stepHeight({
    required bool down,
  }) async {
    if (!down) _undoStepUp = null;
    if (_heightChosen || isClosed) return null;
    if (!down) {
      if (_noStepUpUntil case final until?
          when DateTime.now().isBefore(until)) {
        return null;
      }
    }
    // what came in while playing keeps up with the stream: the buffer ran
    // low for another reason (a seek, a burst) — kept once, as the bilibili
    // page does; slow again within 2 min, a step down
    if (down) {
      final delivered = plPlayerController.observedBytesPerSecond;
      // at 3x, three times the bitrate (see PlPlayerController.atSpeed)
      final rate = plPlayerController.atSpeed(
        _streams == null ? null : _bitrateOf(_streams!),
      );
      final at = DateTime.now();
      // not while the buffer falls a long way (see the bilibili page)
      if (delivered != null &&
          rate != null &&
          delivered * 8 >= rate &&
          !plPlayerController.bufferFalling &&
          (_slowKeptAt == null ||
              at.difference(_slowKeptAt!) > const Duration(minutes: 2))) {
        _slowKeptAt = at;
        EventLog.add(
          'player',
          'stream slow, but delivered '
              '${(delivered * 8 / 1e6).toStringAsFixed(1)} Mbps for '
              '${(rate / 1e6).toStringAsFixed(1)} Mbps: quality kept',
        );
        return null;
      }
    }
    final now = _streams?.video == null ? null : ytShortSide(_streams!.video!);
    if (now == null) return null;
    final heights = availableHeights;
    int? next;
    if (down) {
      for (final h in heights) {
        if (h < now) {
          next = h;
          break;
        }
      }
    } else {
      for (final h in heights.reversed) {
        if (h > now && h <= (_heightCeiling ?? now)) {
          next = h;
          break;
        }
      }
    }
    if (next == null) return null;
    final height = next;
    // the source of the streams playing: a step served by another (after a
    // fall-through, the direct source is asked first again) is not mixed in
    final playingFrom = _streams?.sourceId;
    final result = await play.run(
      (s) =>
          s.streams(videoId, preference: YtFormatPreference(maxHeight: height)),
    );
    final pair = result.value;
    if (isClosed || !result.ok || pair == null) return null;
    final bitrate = _bitrateOf(pair);
    if (!down) {
      // the host's burst on a fresh request, the line's capacity: what came
      // in while playing never shows room for more (see the bilibili page's
      // raiseQuality). No bilibili referer goes to googlevideo
      final capacity = await CdnProbe.speed(
        await _playable(pair, pair.videoUrl),
        length: 1 << 20,
        timeout: const Duration(seconds: 4),
        bilibili: false,
      );
      if (isClosed ||
          !CdnProbe.keepsUp(
            capacity,
            plPlayerController.atSpeed(bitrate),
            margin: 1.5,
          )) {
        return null;
      }
    }
    if (!down) {
      final before = (
        streams: _streams,
        height: maxHeight.value,
        bitrate: plPlayerController.streamBitrate,
      );
      _undoStepUp = () {
        _streams = before.streams;
        maxHeight.value = before.height;
        plPlayerController.streamBitrate = before.bitrate;
        _steppedUpAt = null;
      };
    }
    _streams = pair;
    maxHeight.value = next;
    plPlayerController.streamBitrate = bitrate;
    EventLog.add('player', 'quality ${down ? 'down' : 'up'} to ${next}p');
    final stamp = DateTime.now();
    if (!down) {
      _steppedUpAt = stamp;
    } else if (_steppedUpAt case final up?
        when stamp.difference(up) < const Duration(minutes: 10)) {
      // the step up stalled: not again for a while
      _noStepUpUntil = stamp.add(const Duration(minutes: 10));
      _steppedUpAt = null;
      EventLog.add('player', 'the step up stalled: no step up for 10 min');
    }
    final video = await _playable(pair, _videoUrlOf(pair));
    // from another source, its audio too: a relay URL and a googlevideo one
    // in one file left the latter outside 设置代理 (AppProxy.mpvFor)
    final audio = pair.sourceId == playingFrom
        ? null
        : await _playable(pair, pair.audioUrl);
    if (isClosed) return null;
    return (video: video, audio: audio);
  }

  /// Puts back what a step up changed, for one the player could not make
  /// without a stop (see [PlPlayerController.onStepUpDropped]).
  VoidCallback? _undoStepUp;

  void _dropStepUp() {
    _undoStepUp?.call();
    _undoStepUp = null;
  }

  /// Self-test: the first open gets URLs YouTube refuses (403).
  static bool debugRefuseFirstOpen = false;

  /// [pair]'s video URL, through the self-test's slow host when it has one
  /// ([VideoUtils.debugWrapVideoUrl]).
  static String _videoUrlOf(YtStreamPair pair) =>
      VideoUtils.debugWrapVideoUrl?.call(pair.videoUrl) ?? pair.videoUrl;

  /// Video and audio bitrate of [pair], bits per second; null when YouTube
  /// did not say.
  static int? _bitrateOf(YtStreamPair pair) {
    int? rate(YtFormat? f) => f == null
        ? null
        : (f.averageBitrate ?? 0) > 0
        ? f.averageBitrate
        : (f.bitrate > 0 ? f.bitrate : null);
    final video = rate(pair.video);
    return video == null ? null : video + (rate(pair.audio) ?? 0);
  }

  DateTime? _failoverAt;

  /// Failovers since [_failoverAt].
  int _failovers = 0;

  /// What the player asks for when the URLs will not serve: there is one
  /// host per URL, so new URLs, where playback is — once every two minutes;
  /// after that the player says 视频无法播放. From Invidious, once per
  /// instance it may still ask ([YtInvidiousSource.triesPerVideo]): the one
  /// that served is set aside first, so the new URLs are another's.
  bool _failover() {
    final now = DateTime.now();
    if (isClosed) return false;
    final fromInvidious = _streams?.sourceId == YtInvidiousSource.shared.id;
    final within =
        _failoverAt != null &&
        now.difference(_failoverAt!) < const Duration(minutes: 2);
    if (!within) {
      _failoverAt = now;
      _failovers = 0;
    }
    final allowed = fromInvidious ? YtInvidiousSource.triesPerVideo : 1;
    if (_failovers >= allowed) return false;
    _failovers++;
    if (fromInvidious) YtInvidiousSource.shared.playbackFailed(videoId);
    final at = plPlayerController.resumePosition;
    EventLog.add('player', 'youtube: new stream URLs at ${at.inSeconds} s');
    _renewStreams(at);
    return true;
  }

  /// Opens the streams played now again, where playback is.
  void _reopenHere() {
    final pair = _streams;
    if (pair == null || isClosed) return;
    _open(pair, seekTo: plPlayerController.resumePosition);
  }

  /// Re-resolves the streams: a direct URL lasts about six hours and is bound
  /// to this network, so a resumed session needs new ones rather than a retry.
  Future<void> refreshStreams() async {
    _forgetResolved();
    final streams = await play.run((s) => s.streams(videoId));
    if (isClosed) return;
    if (streams.ok && streams.value != null) {
      _streams = streams.value;
      await _open(streams.value!);
    } else {
      _fail(streams.verdict);
    }
  }

  String? get shareUrl => 'https://www.youtube.com/watch?v=$videoId';

  /// YouTube refused this network: the video in the browser, which has its
  /// own network standing (user 2026-10-03).
  void openInBrowser() => PageUtils.launchURL(shareUrl!);

  /// …or on a public Invidious instance that answers now.
  Future<void> openInInvidious() async {
    if (findingInvidious.value) return;
    findingInvidious.value = true;
    try {
      final instance = await InvidiousInstances.pick();
      if (instance == null) {
        SmartDialog.showToast('没有找到可用的 Invidious 实例');
        return;
      }
      EventLog.add('youtube', 'opening $videoId on $instance');
      await PageUtils.launchURL(InvidiousInstances.watchUrl(instance, videoId));
    } finally {
      findingInvidious.value = false;
    }
  }

  Duration? get position =>
      plPlayerController.videoPlayerController?.state.position;

  YtStreamPair? get streams => _streams;

  @override
  void onClose() {
    _saveHistory();
    for (final w in _historyWorkers) {
      w.dispose();
    }
    _stopWatchingPlayback();
    // the gate coming down on the way out must not start the player again
    _releaseHold();
    stopAsr(leaving: true);
    if (plPlayerController.onSourceExpired == _renewStreams) {
      plPlayerController
        ..onSourceExpired = null
        ..onStreamSlow = null
        ..onStreamRoomy = null
        ..onCdnFailover = null
        ..onReopen = null
        ..onStepUpDropped = null;
    }
    videoPlayerServiceHandler?.onVideoDetailDispose(_mediaTag);
    plPlayerController.dispose();
    // after the player let go of its streams
    unawaited(_relay?.close());
    super.onClose();
  }
}

/// The job's cancel (its notification's button, the system's task manager)
/// reaches the download's own token.
class _YtJobToken extends AsrCancelToken {
  _YtJobToken(this._download);

  final YtDownloadToken _download;

  @override
  void cancel() {
    super.cancel();
    _download.cancel();
  }
}
