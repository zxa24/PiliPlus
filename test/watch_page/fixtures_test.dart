// LibrePili: the offline materials of the watch-page shell's S0b (design
// feature-logs/watch-page-shell/design.md §5 S0b 「素材与前置条件」, and the
// offline snapshot of §5 S0a 「核对」), written here with the app's own
// writers so that they are in the format a real download leaves:
//
//   download/<avid>/c_<cid>/entry.json       BiliDownloadEntryInfo.toJson
//   download/<export>/<export>.mp4           (media, placed by the runner)
//   download/<export>/<export>.comments.json DownloadExtras.replyToJson
//   download/<export>/<export>.intro.json    as DownloadExtras._intro writes
//   download/<export>/librepili.json         as DownloadExtras.export writes
//   cover.jpg in both folders                (media, placed by the runner)
//
// <export> is DownloadService's own export name (title + [quality]). The
// video files and covers are not in the repository: make_media.ps1 makes
// them with ffmpeg into the media folder media.json names, and run.ps1's
// Restore-WpProfile copies a snapshot into a fresh profile, placing them
// as each snapshot's place.json says and turning ${PROFILE_APPDATA} in
// merged_path into the profile's folder (design v7 wp6#13).
//
// The test: every file under test/fixtures/watch_page/<snapshot>/ that is
// made here equals what is made now (WP_FIXTURES_WRITE=1 writes them
// instead); the app's readers read them back (entry, comments, intro); and
// the download page's own controller, on the real download service over
// the list10 snapshot, lists all ten entries in the order R4 expects, with
// the playing one at index 3 of the offline playlist and no saved intro.
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/pages/download/controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/local_intro.dart';
import 'package:PiliPlus/pages/video/reply/local_comments.dart';
import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

import '../services/download/download_test_support.dart';

const fixturesDir = 'test/fixtures/watch_page';

/// Replaced by the profile's appdata folder when a snapshot is restored
/// (run.ps1 Restore-WpProfile).
const appdata = r'${PROFILE_APPDATA}';

/// One completed bilibili download of a single-part ugc video.
class FixtureVideo {
  const FixtureVideo({
    required this.avid,
    required this.cid,
    required this.title,
    required this.width,
    required this.height,
    required this.media,
    required this.cover,
    required this.stamp,
    this.intro = true,
  });

  final int avid;
  final int cid;
  final String title;

  /// The video file's own size (make_media.ps1), as page_data records it.
  final int width;
  final int height;

  /// File names in the media folder (media.json).
  final String media;
  final String cover;

  /// time_update_stamp: the download list is sorted by it, newest first.
  final int stamp;

  /// Whether `<export>.intro.json` is saved (R4's list has none).
  final bool intro;

  String get bvid => IdUtils.av2bv(avid);

  /// Fixture ids next to the download fixtures' (170001...). Not checked
  /// against bilibili (low avids there are real videos): the offline page
  /// plays from the file and is not meant to request anything with them.
  BiliDownloadEntryInfo entry() => BiliDownloadEntryInfo(
    mediaType: 2,
    hasDashAudio: true,
    isCompleted: true,
    totalBytes: 262144,
    downloadedBytes: 262144,
    title: title,
    typeTag: '16',
    cover: '',
    videoQuality: 16,
    preferedVideoQuality: 16,
    qualityPithyDescription: '360P 流畅',
    guessedTotalBytes: 0,
    totalTimeMilli: 6000,
    danmakuCount: 0,
    timeUpdateStamp: stamp,
    timeCreateStamp: stamp - 60,
    canPlayInAdvance: true,
    avid: avid,
    spid: 0,
    bvid: bvid,
    ownerId: 9101,
    ownerName: '夹具UP主',
    pageData: PageInfo(
      cid: cid,
      page: 1,
      from: 'vupload',
      part: title,
      vid: '',
      hasAlias: false,
      tid: 0,
      width: width,
      height: height,
      downloadTitle: '视频已缓存完成',
      downloadSubtitle: title,
    ),
  );

  /// The export folder's (and file's) name, as the download service names
  /// it after a merge.
  String get exportName => DownloadService.exportNameForTest(entry());

  String get entryDir => 'appdata/download/$avid/c_$cid';
  String get exportDir => 'appdata/download/$exportName';
}

