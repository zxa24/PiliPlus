/// LibrePili — YouTube, stage 2: playing what the stage-1 data layer resolves.
///
/// Deliberately its own page rather than a branch inside the bilibili video
/// page. That page carries aid/bvid/cid, danmaku, the reply tree, history
/// reporting and the rest of a bilibili video everywhere; threading a second
/// platform through it would touch every one of those. A platform is its own
/// mode here, which is also where the interface is going.
library;

import 'dart:async';

import 'package:PiliPlus/common/widgets/dialog/failure_report.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_publish.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/asr/subtitle_punctuation.dart';
import 'package:PiliPlus/services/asr/model_guard.dart';
import 'package:PiliPlus/services/translate/caption_source.dart';
import 'package:PiliPlus/services/translate/comment_translator.dart';
import 'package:PiliPlus/services/translate/translation_languages.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/services/translate/translation_track.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_download.dart';
import 'package:PiliPlus/services/youtube/yt_subscriptions.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, BuildContext, WidgetsBinding;
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart' show SubtitleTrack;

enum YtPageStage { loading, ready, failed }

class YtVideoController extends GetxController {
  YtVideoController({required this.videoId, YouTubeVideoSource? source})
    : router = YtSourceRouter(source ?? YtDirectSource.create());

  final String videoId;
  final YtSourceRouter router;

  final plPlayerController = PlPlayerController.getInstance();

  final stage = YtPageStage.loading.obs;
  final detail = Rxn<YtVideoDetail>();
  final message = ''.obs;

  /// Caption tracks offered by YouTube, plus the one currently shown.
  final captions = <YtCaptionTrack>[].obs;
  final captionIndex = (-1).obs;
  final _captionCache = <int, String>{};

  YtStreamPair? _streams;

  @override
  void onInit() {
    super.onInit();
    // comments loaded while translation is on are translated too
    // (user 2026-09-25, 1A)
    ever(comments, (_) => translateLoadedComments());
    unawaited(load());
  }

  Future<void> load() async {
    stage.value = YtPageStage.loading;
    message.value = '';

    final info = await router.run((s) => s.detail(videoId));
    if (isClosed) return;
    if (!info.ok || info.value == null) {
      _fail(info.verdict);
      return;
    }
    detail.value = info.value;
    captions.value = info.value!.captionTracks;
    _refreshSubscribed();
    refreshFav();

    final streams = await router.run((s) => s.streams(videoId));
    if (isClosed) return;
    if (!streams.ok || streams.value == null) {
      _fail(streams.verdict);
      return;
    }
    _streams = streams.value;
    await _open(streams.value!);
    unawaited(_loadRelated());
  }

