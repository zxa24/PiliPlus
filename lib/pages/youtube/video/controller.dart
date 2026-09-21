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
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_subscriptions.dart';
import 'package:flutter/foundation.dart';
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

    final streams = await router.run((s) => s.streams(videoId));
    if (isClosed) return;
    if (!streams.ok || streams.value == null) {
      _fail(streams.verdict);
      return;
    }
    _streams = streams.value;
    await _open(streams.value!);
    unawaited(_loadRelated());
    unawaited(_loadChannel());
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

  // -------------------------------------------------------- channel header

  /// Avatar, subscriber count — none of which the player response carries.
  /// One extra request, made after the video is already playing.
  final channel = Rxn<YtChannelInfo>();

  Future<void> _loadChannel() async {
    final channelId = detail.value?.channelId;
    if (channelId == null || channelId.isEmpty) return;
    final result = await router.run(
      (s) => (s as YtDirectSource).channelPage(channelId),
    );
    if (isClosed || !result.ok) return;
    channel.value = result.value?.info;
  }

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
  String? _commentsToken;
  var _commentsStarted = false;

  bool get hasMoreComments => _commentsToken != null;

  Future<void> _loadRelated() async {
    final result = await router.run(
      (s) => (s as YtDirectSource).related(videoId),
    );
    if (isClosed || !result.ok || result.value == null) return;
    related.value = result.value!.related;
    _commentsToken = result.value!.commentsToken;
  }

  /// Fetches one page. The first call happens when the comments tab is first
  /// shown, not with the video: most viewers never open it.
  Future<void> loadMoreComments() async {
    final token = _commentsToken;
    if (token == null || commentsLoading.value) return;
    commentsLoading.value = true;
    final result = await router.run(
      (s) => (s as YtDirectSource).comments(token),
    );
    if (isClosed) return;
    commentsLoading.value = false;
    if (result.ok && result.value != null) {
      comments.addAll(result.value!.items);
      _commentsToken = result.value!.continuation;
    } else {
      _commentsToken = null;
    }
  }

  void ensureCommentsStarted() {
    if (_commentsStarted) return;
    _commentsStarted = true;
    loadMoreComments();
  }

  // ------------------------------------------------- on-device transcription

  /// A YouTube video that carries no captions of its own is exactly what the
  /// recogniser is for — and, since most of what has none here is in another
  /// language, the case the "外语视频自动转录" setting was written around.
  final asrSession = Rxn<AsrSession>();
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
    // no Referer, no UA: googlevideo does not need them and sending
    // bilibili's would link the two sites (see [_open])
    final session = await AsrService.to.start(
      key: 'yt:$videoId',
      source: source,
      auto: auto,
    );
    asrSession.value = session;
    SmartDialog.showToast(auto ? '正在自动转录字幕…' : '正在转录字幕…');
    _asrCueSub = session.cues.listen((_) {});
    _asrRefresh = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _publishAsrSubtitle(),
    );
    _asrStateWorker = ever(session.state, (state) {
      switch (state.stage) {
        case AsrStage.done:
          _publishAsrSubtitle();
          SmartDialog.showToast(
            session.cues.isEmpty ? '没有识别到语音' : '转录完成，已显示字幕',
          );
        case AsrStage.failed:
          SmartDialog.showToast('转录失败：${state.message ?? ''}');
        case _:
          break;
      }
    });
  }

  Future<void> stopAsr() async {
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
