/// LibrePili — YouTube, stage 2: playing what the stage-1 data layer resolves.
///
/// Deliberately its own page rather than a branch inside the bilibili video
/// page. That page carries aid/bvid/cid, danmaku, the reply tree, history
/// reporting and the rest of a bilibili video everywhere; threading a second
/// platform through it would touch every one of those. A platform is its own
/// mode here, which is also where the interface is going.
library;

import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_download.dart';
import 'package:PiliPlus/services/youtube/yt_subscriptions.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext, WidgetsBinding;
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
    await plPlayerController.setDataSource(
      NetworkSource(videoSource: pair.videoUrl, audioSource: pair.audioUrl),
      seekTo: seekTo,
      duration: detail.value?.duration,
      width: pair.video?.width,
      height: pair.video?.height,
      isVertical:
          (pair.video?.height ?? 0) > (pair.video?.width ?? 0) &&
          pair.video != null,
      // no aid/bvid/cid: nothing here is reported to bilibili
      videoType: null,
      onInit: () => stage.value = YtPageStage.ready,
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

  /// Shows a caption track, or hides captions when [index] is negative.
  Future<void> setCaption(int index) async {
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
    if (auto) _openAsrGate();
    // no Referer, no UA: googlevideo does not need them and sending
    // bilibili's would link the two sites (see [_open])
    final session = await AsrService.to.start(
      key: 'yt:$videoId',
      source: source,
      auto: auto,
    );
    asrSession.value = session;
    _asrCueSub = session.cues.listen((_) => _closeAsrGate());
    _asrRefresh = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _publishAsrSubtitle(),
    );
    _asrStateWorker = ever(session.state, (state) {
      switch (state.stage) {
        case AsrStage.done:
          _closeAsrGate();
          _publishAsrSubtitle();
        case AsrStage.failed:
          _closeAsrGate();
          // only errors interrupt; progress lives in the subtitle menu
          SmartDialog.showToast('转录失败：${state.message ?? ''}');
        case AsrStage.idle:
          _closeAsrGate();
        case _:
          break;
      }
    });
  }

  void _openAsrGate() {
    _asrGate?.cancel();
    asrPending.value = true;
    _asrGate = Timer(const Duration(seconds: 30), _closeAsrGate);
  }

  void _closeAsrGate() {
    _asrGate?.cancel();
    _asrGate = null;
    if (asrPending.value) asrPending.value = false;
  }

  Future<void> stopAsr() async {
    _closeAsrGate();
    _asrRefresh?.cancel();
    _asrRefresh = null;
    _asrStateWorker?.dispose();
    _asrStateWorker = null;
    await _asrCueSub?.cancel();
    _asrCueSub = null;
    asrSession.value = null;
    if (Get.isRegistered<AsrService>()) await AsrService.to.stop();
  }

  /// Shows what has been recognised so far. The page has no track list of its
  /// own to insert into, so the transcript simply becomes the shown subtitle.
  void _publishAsrSubtitle() {
    final session = asrSession.value;
    final player = plPlayerController.videoPlayerController;
    if (session == null || player == null || session.cues.isEmpty) return;
    player.setSubtitleTrack(
      SubtitleTrack('memory://${session.cues.toVtt()}', '自动转录', 'asr',
          uri: true),
    );
    captionIndex.value = -2;
  }

  /// Starts by itself when the video offers no captions and the user asked
  /// for that. A video with captions is left alone: YouTube's own are better
  /// than ours and cost nothing.
  void _maybeAutoTranscribe() {
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

  @override
  void onClose() {
    stopAsr();
    plPlayerController.dispose();
    super.onClose();
  }
}