  Future<void> _open(YtStreamPair pair, {Duration? seekTo}) async {
    // The player is shared with the bilibili page, which sets bilibili's
    // Referer and UA on it globally. Sending those to googlevideo would tell
    // Google which bilibili client is watching — exactly the cross-site
    // linkage this app exists to avoid. Google serves these URLs without any
    // of it (measured), so they are cleared for the duration.
    plPlayerController.videoPlayerController?.setMediaHeader();
    final source = NetworkSource(
      videoSource: pair.videoUrl,
      audioSource: pair.audioUrl,
    );
    _ownSource = source;
    // mpv keeps an added subtitle track with the file it was added to: a new
    // one — a quality change, fresh streams — starts without the transcript
    // or translation that was on screen, which is only handed over again
    // when it has something new, and a finished or stopped one never is
    final generated = captionIndex.value == -2 ? _generatedTrack : null;
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
          plPlayerController.videoPlayerController?.setSubtitleTrack(generated);
        }
      },
    );
    if (!isClosed) stage.value = YtPageStage.ready;
    _maybeAutoTranscribe();
  }

  /// The UI's reading of a verdict. Kept here rather than in the data layer,
  /// which stays free of presentation — and the diagnostic signal is appended
  /// so a report says which of the four causes fired.
  static String _messageFor(YtVerdict verdict) => switch (verdict.cause) {
    YtCause.ok => '',
    YtCause.contentUnavailable => '该视频无法播放（已删除、私有、年龄限制或地区限制）',
    YtCause.ipBlocked => '当前网络被 YouTube 限流，可稍后重试或切换来源',
    YtCause.transient => '网络错误，请重试',
    YtCause.clientBroken => 'YouTube 接口已变化，应用需要更新（${verdict.signal}）',
  };

  void _fail(YtVerdict verdict) {
    if (isClosed) return;
    stage.value = YtPageStage.failed;
    message.value = _messageFor(verdict);
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

  Future<void> _showCaption(int index) async {
    final player = plPlayerController.videoPlayerController;
    if (player == null) return;
    if (index < 0 || index >= captions.length) {
      await player.setSubtitleTrack(SubtitleTrack.no());
      captionIndex.value = -1;
      return;
    }

    var content = _captionCache[index];
    if (content == null) {
      final track = captions[index];
      final result = await router.run((s) => s.captionContent(track));
      if (!result.ok || result.value == null) {
        message.value = _messageFor(result.verdict);
        return;
      }
      // YouTube hands back WebVTT already; nothing to convert
      content = result.value!;
      _captionCache[index] = content;
    }
    if (isClosed) return;
    final track = captions[index];
    await player.setSubtitleTrack(
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

  /// The heights actually on offer for this video, best first.
  List<int> get availableHeights {
    final heights = <int>{
      for (final format in detail.value?.formats ?? const <YtFormat>[])
        if (format.isVideo && format.isPlayable && format.height != null)
          format.height!,
    }.toList()..sort((a, b) => b.compareTo(a));
    return heights;
  }

  Future<void> setMaxHeight(int height) async {
    if (maxHeight.value == height) return;
    maxHeight.value = height;
    final position = plPlayerController.videoPlayerController?.state.position;
    final streams = await router.run(
      (s) => s.streams(
        videoId,
        preference: YtFormatPreference(maxHeight: height),
      ),
    );
    if (isClosed) return;
    if (streams.ok && streams.value != null) {
      _streams = streams.value;
      await _open(streams.value!, seekTo: position);
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
    final pair = _streams;
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
      final file = await YtDownloader.download(
        pair: pair,
        videoId: videoId,
        title: detail.value?.title ?? videoId,
        token: token,
        onProgress: (fraction, stage) {
          if (isClosed) return;
          SmartDialog.showLoading(
            msg: '$stage ${(fraction * 100).clamp(0, 100).toStringAsFixed(0)}%',
            onDismiss: token.cancel,
          );
        },
      );
      SmartDialog.dismiss(status: SmartStatus.loading);
      SmartDialog.showToast('已保存到 $file');
    } on YtDownloadCancelled {
      SmartDialog.dismiss(status: SmartStatus.loading);
      SmartDialog.showToast('已取消下载');
    } catch (e) {
      SmartDialog.dismiss(status: SmartStatus.loading);
      SmartDialog.showToast('下载失败: $e');
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
      avatar: info.thumbnails.isEmpty ? null : info.thumbnails.first.url,
    );
    subscribed.value = now;
    SmartDialog.showToast(now ? '已订阅 ${info.author}' : '已取消订阅');
  }

  // ------------------------------------------------ related and comments

  final related = <YtSearchItem>[].obs;
  final comments = <YtComment>[].obs;
  final commentsLoading = false.obs;

  /// Null means "no more": either the video has comments off, or the last
  /// page was the last one.
  ///
  /// Observable, because the list's footer reads it: while it was a plain
  /// field, nothing told the footer's Obx to rebuild when a page turned out
  /// to be the last one, and the trailing spinner had no reason to go away.
  final _commentsToken = RxnString();
  // observable: `commentsPending` is read inside an Obx, and a plain bool
  // there is the same trap the continuation token was in
  final _commentsStarted = false.obs;

  /// Why the comments are not here, when they are not.
  ///
  /// Without it a failed request emptied into 「暂无评论」, which is what a
  /// video with comments turned off says — the two were indistinguishable,
  /// and since the attempt had already been marked as made, nothing ever
  /// tried again.
  final commentsError = RxnString();

  bool get hasMoreComments => _commentsToken.value != null;

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
      return;
    }
    _relatedDone.value = true;
    relatedError.value = null;
    related.value = result.value!.related;
    _commentsToken.value = result.value!.commentsToken;
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

  /// Fetches one page. The first call is made as soon as the token exists,
  /// so the tab is already populated when it is opened.
  Future<void> loadMoreComments() async {
    final token = _commentsToken.value;
    if (token == null || commentsLoading.value) return;
    commentsLoading.value = true;
    final result = await router.run(
      (s) => (s as YtDirectSource).comments(token),
    );
    if (isClosed) return;
    commentsLoading.value = false;
    if (result.ok && result.value != null) {
      comments.addAll(result.value!.items);
      _commentsToken.value = result.value!.continuation;
      commentsError.value = null;
    } else {
      // the token is kept: the page that failed is the page to retry
      commentsError.value = _messageFor(result.verdict);
    }
  }

  void ensureCommentsStarted() {
    // The latch must not close on an attempt that could not have worked.
    // Opening the 评论 tab while the video is still loading called this
    // before the token existed: it did nothing, marked the comments as
    // started, and the call that arrives *with* the token then found the
    // latch already closed — so the tab stayed empty for good.
    if (_commentsStarted.value || _commentsToken.value == null) return;
    _commentsStarted.value = true;
    loadMoreComments();
  }

  /// True while there is nothing to show and nothing has failed: either a
  /// page is in flight or the token it needs has not arrived yet. Both are
  /// "wait", and neither is 「暂无评论」, which is what a video with
  /// comments turned off says.
  bool get commentsPending =>
      comments.isEmpty &&
      commentsError.value == null &&
      (commentsLoading.value || !_commentsStarted.value);

  /// Retries the page that failed, without losing the ones that did not.
  Future<void> retryComments() {
    commentsError.value = null;
    return loadMoreComments();
  }

  /// Pull to refresh: back to the first page, which means a fresh bootstrap
  /// token — the one this page holds belongs to a position in a list that is
  /// about to be thrown away.
  Future<void> refreshComments() async {
    if (commentsLoading.value) return;
    commentsLoading.value = true;
    final result = await router.run(
      (s) => (s as YtDirectSource).related(videoId),
    );
    if (isClosed) {
      return;
    }
    commentsLoading.value = false;
    if (!result.ok || result.value == null) {
      commentsError.value = _messageFor(result.verdict);
      return;
    }
    comments.clear();
    replies.clear();
    repliesLoading.clear();
    _moreReplies.clear();
    commentsError.value = null;
    _commentsToken.value = result.value!.commentsToken;
    await loadMoreComments();
  }

  // ------------------------------------------------------------- replies
  //
  // A thread's replies are another page from the same endpoint, reached by
  // the token that came with the comment. They are kept per comment rather
  // than spliced into `comments`: a reply is not a comment that happens to
  // be lower down, and the list has to be able to collapse again.

  final replies = <String, RxList<YtComment>>{}.obs;
  final repliesLoading = <String>{}.obs;
  final _moreReplies = <String, String?>{};

  bool hasMoreReplies(String commentId) => _moreReplies[commentId] != null;

  /// Fetches the first page of a thread's replies so the list can show a
  /// preview of them, the way the bilibili one does.
  ///
  /// YouTube sends no replies with the comments — only a token and a count —
  /// so a preview is a request per thread. It is made when the row is built,
  /// which is when it is about to be seen, rather than for all twenty at
  /// once when the page opens.
  void ensureRepliesPreview(YtComment comment) {
    if (!comment.hasReplies) return;
    final id = comment.commentId;
    if (replies.containsKey(id) || repliesLoading.contains(id)) return;
    // This is called from a row's build. Marking the thread as loading
    // touches an observable, and doing that while the frame is being built
    // is a change-during-build — the error lands in an unawaited future and
    // vanishes, which is exactly what it did: no request, no entry, and
    // nothing on screen to say why. It waits for the frame to end instead.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isClosed) return;
      if (replies.containsKey(id) || repliesLoading.contains(id)) return;
      unawaited(_fetchReplies(id, comment.replyToken));
    });
  }

  /// Pull to refresh inside a thread: back to its first page.
  Future<void> refreshReplies(YtComment comment) async {
    final id = comment.commentId;
    if (repliesLoading.contains(id)) return;
    replies
      ..remove(id)
      ..refresh();
    _moreReplies.remove(id);
    repliesError.remove(id);
    await _fetchReplies(id, comment.replyToken);
  }

  /// Why a thread's replies are not here, when they are not. Keyed by
  /// comment id, so one failed thread does not speak for the others.
  final repliesError = <String, String>{}.obs;

  Future<void> loadMoreReplies(String commentId) =>
      _fetchReplies(commentId, _moreReplies[commentId]);

  Future<void> _fetchReplies(String commentId, String? token) async {
    if (token == null || repliesLoading.contains(commentId)) return;
    repliesLoading.add(commentId);
    final result = await router.run(
      (s) => (s as YtDirectSource).comments(token),
    );
    if (isClosed) return;
    repliesLoading.remove(commentId);
    if (result.ok && result.value != null) {
      (replies[commentId] ??= <YtComment>[].obs).addAll(result.value!.items);
      translateLoadedComments();
      replies.refresh();
      _moreReplies[commentId] = result.value!.continuation;
      repliesError.remove(commentId);
    } else {
      // an empty list rather than nothing: the thread is open and has to say
      // something, and "nothing loaded" must not look like "not tried yet"
      replies[commentId] ??= <YtComment>[].obs;
      replies.refresh();
      _moreReplies[commentId] = null;
      repliesError[commentId] = _messageFor(result.verdict);
    }
  }

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

  /// See [VideoDetailController._autoTranslateOff]; here a stream refresh is
  /// what comes back through [_maybeAutoTranscribe].
  var _autoTranslateOff = false;

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
  String? get asrSource => _streams?.audioUrl;

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
      auto: auto,
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
      // the language is known from the first segment on
      if (state.language != null) {
        // a corrected language can turn out to be the user's own
        if (translation.isActive &&
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
      _released = true;
      _resumeHeldPlayback();
    }
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
        'memory://${session.cues.forDisplay(session.state.value.language).toVtt()}',
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
    _generatedTrack = track;
    plPlayerController.videoPlayerController?.setSubtitleTrack(track);
    captionIndex.value = -2;
  }

  /// See [VideoDetailController._maybeTranslate].
  void _maybeTranslate(AsrSession session, {required bool auto}) {
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
      _publishAsrSubtitle(isFinal: true);
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
    // a transcript's translation, not a caption track's
    _translatedCaption = null;
    if (auto && asrPending.value) _gateOnTranslation = true;
    _startUnawaited(
      translation.start(session, into: requested ? _requestedInto : null),
    );
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
  int? captionToTranslateInto(String? into) => pickCaptionToTranslateInto(
    [
      for (final c in captions)
        (language: c.languageCode, generated: c.isAutomatic),
    ],
    into: into ?? AsrService.appLanguage,
  );

  /// See [VideoDetailController._maybeAutoTranslateCaptions].
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

  Future<bool> _translateCaptions(int index, {String? into}) async {
    var content = _captionCache[index];
    if (content == null) {
      final stops = _translationStops;
      final result = await router.run((s) => s.captionContent(captions[index]));
      // gone, or stopped while fetching: nothing more to do, and above all
      // no falling back to transcription
      if (isClosed) return true;
      if (stops != _translationStops) {
        _closeAsrGate();
        return true;
      }
      content = result.ok ? result.value : null;
      if (content != null) _captionCache[index] = content;
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
      from: captionLanguage(captions[index].languageCode),
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
    // a finished or failed translation is started over
    if (!translation.isRunning) await translation.stop();
    _maybeTranslate(session, auto: false);
  }

  /// Stops translating and goes back to what was shown before.
  Future<void> stopTranslation() async {
    _translationStops++;
    _translationRequested = false;
    // nor does automatic translation start it again
    _autoTranslateOff = true;
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
  bool hasTranslationInto(String into) =>
      (translation.into ?? AsrService.appLanguage) == into &&
      translation.currentVtt != null &&
      translation.session.value?.state.value.stage != TranslationStage.failed;

  /// See [VideoDetailController.onDeviceStatus].
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
    if (_wantedOnDevice == code && _translationRequested) {
      return asrStatus() ?? '准备中';
    }
    return null;
  }

  /// See [VideoDetailController.showTranscript].
  Future<void> showTranscript() async {
    _viewerChose = true;
    _wantedOnDevice = 'asr';
    final session = asrSession.value;
    if (session == null || session.state.value.stage == AsrStage.failed) {
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

  /// See [VideoDetailController.stopOnDevice].
  Future<void> stopOnDevice() async {
    await stopTranslation();
    await stopAsr();
  }

  /// Starts by itself when the video offers no captions and the user asked
  /// for that. A video with captions is left alone: YouTube's own are better
  /// than ours and cost nothing.
  void _maybeAutoTranscribe() {
    _autoChecks++;
    // captions in a language the user does not read are translated instead
    _maybeAutoTranslateCaptions();
    if (!Get.isRegistered<AsrService>()) return;
    if (asrSession.value != null || !canTranscribe) return;
    if (!AsrService.to.shouldAutoStart(hasSubtitles: captions.isNotEmpty)) {
      return;
    }
    startAsr(auto: true);
  }

  /// Re-resolves the streams: a direct URL lasts about six hours and is bound
  /// to this network, so a resumed session needs new ones rather than a retry.
  Future<void> refreshStreams() async {
    final streams = await router.run((s) => s.streams(videoId));
    if (isClosed) return;
    if (streams.ok && streams.value != null) {
      _streams = streams.value;
      await _open(streams.value!);
    } else {
      _fail(streams.verdict);
    }
  }

  String? get shareUrl => 'https://www.youtube.com/watch?v=$videoId';

  Duration? get position =>
      plPlayerController.videoPlayerController?.state.position;

  YtStreamPair? get streams => _streams;

  /// LibrePili: this video's on-device comment translation
  /// (research/comment-translation-design-2026-09-25.md, E4).
  late final commentTranslator = CommentTranslator.of('yt:$videoId');

  /// The comments loaded, and the replies previewed, as the translator
  /// takes them.
  Iterable<(String, String)> get loadedCommentTexts => [
    for (final c in comments) (c.commentId, c.content),
    for (final list in replies.values)
      for (final r in list) (r.commentId, r.content),
  ];

  void translateLoadedComments() =>
      commentTranslator.addTexts(loadedCommentTexts);

  @override
  void onClose() {
    CommentTranslator.release('yt:$videoId');
    _stopWatchingPlayback();
    // the gate coming down on the way out must not start the player again
    _releaseHold();
    stopAsr(leaving: true);
    plPlayerController.dispose();
    super.onClose();
  }
}
