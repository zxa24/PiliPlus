import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether an open is the video already shown, its last picture held over
/// the open. YouTube and live have no cid or bvid: by their identity only,
/// and every reopen there went black before it (audit 2026-10-21).
void main() {
  bool same({
    int? cid,
    String? bvid,
    String? identity,
    int? oldCid,
    String? oldBvid,
    String? oldIdentity,
  }) => PlPlayerController.isSameVideo(
    cid: cid,
    bvid: bvid,
    identity: identity,
    oldCid: oldCid,
    oldBvid: oldBvid,
    oldIdentity: oldIdentity,
  );

  test('bilibili: the same part again (quality, host, retry)', () {
    expect(same(cid: 1, bvid: 'BV1', oldCid: 1, oldBvid: 'BV1'), isTrue);
  });

  test('bilibili: another part, another video', () {
    expect(same(cid: 2, bvid: 'BV1', oldCid: 1, oldBvid: 'BV1'), isFalse);
    expect(same(cid: 1, bvid: 'BV2', oldCid: 1, oldBvid: 'BV1'), isFalse);
  });

  test('a local file: cid 0 and its bvid', () {
    expect(same(cid: 0, bvid: 'BV1', oldCid: 0, oldBvid: 'BV1'), isTrue);
  });

  test('YouTube: the same video id again, another one', () {
    expect(same(identity: 'yt:abc', oldIdentity: 'yt:abc'), isTrue);
    expect(same(identity: 'yt:abc', oldIdentity: 'yt:xyz'), isFalse);
  });

  test('live: the same room again, another room', () {
    expect(same(identity: 'live:7', oldIdentity: 'live:7'), isTrue);
    expect(same(identity: 'live:7', oldIdentity: 'live:8'), isFalse);
  });

  test('nothing to tell by: not the same', () {
    expect(same(), isFalse);
  });

  test('a page of one kind after another: never the same', () {
    // a YouTube video after a bilibili one, and back
    expect(same(identity: 'yt:abc', oldCid: 1, oldBvid: 'BV1'), isFalse);
    expect(same(cid: 1, bvid: 'BV1', oldIdentity: 'yt:abc'), isFalse);
    // a live room after a YouTube video
    expect(same(identity: 'live:7', oldIdentity: 'yt:abc'), isFalse);
  });

  group('local files (review 2026-10-21)', () {
    FileSource file(String dir, {String? uri}) => FileSource(
      dir: dir,
      isMp4: true,
      hasDashAudio: false,
      typeTag: '64',
      uri: uri,
    );

    test('a local file is known by its path or document', () {
      expect(
        PlPlayerController.sourceIdentity(file('a', uri: 'content://x/1')),
        'file:content://x/1',
      );
      expect(PlPlayerController.sourceIdentity(file('a')), startsWith('file:'));
      expect(
        PlPlayerController.sourceIdentity(
          NetworkSource(videoSource: 'https://a', audioSource: null),
        ),
        isNull,
      );
    });

    test('two plain files (cid 0, bvid empty) are not the same video', () {
      final a = PlPlayerController.sourceIdentity(file('a'));
      final b = PlPlayerController.sourceIdentity(file('b'));
      expect(
        same(
          cid: 0,
          bvid: '',
          identity: b,
          oldCid: 0,
          oldBvid: '',
          oldIdentity: a,
        ),
        isFalse,
      );
      expect(
        same(
          cid: 0,
          bvid: '',
          identity: a,
          oldCid: 0,
          oldBvid: '',
          oldIdentity: a,
        ),
        isTrue,
      );
    });
  });
}