/// A profile's data restored before a run: its entries, and where the
/// media go ([place]).
class FixtureSnapshot {
  const FixtureSnapshot(this.name, this.about, this.videos);
  final String name;
  final String about;
  final List<FixtureVideo> videos;
}

final snapshots = [
  const FixtureSnapshot(
    'landscape',
    'one completed 16:9 download with a comment attachment and a saved '
        'intro (design §5 S0b 素材 1; the AC-S0a 核对 snapshot, §5 S0a)',
    [
      FixtureVideo(
        avid: 171001,
        cid: 281001,
        title: '夹具横屏',
        width: 640,
        height: 360,
        media: 'landscape.mp4',
        cover: 'cover_landscape.jpg',
        stamp: 1761100000,
      ),
    ],
  ),
  const FixtureSnapshot(
    'portrait',
    'one completed 9:16 download with a comment attachment and a saved '
        'intro (design §5 S0b 素材 1)',
    [
      FixtureVideo(
        avid: 171002,
        cid: 281002,
        title: '夹具竖屏',
        width: 360,
        height: 640,
        media: 'portrait.mp4',
        cover: 'cover_portrait.jpg',
        stamp: 1761100000,
      ),
    ],
  ),
  FixtureSnapshot(
    'list10',
    'ten completed 16:9 downloads, one video each, the same media file in '
        "each one's folder, comment attachments and no saved intro; listed "
        'newest first, so row k is 夹具列表 k+1 and R4 plays index 3 '
        '(cid 281104) opened from the download page (design §5 S0b 素材 3)',
    [
      for (var k = 0; k < 10; k++)
        FixtureVideo(
          avid: 171101 + k,
          cid: 281101 + k,
          title: '夹具列表 ${(k + 1).toString().padLeft(2, '0')}',
          width: 640,
          height: 360,
          media: 'landscape.mp4',
          cover: 'cover_landscape.jpg',
          stamp: 1761100000 - 100 * k,
          intro: false,
        ),
    ],
  ),
];

/// The list10 entry R4 plays (design: index 3 of the offline playlist).
const r4PlayingCid = 281104;

/// A tiny PNG (1x1): the uploader's avatar as `faces` keeps it, so the
/// offline intro shows one without a request.
const _facePng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const _faceUrl = 'https://i0.hdslb.com/bfs/face/librepili-fixture-face.jpg';

/// Five comments, two with replies; plain text, no pictures or emotes (the
/// offline panel would need their files beside the video).
List<(ReplyInfo, List<ReplyInfo>)> comments(FixtureVideo v) {
  ReplyInfo reply(int n, String name, String text, {int root = 0}) =>
      ReplyInfo(
        id: Int64(v.cid * 100 + n),
        oid: Int64(v.avid),
        type: Int64(1),
        mid: Int64(9200 + n),
        root: Int64(root),
        parent: Int64(root),
        like: Int64(20 - n),
        ctime: Int64(1761000000 + 60 * n),
        count: Int64(root == 0 && n <= 2 ? 2 : 0),
        content: Content(message: text),
        member: Member(mid: Int64(9200 + n), name: name, face: '', level: Int64(4)),
        replyControl: ReplyControl(timeDesc: '2025-10-21', location: 'IP属地：夹具'),
      );
  ReplyInfo root(int n, String name, String text) => reply(n, name, text);
  final a = root(1, '夹具观众甲', '第一条评论：这是离线评论附件里的一条。');
  final b = root(2, '夹具观众乙', '第二条评论，下面有两条回复。');
  final c = root(3, '夹具观众丙', '第三条评论。');
  final d = root(4, '夹具观众丁', '第四条评论，稍长一些，用来占一行以上的宽度，看看换行之后的样子。');
  final e = root(5, '夹具观众戊', '第五条评论。');
  final ra = [
    reply(11, '夹具回复一', '回复第一条。', root: a.id.toInt()),
    reply(12, '夹具回复二', '也回复第一条。', root: a.id.toInt()),
  ];
  final rb = [
    reply(21, '夹具回复三', '回复第二条。', root: b.id.toInt()),
    reply(22, '夹具回复四', '再回复第二条。', root: b.id.toInt()),
  ];
  // the list's own preview of the first replies, as bilibili sends it
  a.replies.addAll(ra.take(1));
  b.replies.addAll(rb.take(1));
  return [(a, ra), (b, rb), (c, []), (d, []), (e, [])];
}

