// LibrePili (stage-2 plan §3.3; AC15's unit part): `liveNow` read off the
// direct source's player answer — live now or upcoming; a replay of a
// live stream (`isLiveContent` true) and a plain video are not — and the
// one source mode shared by the video page and the downloads.
import 'package:PiliPlus/pages/youtube/video/controller.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_source_store.dart';
import 'package:flutter_test/flutter_test.dart';

YtVideoDetail _detail(Map<String, dynamic> videoDetails) =>
    YtVideoDetail.fromPlayerJson({
      'videoDetails': {'videoId': 'dQw4w9WgXcQ', ...videoDetails},
      'streamingData': {
        'hlsManifestUrl': 'https://manifest.googlevideo.com/x.m3u8',
      },
    });

void main() {
  test('live now, or upcoming: liveNow', () {
    expect(_detail({'isLive': true, 'isLiveContent': true}).liveNow, isTrue);
    expect(_detail({'isUpcoming': true}).liveNow, isTrue);
  });

  test('a replay, a plain video: not — whatever hlsManifestUrl says', () {
    final replay = _detail({'isLiveContent': true});
    expect(replay.liveNow, isFalse);
    expect(replay.isLive, isTrue);
    expect(replay.hlsManifestUrl, isNotNull);
    expect(_detail({}).liveNow, isFalse);
    expect(_detail({'isLive': false, 'isUpcoming': false}).liveNow, isFalse);
  });

  test('a detail built by hand (Invidious): not live', () {
    const d = YtVideoDetail(
      videoId: 'dQw4w9WgXcQ',
      title: '',
      author: '',
      channelId: '',
      duration: Duration.zero,
      thumbnails: [],
      formats: [],
      captionTracks: [],
      isLive: true,
      expiresIn: Duration.zero,
    );
    expect(d.liveNow, isFalse);
  });

  test("the page's source mode is the store's", () {
    addTearDown(() => YtSourceStore.debugMode = YtSourceMode.auto);
    YtVideoController.debugSourceMode = YtSourceMode.fallbackOnly;
    expect(YtSourceStore.debugMode, YtSourceMode.fallbackOnly);
    YtSourceStore.debugMode = YtSourceMode.directOnly;
    expect(YtVideoController.debugSourceMode, YtSourceMode.directOnly);
  });
}
