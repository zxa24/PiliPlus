// LibrePili: a YouTube download's extras (design §6, stage 4; AC5, AC9).
// The real export on a fake network: which caption tracks are kept and
// their file names (§10-1, the regional variant as its language, user
// 2026-11-16 「1B」), the intro with and without the `next` answer, the
// comments paced and stopped by a wall (§6.3), the avatars (§6.4), the
// record copy, the transcript beside the video (AC9's step), and a delete
// stopping it before the next request.
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/subtitle_source.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:PiliPlus/services/download/yt_extras.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/services/youtube/direct_source.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/video_source.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

YtCaptionTrack _track(String lang, {bool auto = false, String? name}) =>
    YtCaptionTrack(
      languageCode: lang,
      baseUrl: 'https://www.youtube.com/api/timedtext?lang=$lang'
          '${auto ? '&kind=asr' : ''}&n=${name ?? ''}',
      vssId: auto ? 'a.$lang' : '.$lang',
      name: name ?? lang,
      translatable: true,
    );

String _vtt(String text) =>
    'WEBVTT\n\n00:00:01.000 --> 00:00:02.500\n$text\n';

YtComment _comment(String id, {String? replies, String? avatar}) => YtComment(
  commentId: id,
  author: '@$id',
  authorChannelId: 'UC$id',
  authorAvatar: YtThumbnail(
    url: avatar ?? 'https://yt3.ggpht.com/$id=s176-c-k-c0x00ffffff-no-rj',
  ),
  content: 'comment $id',
  likeCountText: '3',
  publishedText: '1 day ago',
  replyCount: replies == null ? 0 : 2,
  replyToken: replies,
);

const _wall = YtVerdict(YtCause.ipBlocked, 'http-429', 'test wall');

/// What the extras asked, in order; the answers set per test.
class _Net implements YtExtrasNet {
  final log = <String>[];
  var closed = false;

  YtResult<YtVideoDetail> detailAnswer = YtResult.ok(_detailWith());
  YtResult<YtRelatedAndComments> relatedAnswer = const YtResult.ok(
    YtRelatedAndComments(
      [],
      'top-1',
      YtVideoExtra(
        dateText: '25 Oct 2009',
        viewCountText: '1,818 views',
        subscriberText: '4.54m subscribers',
        ownerAvatar: YtThumbnail(
          url: 'https://yt3.ggpht.com/owner=s240-c-k-c0x00ffffff-no-rj',
        ),
      ),
    ),
  );
  Map<String, YtResult<YtPage<YtComment>>> pages = {};
  Map<String, YtResult<String>> captions = {};
  Map<String, List<int>> imageBytes = {};
  void Function(String asked)? onAsk;

  static YtVideoDetail _detailWith([List<YtCaptionTrack> tracks = const []]) =>
      YtVideoDetail(
        videoId: ytId,
        title: 'Never Gonna Give You Up',
        author: 'Rick Astley',
        channelId: 'UCuAXFkgsw1L7xaCfnd5JJOw',
        duration: const Duration(seconds: 213),
        thumbnails: const [],
        formats: const [],
        captionTracks: tracks,
        isLive: false,
        expiresIn: Duration.zero,
        description: 'the description',
        viewCount: 1818,
      );

  void tracks(List<YtCaptionTrack> tracks) =>
      detailAnswer = YtResult.ok(_detailWith(tracks));

  void _ask(String what) {
    log.add(what);
    onAsk?.call(what);
  }

  @override
  Future<YtRoutedResult<YtVideoDetail>> detail(String videoId) async {
    _ask('detail');
    return YtRoutedResult(detailAnswer, null);
  }

  @override
  Future<YtResult<String>> captionContent(
    YouTubeVideoSource? source,
    YtCaptionTrack track,
  ) async {
    _ask('caption ${track.vssId}');
    return captions[track.vssId] ?? YtResult.ok(_vtt('line ${track.vssId}'));
  }

  @override
  Future<YtResult<YtRelatedAndComments>> related(String videoId) async {
    _ask('related');
    return relatedAnswer;
  }

  @override
  Future<YtResult<YtPage<YtComment>>> comments(String token) async {
    _ask('comments $token');
    return pages[token] ??
        const YtResult.failed(YtVerdict(YtCause.clientBroken, 'no-page'));
  }