Future<String> commentsJson(FixtureVideo v) async {
  final items = <Map<String, Object?>>[];
  for (final (root, replies) in comments(v)) {
    items.add(
      (await DownloadExtras.replyToJson(root))
        ..['replies'] = [
          for (final r in replies) await DownloadExtras.replyToJson(r),
        ],
    );
  }
  final entry = v.entry();
  // as DownloadExtras._comments writes it
  return const JsonEncoder.withIndent(' ').convert({
    'format': 'librepili-comments-2',
    'oid': entry.avid,
    'bvid': entry.bvid,
    'upMid': ?entry.ownerId,
    'title': entry.showTitle,
    'sort': 'hot',
    'fetchedAt': '2025-10-22T10:00:00.000',
    'count': items.length,
    'comments': items,
  });
}

/// As DownloadExtras._intro writes it: bilibili's own `view` answer (a
/// subset of its keys, the ones the intro shows), no tags or card.
String introJson(FixtureVideo v) => jsonEncode({
  'format': 'librepili-intro-1',
  'fetchedAt': '2025-10-22T10:00:00.000',
  'view': {
    'bvid': v.bvid,
    'aid': v.avid,
    'videos': 1,
    'tid': 0,
    'tname': '夹具',
    'copyright': 1,
    'pic': '',
    'title': v.title,
    'pubdate': 1761000000,
    'ctime': 1761000000,
    'desc': '离线素材的简介（夹具）。',
    'duration': 6,
    'owner': {'mid': 9101, 'name': '夹具UP主', 'face': _faceUrl},
    'stat': {
      'aid': v.avid,
      'view': 1234,
      'danmaku': 0,
      'reply': 5,
      'favorite': 12,
      'coin': 3,
      'share': 1,
      'like': 56,
    },
    'dimension': {'width': v.width, 'height': v.height, 'rotate': 0},
    'cid': v.cid,
    'pages': [
      {
        'cid': v.cid,
        'page': 1,
        'from': 'vupload',
        'part': v.title,
        'duration': 6,
        'dimension': {'width': v.width, 'height': v.height, 'rotate': 0},
      },
    ],
  },
  'faces': {_faceUrl: _facePng},
});

/// As DownloadExtras.export writes `librepili.json`: the record without
/// this device's paths.
String infoJson(FixtureVideo v) => const JsonEncoder.withIndent(' ').convert(
  v.entry().toJson()
    ..remove('merged_path')
    ..remove('merged_parts')
    ..remove('extras_pending')
    ..remove('transcript_pending'),
);

/// The record with its merged file in the restored profile.
String entryJson(FixtureVideo v) => const JsonEncoder.withIndent(' ').convert(
  (v.entry()..mergedPath = path.windows.joinAll([
        appdata,
        'download',
        v.exportName,
        '${v.exportName}.mp4',
      ]))
      .toJson(),
);

/// Every made file of [s], by its path in the snapshot folder.
Future<Map<String, String>> made(FixtureSnapshot s) async {
  final files = <String, String>{};
  final place = <Map<String, String>>[];
  for (final v in s.videos) {
    files['${v.entryDir}/entry.json'] = entryJson(v);
    files['${v.exportDir}/librepili.json'] = infoJson(v);
    files['${v.exportDir}/${v.exportName}${DownloadExtras.commentsSuffix}'] =
        await commentsJson(v);
    if (v.intro) {
      files['${v.exportDir}/${v.exportName}${DownloadExtras.introSuffix}'] =
          introJson(v);
    }
    place
      ..add({'file': v.media, 'to': '${v.exportDir}/${v.exportName}.mp4'})
      ..add({'file': v.cover, 'to': '${v.entryDir}/cover.jpg'})
      ..add({'file': v.cover, 'to': '${v.exportDir}/cover.jpg'});
  }
  files['place.json'] = const JsonEncoder.withIndent('  ').convert({
    'about': s.about,
    'made': 'test/watch_page/fixtures_test.dart (WP_FIXTURES_WRITE=1)',
    'media': '../media.json',
    'place': place,
  });
  return {for (final MapEntry(:key, :value) in files.entries) key: '$value\n'};
}

