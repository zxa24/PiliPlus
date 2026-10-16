import 'package:PiliPlus/services/download/download_progress.dart';
import 'package:flutter_test/flutter_test.dart';

/// One bar over every part of a download: the danmaku, both streams, the
/// merge and the comments / subtitles saved next to the video.
void main() {
  var now = DateTime(2026, 10, 16);
  DownloadProgress progress() => DownloadProgress(clock: () => now);

  // the defaults: cover, danmaku files, subtitles, 200 comments
  final plan = DownloadProgress.extrasPlan(
    cover: true,
    danmaku: true,
    subtitles: true,
    comments: 200,
  );

  setUp(() => now = DateTime(2026, 10, 16));

  test('the extras plan counts comments as list pages plus comments', () {
    expect(plan, {
      DownloadProgress.stepCover: 1,
      DownloadProgress.stepDanmaku: 1,
      DownloadProgress.stepSubtitles: 2,
      DownloadProgress.stepCommentList: 10,
      DownloadProgress.stepComments: 200,
    });
    expect(
      DownloadProgress.extrasPlan(
        cover: false,
        danmaku: false,
        subtitles: false,
        comments: 0,
      ),
      isEmpty,
    );
  });

  test('both streams downloaded is not the whole download', () {
    final p = progress()
      ..planExtras(plan)
      ..video(100e6.toInt(), 100e6.toInt())
      ..audio(8e6.toInt(), 8e6.toInt());
    expect(p.value, greaterThan(0.2));
    expect(p.value, lessThan(0.9));
    p.mergeDone();
    final merged = p.value;
    // the comments are what is left
    p.extras(DownloadProgress.stepComments, 100, 200);
    expect(p.value, greaterThan(merged));
    p.complete();
    expect(p.value, 1);
  });

  test('without extras the streams and the merge are all of it', () {
    final p = progress()
      ..planExtras(const {})
      ..video(50, 50)
      ..mergeDone();
    expect(p.value, 1);
  });

  test('the audio bytes count', () {
    final p = progress()
      ..planExtras(const {})
      ..video(100, 100)
      ..audio(0, 100);
    final videoOnly = p.value;
    p.audio(100, 100);
    expect(p.value, greaterThan(videoOnly));
    expect(p.mediaReceived, 200);
    expect(p.mediaTotal, 200);
  });

  test('the guess stands for a stream not reported yet', () {
    final p = progress()
      ..mediaGuess = 110
      ..video(10, 100);
    // video known, audio not yet: the guess (both streams) is the total
    expect(p.mediaTotal, 110);
    p.audio(1, 12);
    expect(p.mediaTotal, 112);
  });

  test('audio reporting before the video is not the whole size', () {
    // 2026-10-16 BV1p3af6QEV1 480P: audio 15.3 MB reported first, the
    // video's 23.2 MB a moment later
    final p = progress()
      ..expectAudio = true
      ..mediaGuess = 38527638
      ..audio(7007, 15292436);
    expect(p.mediaTotal, 38527638);
    p.video(117646, 23204170);
    expect(p.mediaTotal, 23204170 + 15292436);
  });

  test('without an audio stream the video alone is all of it', () {
    final p = progress()
      ..expectAudio = false
      ..mediaGuess = 120
      ..video(10, 100);
    expect(p.mediaTotal, 100);
  });

  test('a finished stream counts in full', () {
    final p = progress()
      ..video(37429828 - 15292436, 23204170)
      ..audio(14225658, 15292436)
      ..videoDone()
      ..audioDone();
    expect(p.mediaReceived, p.mediaTotal);
  });

  test('fewer comments than planned: the estimate shrinks, the bar does not '
      'go back', () {
    final p = progress()
      ..planExtras(plan)
      ..video(10e6.toInt(), 10e6.toInt())
      ..mergeDone();
    final before = p.value;
    // the list ended after one page of 12
    p
      ..extras(DownloadProgress.stepCommentList, 1, 1)
      ..extrasDone(DownloadProgress.stepCommentList)
      ..extras(DownloadProgress.stepComments, 0, 12);
    expect(p.value, greaterThanOrEqualTo(before));
    final shrunk = p.value;
    p.extras(DownloadProgress.stepComments, 6, 12);
    expect(p.value, greaterThan(shrunk));
  });

  test('a slower connection than assumed weighs the streams more', () {
    final fast = progress()
      ..planExtras(plan)
      ..video(0, 100e6.toInt());
    now = now.add(const Duration(seconds: 10));
    // 50 MB in 10 s: 5 MB/s
    fast.video(50e6.toInt(), 100e6.toInt());

    now = DateTime(2026, 10, 16);
    final slow = progress()
      ..planExtras(plan)
      ..video(0, 100e6.toInt());
    now = now.add(const Duration(seconds: 100));
    // 50 MB in 100 s: 0.5 MB/s
    slow.video(50e6.toInt(), 100e6.toInt());

    expect(slow.bytesPerSecond, closeTo(0.5e6, 1));
    // half of the streams is more of the whole when they take longer
    expect(slow.value, greaterThan(fast.value));
  });

  test('the comment time is measured once a few are in', () {
    final p = progress()
      ..planExtras(plan)
      ..extras(DownloadProgress.stepComments, 0, 200);
    now = now.add(const Duration(seconds: 6));
    p.extras(DownloadProgress.stepComments, 3, 200);
    // 2 s each: the comments outweigh everything else
    final comments = p.parts.last;
    expect(comments.$1, closeTo(400, 0.01));
  });

  test('a step starting keeps its planned units', () {
    final p = progress()
      ..planExtras(plan)
      ..extrasStart(DownloadProgress.stepComments);
    expect(p.parts.last.$1, closeTo(200 * 0.4, 1e-9));
    expect(p.extrasLabel, '保存评论 0/200');
  });

  test('labels', () {
    final p = progress()..planExtras(plan);
    expect(p.extrasLabel, isNull);
    p.extras(DownloadProgress.stepCommentList, 2, 10);
    expect(p.extrasLabel, '获取评论列表 2/10');
    p.extrasDone(DownloadProgress.stepCommentList);
    expect(p.extrasLabel, isNull);
    p.extrasStart(DownloadProgress.stepCover);
    expect(p.extrasLabel, '保存封面');
  });

  test('never goes back within a run, starts over on a new one', () {
    final p = progress()
      ..planExtras(const {})
      ..video(80, 100);
    final high = p.value;
    // the stream changed: fewer bytes of a bigger total
    p.video(10, 1000);
    expect(p.value, high);
    p
      ..restart()
      ..video(10, 1000);
    expect(p.value, lessThan(high));
  });

  test('danmaku rounds are part of it', () {
    final p = progress()
      ..planExtras(const {})
      ..danmaku(0, 4);
    expect(p.value, 0);
    p.danmaku(4, 4);
    expect(p.value, greaterThan(0));
  });
}
