// LibrePili: a YouTube download's extras (design §6, stage 4; AC5, AC9).
// The real export on a fake network: which caption tracks are kept and
// their file names (§10-1, the regional variant as its language, user
// 2026-11-16 「1B」), the intro with and without the `next` answer, the
// comments paced and stopped by a wall (§6.3), the avatars (§6.4), the
// record copy, the transcript beside the video (AC9's step), and a delete
// stopping it before the next request.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models/common/subtitle_source.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/download/yt_extras.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/services/youtube/direct_source.dart';
import 'package:PiliPlus/services/youtube/innertube_client.dart';
import 'package:PiliPlus/services/youtube/invidious_source.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/yt_classifier.dart' show YtSignals;
import 'package:PiliPlus/services/youtube/video_source.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';
import '../youtube/yt_test_support.dart';
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
    if (held.contains(token)) return holdUntilClosed();
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

  /// Each pause's length, in order.
  final pauses = <Duration>[];

  @override
  bool detailAsksDirect = true;

  @override
  Future<void> pause(Duration duration) async {
    pauses.add(duration);
    _ask('pause');
  }

  /// A comment page held until the net is closed (then a failure).
  final held = <String>{};
  final _closing = Completer<void>();

  @override
  void close() {
    closed = true;
    if (!_closing.isCompleted) _closing.complete();
  }

  Future<YtResult<YtPage<YtComment>>> holdUntilClosed() async {
    await _closing.future;
    return const YtResult.failed(YtVerdict(YtCause.transient, 'closed'));
  }
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
    YtExtras.resetSessionForTest();
    YtSourceRouter.sharedHealth.clear();
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
    YtExtras.resetSessionForTest();
    YtSourceRouter.sharedHealth.clear();
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

  /// [name] in the export folder, holding [text].
  void put(String name, String text) =>
      File(path.join(folder, name)).writeAsStringSync(text);

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
      expect(YtExtras.trackOfFile('b.srt', 'b'), isNull);
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
    // the requests one at a time with a pause before each, the first page
    // after `next` too (review 1, l7)
    final asked = net.log.where((l) => !l.startsWith('image')).toList();
    expect(
      asked.sublist(asked.indexOf('comments top-1') - 1),
      [
        'pause',
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
    // the wall `next` met holds for the comments: not asked (review 1, l9)
    expect(
      written['comments'],
      startsWith(
        'error: comments unavailable (skipped, stoppedBy: direct source '
        'cooling down until',
      ),
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
      'error: comments unavailable (no token)',
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

  group('review 1', () {
    // 1 (c3, l4): written whole or not at all
    test('a subtitle whose write fails half-way leaves neither it nor a '
        '.part', () async {
      net.tracks([_track('en'), _track('de')]);
      final written = await IOOverrides.runWithIOOverrides(
        export,
        _HalfWrites('.de.srt'),
      );
      expect(File(path.join(folder, '$base.de.srt')).existsSync(), isFalse);
      expect(
        Directory(folder).listSync().where((e) => e.path.endsWith('.part')),
        isEmpty,
      );
      final subs = written['subtitles']! as Map;
      expect(subs['files'], ['$base.en.srt']);
      expect(subs['failed'], [contains('$base.de.srt')]);
    });

    // 3 (l3): a delete ends the request in flight
    test('a delete closes the network: the request in flight ends, the '
        'export with it', () async {
      YtExtras.cancelPoll = const Duration(milliseconds: 20);
      addTearDown(
        () => YtExtras.cancelPoll = const Duration(milliseconds: 250),
      );
      var deleted = false;
      net
        ..held.add('top-1')
        ..onAsk = (asked) {
          if (asked == 'comments top-1') deleted = true;
        };
      final written = await export(
        cancelled: () => deleted,
      ).timeout(const Duration(seconds: 5));
      expect(net.closed, isTrue);
      expect(written['comments'], 'error: cancelled');
    });

    // 5 (l1): nothing came: no file
    test('a wall on the first page: no comments file, the step says the '
        'comments are unavailable', () async {
      net.pages = {'top-1': const YtResult.failed(_wall)};
      final written = await export();
      expect(
        written['comments'],
        'error: comments unavailable (ipBlocked<http-429> :: test wall)',
      );
      expect(
        File(
          path.join(folder, '$base${YtExtras.commentsSuffix}'),
        ).existsSync(),
        isFalse,
      );
    });

    // 5 (l2): replies that keep failing end the reply phase
    test('three reply answers in a row not ok end the replies; what came '
        'is written, the stop recorded', () async {
      await GStorage.setting.put(SettingBoxKey.dlCommentCount, 5);
      net.pages = {
        'top-1': YtResult.ok(
          YtPage([
            for (final id in ['a', 'b', 'c', 'd', 'e'])
              _comment(id, replies: 'r-$id'),
          ], null),
        ),
        'r-a': YtResult.ok(YtPage([_comment('a1')], null)),
        // r-b, r-c, r-d: no page (clientBroken)
      };
      final written = await export();
      expect(net.log, contains('comments r-d'));
      expect(net.log, isNot(contains('comments r-e')));
      final comments = readJson('$base${YtExtras.commentsSuffix}');
      expect((comments['comments'] as List), hasLength(5));
      expect(comments['stoppedBy'], startsWith('replies: 3 failures in a row'));
      expect(written['comments'], contains('stopped: replies'));
    });

    // 6 (l6): the pages' cooldown is respected, not changed
    test('the pages\' table has the direct source cooling: no `next`, no '
        'comment page; the table is not changed', () async {
      final until = DateTime.now().add(const Duration(minutes: 10));
      YtSourceRouter.sharedHealth['direct'] = YtSourceHealth()
        ..cooldownUntil = until
        ..cooldownStep = 1;
      net.pages = {
        'top-1': YtResult.ok(YtPage([_comment('a')], null)),
      };
      final written = await export();
      expect(net.log, isNot(contains('related')));
      expect(net.log.where((l) => l.startsWith('comments')), isEmpty);
      expect(written['intro'], contains('no extra'));
      expect(
        written['comments'],
        startsWith(
          'error: comments unavailable (skipped, stoppedBy: direct source '
          'cooling down',
        ),
      );
      expect(
        File(
          path.join(folder, '$base${YtExtras.commentsSuffix}'),
        ).existsSync(),
        isFalse,
      );
      final h = YtSourceRouter.sharedHealth['direct']!;
      expect((h.cooldownUntil, h.cooldownStep), (until, 1));
    });

    test('the pages\' table has the direct source cooling: the export\'s '
        'details and captions go to the fallback alone', () async {
      YtSourceRouter.sharedHealth['direct'] = YtSourceHealth()
        ..cooldownUntil = DateTime.now().add(const Duration(minutes: 10));
      final modes = <YtSourceMode>[];
      YtDownloadPlatform.routerForTest = (mode, {required own, required health}) {
        modes.add(mode);
        return YtSourceRouter(_NoNetDirect(), health: health, mode: mode);
      };
      YtDownloadPlatform.extrasNetForTest = (_, _) => net;
      addTearDown(() {
        YtDownloadPlatform.routerForTest = null;
        YtDownloadPlatform.extrasNetForTest = null;
      });
      await YtDownloadPlatform(_NoHost()).extras(
        entry: entry,
        folder: folder,
        base: base,
      );
      expect(modes, [YtSourceMode.fallbackOnly]);
      YtSourceRouter.sharedHealth.clear();
      modes.clear();
      await YtDownloadPlatform(_NoHost()).extras(
        entry: entry,
        folder: folder,
        base: base,
      );
      expect(modes, [YtSourceMode.auto]);
    });

    // 6 (l9): one table for the session, and a gap between exports
    test('a wall one export met stops the next export\'s comments', () async {
      net.pages = {
        'top-1': YtResult.ok(YtPage([_comment('a')], 'top-2')),
        'top-2': const YtResult.failed(_wall),
      };
      await export();
      expect(YtExtras.directWall(), contains('(the comments)'));
      final first = net;
      net = _Net()
        ..pages = {
          'top-1': YtResult.ok(YtPage([_comment('a')], null)),
        };
      final written = await export();
      expect(first.log, contains('comments top-2'));
      expect(net.log, isNot(contains('related')));
      expect(net.log.where((l) => l.startsWith('comments')), isEmpty);
      expect(
        written['comments'],
        startsWith('error: comments unavailable (skipped, stoppedBy:'),
      );
    });

    test('the next export\'s first `next` waits for the gap after the last '
        'one\'s comment traffic', () async {
      var now = DateTime(2026, 11, 17, 12);
      YtExtras.clock = () => now;
      net.pages = {
        'top-1': YtResult.ok(YtPage([_comment('a')], null)),
      };
      await export();
      expect(net.pauses, isNot(contains(YtExtras.exportGap)));
      now = now.add(const Duration(seconds: 10));
      net = _Net()
        ..pages = {
          'top-1': YtResult.ok(YtPage([_comment('a')], null)),
        };
      await export();
      // 30 s after the first ended, 10 s of it gone: 20 s, before `next`
      expect(net.pauses.first, const Duration(seconds: 20));
      expect(net.log.indexOf('pause'), lessThan(net.log.indexOf('related')));
    });

  });

  // review 3: a subtitle file is written only where none of its name is;
  // never written over, never deleted, whoever wrote it
  group('review 3: subtitles written if absent', () {
    test('a run again touches no file there: one of an earlier run, one '
        'the user edited, the user\'s own; it writes the picked one that '
        'is missing', () async {
      put('$base.en.srt', 'an earlier run');
      put('$base.de.srt', 'an earlier run, edited by the user');
      put('$base.fr.srt', "the user's own");
      // an earlier pick's track, not in this pick
      put('$base.ja.srt', 'an earlier pick');
      net.tracks([_track('en'), _track('de'), _track('ko')]);
      final written = await export();
      expect(File(path.join(folder, '$base.en.srt')).readAsStringSync(),
          'an earlier run');
      expect(File(path.join(folder, '$base.de.srt')).readAsStringSync(),
          'an earlier run, edited by the user');
      expect(File(path.join(folder, '$base.fr.srt')).readAsStringSync(),
          "the user's own");
      expect(File(path.join(folder, '$base.ja.srt')).readAsStringSync(),
          'an earlier pick');
      expect(File(path.join(folder, '$base.ko.srt')).readAsStringSync(),
          contains('line .ko'));
      // only the missing one asked for
      expect(net.log.where((l) => l.startsWith('caption')), ['caption .ko']);
      final subs = written['subtitles']! as Map;
      // this pick's files on disk, written now or there already
      expect(subs['files'], [
        '$base.en.srt',
        '$base.de.srt',
        '$base.ko.srt',
      ]);
      expect(subs.containsKey('failed'), isFalse);
    });

    test("another video's files beside an export of `movie`: untouched, "
        'the one of that name is listed as there', () async {
      // `movie.en.mp4`'s side file, and a user's
      put('movie.en.srt', 'its own');
      put('movie.fr.srt', 'its own');
      net.tracks([_track('en'), _track('de')]);
      final written = await YtExtras.export(
        entry: entry,
        folder: folder,
        base: 'movie',
        net: net,
        transcriptKey: SubtitleCacheKey.youtube(entry.videoId),
      );
      for (final name in ['movie.en.srt', 'movie.fr.srt']) {
        expect(
          File(path.join(folder, name)).readAsStringSync(),
          'its own',
          reason: name,
        );
      }
      expect(
        File(path.join(folder, 'movie.de.srt')).readAsStringSync(),
        contains('line .de'),
      );
      expect((written['subtitles']! as Map)['files'], [
        'movie.en.srt',
        'movie.de.srt',
      ]);
      expect(net.log, isNot(contains('caption .en')));
    });

    test('a picked track that fails, its file missing: not listed; the '
        'files listed are the ones on disk', () async {
      net
        ..tracks([_track('en'), _track('de')])
        ..captions = {'.de': const YtResult.failed(_wall)};
      final written = await export();
      final subs = written['subtitles']! as Map;
      expect(subs['files'], ['$base.en.srt']);
      expect(subs['failed'], [contains('$base.de.srt: ipBlocked')]);
      for (final name in subs['files'] as List) {
        expect(File(path.join(folder, name as String)).existsSync(), isTrue);
      }
      expect(srtFiles(), ['$base.en.srt']);
    });

    test('a file of the name that comes while its caption is fetched is '
        'not written over', () async {
      net
        ..tracks([_track('en')])
        ..onAsk = (asked) {
          if (asked == 'caption .en') put('$base.en.srt', 'came meanwhile');
        };
      final written = await export();
      expect(
        File(path.join(folder, '$base.en.srt')).readAsStringSync(),
        'came meanwhile',
      );
      expect((written['subtitles']! as Map)['files'], ['$base.en.srt']);
      expect(
        Directory(folder).listSync().where((e) => e.path.endsWith('.part')),
        isEmpty,
      );
    });

    test('the record has no subtitle list, nor the copy', () async {
      net.tracks([_track('en')]);
      await export();
      expect(entry.toJson().containsKey('written'), isFalse);
      expect(readJson(DownloadExtras.infoName).containsKey('written'), isFalse);
    });
  });

  group('review 2: a delete ends the details and the captions', () {
    final h = DownloadHarness();
    tearDown(() async {
      YtDownloadPlatform.routerForTest = null;
      YtDownloadPlatform.extrasNetForTest = null;
      YtExtras.cancelPoll = const Duration(milliseconds: 250);
      await h.stop();
    });

    /// A YouTube export held in its detail lookup (or its caption fetch),
    /// a bilibili one queued behind it; the YouTube entry deleted.
    Future<void> deleteWhileHeld({required bool caption}) async {
      await h.start();
      YtExtras.cancelPoll = const Duration(milliseconds: 20);
      final held = _HeldSource(holdDetail: !caption);
      YtDownloadPlatform.extrasForTest = null;
      YtDownloadPlatform.routerForTest =
          (mode, {required own, required health}) => YtSourceRouter(
            held,
            health: health,
            mode: mode,
            sleep: (_) async {},
          );
      YtDownloadPlatform.extrasNetForTest = (play, cancelled) =>
          YtExtrasLiveNet(
            play: play,
            direct: _NoNetDirect(),
            cancelled: cancelled,
            sleepForTest: (_) async {},
          );
      File mp4(String dir) => File(path.join(h.root.path, dir, 'v.mp4'))
        ..parent.createSync()
        ..writeAsBytesSync([1]);
      final yt = ytEntry(h.root, completed: true, merged: mp4('yt').path);
      Directory(yt.entryDirPath).createSync(recursive: true);
      final bili = h.entry(fixtureP1)..mergedPath = mp4('bili').path;
      h.service
        ..queueExtrasForTest(yt)
        ..queueExtrasForTest(bili);
      await held.asked.future.timeout(const Duration(seconds: 5));
      expect(h.exported, isEmpty);
      await h.service
          .cancelExtrasForTest(yt.key)
          .timeout(const Duration(seconds: 2));
      await until(() => h.exported.isNotEmpty, reason: "bilibili's export");
      expect(h.exported, [same(bili)]);
    }

    test('held in the detail lookup: the delete returns at once, the '
        'bilibili job behind it starts', () => deleteWhileHeld(caption: false));

    test('held in a caption fetch: the same', () => deleteWhileHeld(caption: true));

    test("the Invidious instance walk of a detail ends once the export's "
        'net is closed', () async {
      final closing = Completer<void>();
      var asked = 0;
      Future<InvidiousAnswer> fetch(
        Uri uri, {
        required String method,
        required Map<String, String> headers,
      }) async {
        asked++;
        await closing.future;
        return const InvidiousAnswer(0, '', error: 'closed');
      }

      final inv = YtInvidiousSource(
        hosts: const ['https://a.example', 'https://b.example'],
        fetch: (uri, {required method, required headers}) =>
            throw StateError('the shared one is not asked'),
      ).fork(fetch: fetch);
      final net = YtExtrasLiveNet(
        play: YtSourceRouter(
          _NoNetDirect(),
          fallback: inv,
          mode: YtSourceMode.fallbackOnly,
        ),
        direct: _NoNetDirect(),
        closeSources: closing.complete,
      );
      final asking = net.detail(ytId);
      // the walk the router started (one per video at a time)
      final walk = inv.detail(ytId);
      await until(() => asked > 0, reason: 'the first instance asked');
      net.close();
      await expectLater(
        asking.timeout(const Duration(seconds: 1)),
        throwsA(isA<YtExtrasCancelled>()),
      );
      final r = await walk.timeout(const Duration(seconds: 2));
      expect(r.ok, isFalse);
    });
  });

  group('review 2: walls and gaps', () {
    // P3: the session's comments table counts for the details too
    test('the comments table alone has the direct source cooling: the '
        "export's details and captions go to the fallback alone", () async {
      YtExtras.commentsHealth['direct'] = YtSourceHealth()
        ..cooldownUntil = DateTime.now().add(const Duration(minutes: 5))
        ..cooldownStep = 1;
      final modes = <YtSourceMode>[];
      YtDownloadPlatform.routerForTest = (mode, {required own, required health}) {
        modes.add(mode);
        return YtSourceRouter(_NoNetDirect(), health: health, mode: mode);
      };
      YtDownloadPlatform.extrasNetForTest = (_, _) => net;
      addTearDown(() {
        YtDownloadPlatform.routerForTest = null;
        YtDownloadPlatform.extrasNetForTest = null;
      });
      await YtDownloadPlatform(_NoHost()).extras(
        entry: entry,
        folder: folder,
        base: base,
      );
      expect(modes, [YtSourceMode.fallbackOnly]);
    });

    // P3: the gap comes before a detail that may go to the direct source
    test("the next export's detail to the direct source waits for the gap "
        "after the last one's traffic there", () async {
      var now = DateTime(2026, 11, 17, 12);
      YtExtras.clock = () => now;
      net.pages = {'top-1': YtResult.ok(YtPage([_comment('a')], null))};
      await export();
      now = now.add(const Duration(seconds: 10));
      net = _Net()
        ..pages = {'top-1': YtResult.ok(YtPage([_comment('a')], null))};
      await export();
      expect(net.log.take(2), ['pause', 'detail']);
      expect(net.pauses.first, const Duration(seconds: 20));
      // once per export: `next` right after it
      expect(net.pauses.where((p) => p == const Duration(seconds: 20)), hasLength(1));
    });

    test('a detail that goes to the fallback alone does not wait', () async {
      var now = DateTime(2026, 11, 17, 12);
      YtExtras.clock = () => now;
      await export();
      now = now.add(const Duration(seconds: 10));
      net = _Net()..detailAsksDirect = false;
      await GStorage.setting.put(SettingBoxKey.dlSaveComments, false);
      await export();
      // the intro's `next` waits; the detail before it did not
      expect(net.log.take(3), ['detail', 'pause', 'related']);
    });

    // P4: the live router's cooldown for a confirmed wall is the one kept
    test("a confirmed wall on the first page: the router's cooldown kept, "
        'not a second step up the ladder', () async {
      final now = DateTime(2026, 11, 17, 12);
      YtExtras.clock = () => now;
      for (final key in [SettingBoxKey.dlSaveCover, SettingBoxKey.dlSaveSubtitle]) {
        await GStorage.setting.put(key, false);
      }
      final direct = _Direct()
        ..relatedAnswer = const YtResult.ok(
          YtRelatedAndComments([], 'top-1', YtVideoExtra()),
        )
        ..answers.add(
          const YtResult.failed(
            YtVerdict(YtCause.ipBlocked, YtSignals.botCheckConfirmed),
          ),
        );
      final live = YtExtrasLiveNet(
        play: YtSourceRouter(_NoNetDirect(), sleep: (_) async {}),
        direct: direct,
        sleepForTest: (_) async {},
      );
      final written = await YtExtras.export(
        entry: entry,
        folder: folder,
        base: base,
        net: live,
        transcriptKey: SubtitleCacheKey.youtube(entry.videoId),
      );
      expect(written['comments'], contains('comments unavailable'));
      final h = YtExtras.commentsHealth['direct']!;
      expect(h.cooldownStep, 1);
      expect(h.cooldownUntil, now.add(ytCooldownLadder.first));
    });

    test('a wall the router did not confirm: one cooldown started, the '
        'first step', () async {
      final now = DateTime(2026, 11, 17, 12);
      YtExtras.clock = () => now;
      net.pages = {'top-1': const YtResult.failed(_wall)};
      await export();
      final h = YtExtras.commentsHealth['direct']!;
      expect(h.cooldownStep, 1);
      expect(h.cooldownUntil, now.add(ytCooldownLadder.first));
    });
  });

  // review 2, item 5: comments a wall kept out are asked for again
  group('review 2: the comments a wall kept out', () {
    final now = DateTime(2026, 11, 17, 12);
    File commentsFile() =>
        File(path.join(folder, '$base${YtExtras.commentsSuffix}'));

    test('a wall at the export: marked to be asked again after the first '
        'cooldown; no comments file; the other extras saved', () async {
      YtExtras.clock = () => now;
      net
        ..tracks([_track('en')])
        ..pages = {'top-1': const YtResult.failed(_wall)};
      final written = await export();
      expect(
        written['comments'],
        'error: comments unavailable (ipBlocked<http-429> :: test wall)',
      );
      expect(commentsFile().existsSync(), isFalse);
      expect(srtFiles(), ['$base.en.srt']);
      expect(entry.commentsPending, isTrue);
      expect(entry.commentsTries, 0);
      expect(entry.commentsAfter, now.add(ytCooldownLadder.first));
      expect(entry.commentsNote, contains('ipBlocked'));
      final json = entry.toJson();
      expect(json['comments_pending'], isTrue);
      expect(json['comments_after'], isA<int>());
    });

    test('a wall known before the export: not asked, marked, asked again '
        'once the wall is over', () async {
      YtExtras.clock = () => now;
      final until = now.add(const Duration(hours: 1));
      YtSourceRouter.sharedHealth['direct'] = YtSourceHealth()
        ..cooldownUntil = until;
      await export();
      expect(net.log.where((l) => l.startsWith('comments')), isEmpty);
      expect(entry.commentsPending, isTrue);
      expect(entry.commentsAfter, until);
    });

    test('not a wall (the video has no comments): not marked', () async {
      net.relatedAnswer = const YtResult.ok(
        YtRelatedAndComments([], null, YtVideoExtra()),
      );
      entry.commentsPending = true;
      await export();
      expect(entry.commentsPending, isFalse);
      expect(entry.toJson().containsKey('comments_pending'), isFalse);
    });

    test("the export folder's copy leaves the retry state out", () async {
      entry
        ..commentsPending = true
        ..commentsTries = 1
        ..commentsAfter = now
        ..commentsNote = 'a wall';
      await GStorage.setting.put(SettingBoxKey.dlSaveComments, false);
      await export();
      final info = readJson(DownloadExtras.infoName);
      for (final key in [
        'comments_pending',
        'comments_tries',
        'comments_after',
        'comments_note',
      ]) {
        expect(info.containsKey(key), isFalse, reason: key);
      }
    });

    Future<Map<String, Object?>> again() => YtExtras.exportComments(
      entry: entry,
      folder: folder,
      base: base,
      net: net,
    );

    test('asked again and saved: only the comments asked for, the mark '
        'cleared', () async {
      entry
        ..commentsPending = true
        ..commentsTries = 1;
      net.pages = {'top-1': YtResult.ok(YtPage([_comment('a')], null))};
      final written = await again();
      expect(written['comments'], startsWith('1 comments'));
      expect(commentsFile().existsSync(), isTrue);
      expect(net.log.where((l) => l == 'detail' || l.startsWith('caption')), isEmpty);
      expect(entry.commentsPending, isFalse);
      expect(entry.commentsTries, 0);
      expect(entry.commentsNote, isNull);
    });

    test('still walled when asked again: not asked, not counted, asked once '
        'the wall is over', () async {
      YtExtras.clock = () => now;
      final until = now.add(const Duration(minutes: 40));
      YtExtras.commentsHealth['direct'] = YtSourceHealth()
        ..cooldownUntil = until;
      entry
        ..commentsPending = true
        ..commentsTries = 1;
      await again();
      expect(net.log, isEmpty);
      expect(entry.commentsPending, isTrue);
      expect(entry.commentsTries, 1);
      expect(entry.commentsAfter, until);
    });

    test('three tries that fail: the mark cleared, the reason kept',
        () async {
      var at = now;
      YtExtras.clock = () => at;
      entry.commentsPending = true;
      for (var i = 1; i <= YtExtras.commentRetries; i++) {
        // past the cooldown the last try met
        at = at.add(const Duration(hours: 7));
        net = _Net()..pages = {'top-1': const YtResult.failed(_wall)};
        await again();
        expect(net.log, contains('comments top-1'), reason: 'try $i');
        if (i < YtExtras.commentRetries) {
          expect(entry.commentsPending, isTrue, reason: 'try $i');
          expect(entry.commentsTries, i);
          expect(
            entry.commentsAfter,
            at.add(ytCooldownLadder[i]),
            reason: 'try $i: on the ladder',
          );
        }
      }
      expect(entry.commentsPending, isFalse);
      expect(entry.commentsNote, startsWith('given up after 3 tries: ipBlocked'));
      expect(commentsFile().existsSync(), isFalse);
      final back = YtDownloadEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>,
      );
      expect(back.commentsPending, isFalse);
      expect(back.commentsNote, entry.commentsNote);
    });

    test('the video gone: given up without a request', () async {
      entry.commentsPending = true;
      File(entry.mergedPath!).deleteSync();
      await again();
      expect(net.log, isEmpty);
      expect(entry.commentsPending, isFalse);
      expect(entry.commentsNote, contains('the video is gone'));
    });
  });

  group('review 2: the comments asked for again, by the service', () {
    final h = DownloadHarness();
    tearDown(() async {
      YtDownloadPlatform.routerForTest = null;
      YtDownloadPlatform.extrasNetForTest = null;
      await h.stop();
    });

    test('the next launch, the wall over: only the comments asked for; the '
        'mark cleared; the other files as they were', () async {
      net.pages = {'top-1': YtResult.ok(YtPage([_comment('a')], null))};
      YtDownloadPlatform.routerForTest =
          (mode, {required own, required health}) =>
              YtSourceRouter(_NoNetDirect(), health: health, mode: mode);
      YtDownloadPlatform.extrasNetForTest = (_, _) => net;
      late File record;
      late Directory export;
      final before = <String, (String, DateTime)>{};
      await h.start(
        entries: const [],
        before: (root) {
          export = Directory(path.join(root.path, base))..createSync();
          final mp4 = File(path.join(export.path, '$base.mp4'))
            ..writeAsBytesSync([1]);
          for (final (name, text) in [
            (DownloadExtras.infoName, '{"the": "copy"}'),
            ('$base${YtExtras.introSuffix}', '{"the": "intro"}'),
            ('$base.en.srt', 'the subtitle'),
            ('cover.jpg', 'the cover'),
          ]) {
            final f = File(path.join(export.path, name))
              ..writeAsStringSync(text);
            before[name] = (text, f.lastModifiedSync());
          }
          record = writeYtRecord(
            root,
            ytEntry(root, completed: true, merged: mp4.path)
              ..commentsPending = true
              ..commentsTries = 1
              ..commentsAfter = DateTime(2026)
              ..commentsNote = 'ipBlocked',
          );
        },
      );
      Map<String, dynamic>? onDisk() {
        try {
          return jsonDecode(record.readAsStringSync()) as Map<String, dynamic>;
        } on FormatException {
          return null;
        } on FileSystemException {
          return null;
        }
      }

      await until(() {
        final json = onDisk();
        return json != null && json['comments_pending'] == null;
      }, reason: 'the record without the mark');
      final e = h.service.downloadList.single as YtDownloadEntry;
      expect(e.commentsPending, isFalse);
      expect(e.status, DownloadStatus.completed);
      expect(onDisk()!['extras_pending'], isFalse);
      final comments = File(
        path.join(export.path, '$base${YtExtras.commentsSuffix}'),
      );
      expect(comments.existsSync(), isTrue);
      expect(
        net.log.where((l) => !l.startsWith('image') && l != 'pause'),
        ['related', 'comments top-1'],
      );
      for (final MapEntry(key: name, value: (text, at)) in before.entries) {
        final f = File(path.join(export.path, name));
        expect(f.readAsStringSync(), text, reason: name);
        expect(f.lastModifiedSync(), at, reason: name);
      }
      expect(h.exported, isEmpty, reason: 'no whole export');
      expect(h.service.extrasQueue, isEmpty);
    });
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

/// A direct source that answers comment pages from [answers] and is never
/// on the network.
class _Direct extends YtDirectSource {
  _Direct() : super(InnertubeClient(FakeYtTransport((_) => throw StateError('no network'))));

  final answers = <YtResult<YtPage<YtComment>>>[];
  var asked = 0;

  /// The `next` answer; null: not to be asked.
  YtResult<YtRelatedAndComments>? relatedAnswer;

  @override
  Future<YtResult<YtRelatedAndComments>> related(String videoId) async =>
      relatedAnswer ?? (throw StateError('related not expected'));

  @override
  Future<YtResult<YtPage<YtComment>>> comments(String token) async {
    asked++;
    return answers.removeAt(0);
  }

  @override
  void close() {}
}

/// A source whose detail (or, with [holdDetail] false, whose caption
/// fetch) never answers.
class _HeldSource extends YtDirectSource {
  _HeldSource({required this.holdDetail})
    : super(InnertubeClient(FakeYtTransport((_) => throw StateError('no network'))));

  final bool holdDetail;
  final asked = Completer<void>();

  @override
  Future<YtResult<YtVideoDetail>> detail(String videoId) async {
    if (!holdDetail) return YtResult.ok(_Net._detailWith([_track('en')]));
    if (!asked.isCompleted) asked.complete();
    return Completer<YtResult<YtVideoDetail>>().future;
  }

  @override
  Future<YtResult<String>> captionContent(
    YtCaptionTrack track, {
    YtCaptionFormat format = YtCaptionFormat.vtt,
    String? translateTo,
  }) {
    if (!asked.isCompleted) asked.complete();
    return Completer<YtResult<String>>().future;
  }

  @override
  void close() {}
}

/// The play router's source in these tests: never asked.
class _NoNetDirect extends YtDirectSource {
  _NoNetDirect()
    : super(InnertubeClient(FakeYtTransport((_) => throw StateError('no network'))));

  @override
  void close() {}
}

class _NoHost extends Fake implements DownloadHost {}

/// Files whose path contains [part] are written half-way, then the write
/// fails (a disk filling up).
final class _HalfWrites extends IOOverrides {
  _HalfWrites(this.part);

  final String part;

  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path.contains(part) ? _HalfFile(real) : real;
  }
}

class _HalfFile implements File {
  _HalfFile(this._real);

  final File _real;

  @override
  String get path => _real.path;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await _real.writeAsString(contents.substring(0, contents.length ~/ 2));
    throw const FileSystemException('the disk is full (test)');
  }

  @override
  bool existsSync() => _real.existsSync();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);

  @override
  Future<File> rename(String newPath) => _real.rename(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_HalfFile.${invocation.memberName}');
}