void main() {
  final write = Platform.environment['WP_FIXTURES_WRITE'] == '1';

  for (final s in snapshots) {
    test('${s.name}: the snapshot files are what the writers make', () async {
      final dir = path.join(fixturesDir, s.name);
      final want = await made(s);
      if (write) {
        final old = Directory(dir);
        if (old.existsSync()) old.deleteSync(recursive: true);
        for (final MapEntry(:key, :value) in want.entries) {
          File(path.join(dir, key))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(value);
        }
      }
      final have = {
        for (final f in Directory(dir).listSync(recursive: true).whereType<File>())
          path.relative(f.path, from: dir).replaceAll(r'\', '/'):
              // a checkout with core.autocrlf has them with CRLF
              f.readAsStringSync().replaceAll('\r\n', '\n'),
      };
      expect(have.keys.toSet(), want.keys.toSet(), reason: 'files of $dir');
      for (final MapEntry(:key, :value) in want.entries) {
        expect(have[key], value, reason: '$dir/$key differs from what the '
            'writers make now (WP_FIXTURES_WRITE=1 rewrites it)');
      }
    });
  }

  test("the app's readers read them back", () {
    for (final s in snapshots) {
      final dir = path.join(fixturesDir, s.name);
      for (final v in s.videos) {
        final entry = BiliDownloadEntryInfo.fromJson(
          jsonDecode(
            File(path.join(dir, v.entryDir, 'entry.json')).readAsStringSync(),
          ),
        );
        expect(entry.isCompleted, isTrue);
        expect(entry.cid, v.cid);
        expect(entry.pageData!.isVertical, v.height > v.width);
        expect(
          entry.mergedPath,
          startsWith(r'${PROFILE_APPDATA}\download\'),
          reason: 'merged_path is rewritten to the profile on restore',
        );
        final comments = LocalComments.parse(
          jsonDecode(
            File(
              path.join(
                dir,
                v.exportDir,
                '${v.exportName}${DownloadExtras.commentsSuffix}',
              ),
            ).readAsStringSync(),
          ),
          path.join(dir, v.exportDir),
        );
        expect(comments, isNotNull, reason: 'format 2, every comment a pb');
        expect(comments!.comments.length, 5);
        expect(comments.comments.first.root.member.name, '夹具观众甲');
        expect(comments.comments.first.replies.length, 2);
        final intro = File(
          path.join(dir, v.exportDir, '${v.exportName}${DownloadExtras.introSuffix}'),
        );
        expect(intro.existsSync(), v.intro);
        if (v.intro) {
          final read = LocalIntro.parse(jsonDecode(intro.readAsStringSync()));
          expect(read, isNotNull);
          expect(read!.view.title, v.title);
          expect(read.face(_faceUrl), isNotNull);
        }
      }
    }
  });

  group('list10 on the download page', () {
    late Directory storage;
    final h = DownloadHarness();
    final list = snapshots.firstWhere((s) => s.name == 'list10');

    setUpAll(() async => storage = await initDownloadStorage());
    tearDownAll(() => closeDownloadStorage(storage));
    tearDown(() async {
      Get.delete<DownloadPageController>(force: true);
      await h.stop();
    });

    test('lists all ten, newest first; R4 plays index 3', () async {
      await h.start(
        fixtures: path.join(fixturesDir, 'list10', 'appdata', 'download'),
        entries: [for (final v in list.videos) '${v.avid}/c_${v.cid}'],
      );
      expect(h.service.downloadList.length, 10);
      final page = Get.put(DownloadPageController());
      for (var i = 0; i < 100 && page.pages.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // one row per video, in the order the list shows them
      expect(
        [for (final p in page.pages) p.title],
        [for (final v in list.videos) v.title],
      );
      expect(page.pages.every((p) => p.entries.length == 1), isTrue);
      final playlist = LocalIntroController.offlinePlaylist(page.pages);
      expect([for (final e in playlist.list) e.cid], [
        for (final v in list.videos) v.cid,
      ]);
      expect(playlist.list.indexWhere((e) => e.cid == r4PlayingCid), 3);
    });
  });
}
