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
import 'package:PiliPlus/services/youtube/youtube.dart';
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

    final streams = await router.run((s) => s.streams(videoId));
    if (isClosed) return;
    if (!streams.ok || streams.value == null) {
      _fail(streams.verdict);
      return;
    }
    _streams = streams.value;
    await _open(streams.value!);
  }

  Future<void> _open(YtStreamPair pair) async {
    // The player is shared with the bilibili page, which sets bilibili's
    // Referer and UA on it globally. Sending those to googlevideo would tell
    // Google which bilibili client is watching — exactly the cross-site
    // linkage this app exists to avoid. Google serves these URLs without any
    // of it (measured), so they are cleared for the duration.
    plPlayerController.videoPlayerController?.setMediaHeader();
    await plPlayerController.setDataSource(
      NetworkSource(videoSource: pair.videoUrl, audioSource: pair.audioUrl),
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
    plPlayerController.dispose();
    super.onClose();
  }
}