  @override
  Future<List<int>> image(Uri uri, {required int maxBytes}) async {
    _ask('image ${uri.path}');
    final bytes = imageBytes[uri.toString()] ?? List.filled(100, 7);
    if (bytes.length > maxBytes) throw const HttpException('over the cap');
    return bytes;
  }

  @override
  Future<void> pause(Duration duration) async => _ask('pause');

  @override
  void close() => closed = true;
}

void main() {
  late Directory storage;
  late Directory root;
  late String folder;
  late _Net net;
  late YtDownloadEntry entry;
  const base = 'Never Gonna Give You Up [360p]';

  setUpAll(() async {
    storage = await initDownloadStorage(inMemory: true);
  });
  tearDownAll(() => closeDownloadStorage(storage));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yt-extras-');
    folder = path.join(root.path, base);
    Directory(folder).createSync();
    final mp4 = File(path.join(folder, '$base.mp4'))..writeAsBytesSync([1]);
    entry = ytEntry(root, completed: true, merged: mp4.path);
    Directory(entry.entryDirPath).createSync(recursive: true);
    File(
      path.join(entry.entryDirPath, PathUtils.coverName),
    ).writeAsBytesSync([0xff, 0xd8]);
    net = _Net();
    SubtitleCache.debugInstance = SubtitleCache(
      Directory(path.join(root.path, 'subtitle_cache')),
    );
    for (final key in [
      SettingBoxKey.dlSaveCover,
      SettingBoxKey.dlSaveSubtitle,
      SettingBoxKey.dlSaveComments,
    ]) {
      await GStorage.setting.put(key, true);
    }
    await GStorage.setting.put(SettingBoxKey.dlCommentCount, 3);
    await GStorage.setting.put(SettingBoxKey.dlReplyCount, 2);
  });
  tearDown(() async {
    SubtitleCache.debugInstance = null;
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, Object?>> export({bool Function()? cancelled}) =>
      YtExtras.export(
        entry: entry,
        folder: folder,
        base: base,
        net: net,
        transcriptKey: SubtitleCacheKey.youtube(entry.videoId),
        cancelled: cancelled,
      );

  Map<String, dynamic> readJson(String name) =>
      jsonDecode(File(path.join(folder, name)).readAsStringSync())
          as Map<String, dynamic>;

  List<String> srtFiles() =>
      Directory(folder)
          .listSync()
          .map((e) => path.basename(e.path))
          .where((n) => n.endsWith('.srt'))
          .toList()
        ..sort();

  group('the caption tracks kept (§10-1)', () {
    List<String> names(List<YtCaptionTrack> tracks) => [
      for (final p in YtExtras.pickTracks(tracks, 'b')) p.name,
    ];

    test('original authored, Chinese, original automatic, the rest in the '
        'order listed; en-GB counts as the automatic en (1B)', () {
      expect(
        names([
          _track('fr'),
          _track('zh-Hant'),
          _track('en-GB'),
          _track('de'),
          _track('zh-Hans'),
          _track('en', auto: true),
        ]),
        [
          'b.en-GB.srt',
          'b.zh-Hant.srt',
          'b.zh-Hans.srt',
          'b.en.auto.srt',
          'b.fr.srt',
          'b.de.srt',
        ],
      );
    });

    test('at most 10: the original and Chinese tracks before the rest', () {
      final many = [
        for (final l in ['ar', 'bg', 'cs', 'da', 'de', 'el', 'es', 'fi', 'fr'])
          _track(l),
        _track('zh-CN'),
        _track('ja'),
        _track('ja', auto: true),
      ];
      expect(names(many), [
        'b.ja.srt',
        'b.zh-CN.srt',
        'b.ja.auto.srt',
        'b.ar.srt',
        'b.bg.srt',
        'b.cs.srt',
        'b.da.srt',
        'b.de.srt',
        'b.el.srt',
        'b.es.srt',
      ]);
    });

    test('no automatic track: no original language, Chinese first', () {
      expect(names([_track('fr'), _track('zh'), _track('en')]), [
        'b.zh.srt',
        'b.fr.srt',
        'b.en.srt',
      ]);
    });

    test('authored and automatic of one code apart; a second authored one '
        'numbered; never the transcript\'s name', () {
      final picked = names([
        _track('en', name: 'English'),
        _track('en', auto: true),
        _track('en', name: 'English (CC)'),
        _track('pt.BR'),
        _track('asr'),
      ]);
      expect(picked, [
        'b.en.srt',
        'b.en.2.srt',
        'b.en.auto.srt',
        'b.pt_BR.srt',
        'b.asr_.srt',
      ]);
      expect(picked.toSet(), hasLength(picked.length));
    });

    test('the offline page reads each name back (§7.1)', () {
      expect(YtExtras.trackOfFile('b.en.srt', 'b'), (
        lang: 'en',
        source: SubtitleSource.author,
      ));
      expect(YtExtras.trackOfFile('b.en.2.srt', 'b'), (
        lang: 'en',
        source: SubtitleSource.author,
      ));
      expect(YtExtras.trackOfFile('b.en.auto.srt', 'b'), (
        lang: 'en',
        source: SubtitleSource.platform,
      ));
      expect(YtExtras.trackOfFile('b.asr.srt', 'b'), isNull);
      expect(YtExtras.trackOfFile('b.en.x.srt', 'b'), isNull);
      expect(YtExtras.trackOfFile('other.en.srt', 'b'), isNull);
    });
  });

  test('everything saved: record copy, intro with its face, cover, '
      'subtitles, comments with replies and avatars', () async {
    net
      ..tracks([_track('en'), _track('en', auto: true), _track('de')])
      ..pages = {
      'top-1': YtResult.ok(
        YtPage([_comment('a', replies: 'r-a'), _comment('b')], 'top-2'),
      ),
      'top-2': YtResult.ok(YtPage([_comment('c'), _comment('d')], 'top-3')),
      'r-a': YtResult.ok(YtPage([_comment('a1')], 'r-a2')),
      'r-a2': YtResult.ok(YtPage([_comment('a2'), _comment('a3')], null)),
    };
    final written = await export();

    // the record, without this device's paths; not a bilibili record
    final info = readJson(DownloadExtras.infoName);
    expect(info['platform'], 'youtube');
    for (final key in [
      'merged_path',
      'merged_parts',
      'extras_pending',
      'transcript_pending',
    ]) {
      expect(info.containsKey(key), isFalse, reason: key);
    }
    expect(() => BiliDownloadEntryInfo.fromJson(info), throwsA(anything));

    final intro = readJson('$base${YtExtras.introSuffix}');
    expect(intro['format'], 'librepili-yt-intro-1');
    expect(intro['description'], 'the description');
    expect(intro['published'], '25 Oct 2009');
    expect(intro['subscriberText'], '4.54m subscribers');
    expect((intro['faces'] as Map).keys, [
      'https://yt3.ggpht.com/owner=s240-c-k-c0x00ffffff-no-rj',
    ]);
    // the face asked at 88 px
    expect(net.log, contains('image /owner=s88-c-k-c0x00ffffff-no-rj'));

    expect(File(path.join(folder, 'cover.jpg')).existsSync(), isTrue);

    expect(srtFiles(), ['$base.de.srt', '$base.en.auto.srt', '$base.en.srt']);
    expect(
      (written['subtitles']! as Map)['files'],
      unorderedEquals(srtFiles()),
    );
    expect(
      File(path.join(folder, '$base.en.srt')).readAsStringSync(),
      contains('line .en'),
    );

    final comments = readJson('$base${YtExtras.commentsSuffix}');
    expect(comments['format'], 'librepili-yt-comments-1');
    final list = (comments['comments'] as List).cast<Map>();
    // dlCommentCount 3, dlReplyCount 2
    expect(list.map((c) => c['id']), ['a', 'b', 'c']);
    expect((list.first['replies'] as List).map((r) => (r as Map)['id']), [
      'a1',
      'a2',
    ]);
    final avatar = list.first['avatarFile'] as String;
    expect(avatar, startsWith('comments_images/'));
    expect(File(path.join(folder, avatar)).existsSync(), isTrue);
    expect(
      Directory(path.join(folder, 'comments_images'))
          .listSync()
          .where((e) => e.path.endsWith('.part')),
      isEmpty,
    );
    // the requests one at a time with a pause before each but the first:
    // page 2, and each of the two reply requests
    final asked = net.log.where((l) => !l.startsWith('image')).toList();
    expect(
      asked.sublist(asked.indexOf('comments top-1')),
      [
        'comments top-1',
        'pause',
        'comments top-2',
        'pause',
        'comments r-a',
        'pause',
        'comments r-a2',
      ],
    );
    // one `next` for the intro and the comments both
    expect(net.log.where((l) => l == 'related'), hasLength(1));
    expect(net.log.where((l) => l == 'detail'), hasLength(1));
    expect(net.closed, isTrue);
  });

  test('the `next` answer refused: the intro without its extra, no '
      'comments file, the other steps saved', () async {
    net
      ..relatedAnswer = const YtResult.failed(_wall)
      ..tracks([_track('en')]);
    final written = await export();
    expect(written['intro'], contains('no extra (ipBlocked<http-429>'));
    final intro = readJson('$base${YtExtras.introSuffix}');
    expect(intro['title'], 'Never Gonna Give You Up');
    expect(intro.containsKey('published'), isFalse);
    expect(intro['faces'], isEmpty);
    expect(
      written['comments'],
      'error: Bad state: comments unavailable (ipBlocked<http-429> :: test wall)',
    );
    expect(
      File(path.join(folder, '$base${YtExtras.commentsSuffix}')).existsSync(),
      isFalse,
    );
    expect(srtFiles(), ['$base.en.srt']);
    expect(net.log.where((l) => l.startsWith('comments')), isEmpty);
  });

  test('comments off for the video (no token): recorded, nothing written',
      () async {
    net.relatedAnswer = const YtResult.ok(
      YtRelatedAndComments([], null, YtVideoExtra()),
    );
    final written = await export();
    expect(
      written['comments'],
      'error: Bad state: comments unavailable (no token)',
    );
  });

  test('a wall on a later page stops the comments: what came is written, '
      'nothing asked after it (§6.3)', () async {
    await GStorage.setting.put(SettingBoxKey.dlCommentCount, 200);
    net.pages = {
      'top-1': YtResult.ok(
        YtPage([_comment('a', replies: 'r-a'), _comment('b')], 'top-2'),
      ),
      'top-2': const YtResult.failed(_wall),
      'r-a': YtResult.ok(YtPage([_comment('a1')], null)),
    };
    final written = await export();
    expect(written['comments'], contains('stopped: ipBlocked<http-429>'));
    final comments = readJson('$base${YtExtras.commentsSuffix}');
    expect((comments['comments'] as List), hasLength(2));
    expect(comments['stoppedBy'], contains('ipBlocked'));
    // no reply asked once the wall was met
    expect(net.log, isNot(contains('comments r-a')));
  });

  test('a wall on a reply: no reply asked after it', () async {
    net.pages = {
      'top-1': YtResult.ok(
        YtPage([
          _comment('a', replies: 'r-a'),
          _comment('b', replies: 'r-b'),
        ], null),
      ),
      'r-a': const YtResult.failed(_wall),
      'r-b': YtResult.ok(YtPage([_comment('b1')], null)),
    };
    await export();
    expect(net.log, contains('comments r-a'));
    expect(net.log, isNot(contains('comments r-b')));
  });

  test('a caption that fails is recorded, the others saved', () async {
    net
      ..tracks([_track('en'), _track('de')])
      ..captions = {'.de': const YtResult.failed(_wall)};
    final written = await export();
    final subs = written['subtitles']! as Map;
    expect(subs['files'], ['$base.en.srt']);
    expect(subs['failed'], [contains('$base.de.srt: ipBlocked')]);
  });

  test('an avatar over 64 KB or from another host is not saved, no .part '
      'left', () async {
    net
      ..pages = {
        'top-1': YtResult.ok(
          YtPage([
            _comment('a', avatar: 'https://yt3.ggpht.com/big=s88'),
            _comment('b', avatar: 'https://example.com/b.jpg'),
            _comment('c', avatar: 'https://yt3.googleusercontent.com/c=s48'),
          ], null),
        ),
      }
      ..imageBytes = {
        'https://yt3.ggpht.com/big=s88': List.filled(64 * 1024 + 1, 1),
      };
    await export();
    final list = (readJson('$base${YtExtras.commentsSuffix}')['comments']
            as List)
        .cast<Map>();
    expect(list[0].containsKey('avatarFile'), isFalse);
    expect(list[1].containsKey('avatarFile'), isFalse);
    expect(list[2]['avatarFile'], startsWith('comments_images/'));
    expect(net.log, isNot(contains(startsWith('image /b.jpg'))));
    final dir = Directory(path.join(folder, 'comments_images'));
    expect(dir.listSync(), hasLength(1));
  });

  test('a delete stops it before the next request', () async {
    net.pages = {
      'top-1': YtResult.ok(YtPage([_comment('a')], 'top-2')),
      'top-2': YtResult.ok(YtPage([_comment('b')], null)),
    };
    var deleted = false;
    net.onAsk = (asked) {
      if (asked == 'comments top-1') deleted = true;
    };
    final written = await export(cancelled: () => deleted);
    expect(net.log, isNot(contains('comments top-2')));
    expect(written['comments'], 'error: cancelled');
    expect(
      File(path.join(folder, '$base${YtExtras.commentsSuffix}')).existsSync(),
      isFalse,
    );
  });

  test('the transcript the cache has of the video is written beside it '
      '(AC9: `yt:<id>`)', () async {
    final cache = SubtitleCache.instance;
    final kept = await cache.open(
      SubtitleCacheKey.youtube(entry.videoId),
      AsrService.recogniserId,
    );
    final store = TranscriptStore();
    final run = store.startRun(0);
    store
      ..addSegment(
        run,
        1,
        2,
        const [AsrCue(from: 1, to: 3, content: 'transcribed online first')],
        language: 'en',
        weight: 10,
      )
      ..advance(run, 30);
    run.finish();
    kept.captureTranscript(store);
    await cache.save(kept);

    final written = await export();
    final srt = File(path.join(folder, '$base.asr.srt'));
    expect(srt.readAsStringSync(), contains('transcribed online first'));
    expect((written['subtitles']! as Map)['files'], contains('$base.asr.srt'));
  });

  test('the switches off: only the record and the intro', () async {
    for (final key in [
      SettingBoxKey.dlSaveCover,
      SettingBoxKey.dlSaveSubtitle,
      SettingBoxKey.dlSaveComments,
    ]) {
      await GStorage.setting.put(key, false);
    }
    final written = await export();
    expect(written.keys, ['intro']);
    expect(YtExtras.plan().keys, ['intro']);
    expect(net.log.where((l) => l.startsWith('comments')), isEmpty);
    expect(net.log.where((l) => l.startsWith('caption')), isEmpty);
  });

  test('the plan: no danmaku, no preview (2A)', () {
    expect(YtExtras.plan().keys, isNot(contains('danmaku')));
    expect(YtExtras.plan().keys, isNot(contains('preview')));
  });

  test('the live network keeps the comments\' health apart from the '
      'pages\' shared table', () {
    final play = YtSourceRouter(YtDirectSource.create());
    final live = YtExtrasLiveNet(play: play);
    expect(identical(live.commentsHealth, YtSourceRouter.sharedHealth), isFalse);
    expect(identical(live.commentsHealth, play.health), isFalse);
    live.close();
    (play.direct as YtDirectSource).close();
  });

  test('avatar sizes above 88 px are asked at 88', () {
    expect(
      YtExtras.smallAvatar('https://yt3.ggpht.com/x=s176-c-k-c0x00ffffff-no-rj'),
      'https://yt3.ggpht.com/x=s88-c-k-c0x00ffffff-no-rj',
    );
    expect(
      YtExtras.smallAvatar('https://yt3.ggpht.com/x=s48-c-k'),
      'https://yt3.ggpht.com/x=s48-c-k',
    );
    expect(YtExtras.isImageHost(Uri.parse('https://yt3.ggpht.com/a')), isTrue);
    expect(YtExtras.isImageHost(Uri.parse('http://yt3.ggpht.com/a')), isFalse);
    expect(YtExtras.isImageHost(Uri.parse('https://evilggpht.com/a')), isFalse);
  });
}
