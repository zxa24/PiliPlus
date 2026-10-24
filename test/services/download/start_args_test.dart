// LibrePili: what a start hands the transfers and writes on its way (design
// feature-logs/download-platforms/design.md, §3.3 and AC1 开始时的参数):
// the size a saved partial was written for, the dash video and audio
// transfers, the width and height of the stream picked, the stream index,
// and the durl segments one after another. The self tests download for
// real and do not see these.
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/bili_download_media_file_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';

Map<String, Object?> queued(String entry, Map<String, dynamic> json) => {
  ...json,
  'is_completed': false,
  'downloaded_bytes': 0,
};

/// A durl play URL of segments of [sizes] bytes.
Type1 durlPlan(List<int> sizes) => Type1(
  availablePeriodMilli: 0,
  description: '',
  format: 'mp4',
  intact: true,
  isDownloaded: false,
  isResolved: true,
  marlinToken: '',
  needLogin: false,
  needVip: false,
  parseTimestampMilli: 0,
  playerCodecConfigList: const [],
  playerError: 0,
  quality: 80,
  segmentList: [
    for (final (i, size) in sizes.indexed)
      Type1Segment(
        backupUrls: const [],
        bytes: size,
        md5: '',
        metaUrl: '',
        order: i + 1,
        url: 'https://upos.example/segment-$i.mp4',
      ),
  ],
  timeLength: 0,
  videoCodecId: 7,
  videoProject: false,
);

void main() {
  late Directory storage;
  final h = DownloadHarness();

  setUpAll(() async => storage = await initDownloadStorage());
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  late BiliDownloadEntryInfo p1;
  late BiliDownloadEntryInfo s;

  /// The transfers left running unless a test says otherwise.
  Future<void> start() async {
    h.onTransport = (_) {};
    await h.start(patch: queued);
    p1 = h.entry(fixtureP1);
    s = h.entry(fixtureS);
  }

  String streamDir(BiliDownloadEntryInfo e) =>
      path.join(e.entryDirPath, e.streamTypeTag);

  test('the size a saved partial was written for, while the quality is '
      'the same', () async {
    await start();
    final total = p1.totalBytes;
    expect(total, greaterThan(0));
    h.service.startDownload(p1);
    await until(() => h.transports.length == 1);
    expect(h.transports.single.expectedTotal, total);

    // another quality this time (the play URL writes it into the entry)
    h.plan = (e) {
      e.typeTag = '64';
      return dashPlan(id: 64);
    };
    h.service.startDownload(p1);
    await until(() => h.transports.length == 2);
    expect(h.transports.first.cancels, [false]);
    expect(h.transports.last.expectedTotal, 0);
    expect(path.dirname(h.transports.last.path), endsWith('64'));
  });

  test('dash: a video and an audio transfer at once, into the stream '
      'folder; no audio, one transfer', () async {
    await start();
    h.plan = (_) => dashPlan(audio: true);
    h.service.startDownload(p1);
    await until(() => h.transports.length == 2);
    expect(
      [for (final t in h.transports) t.path],
      [
        path.join(streamDir(p1), 'video.m4s'),
        path.join(streamDir(p1), 'audio.m4s'),
      ],
    );
    expect(h.transports.first.url, 'https://upos.example/video-80.m4s');
    expect(h.transports.first.backupUrls, [
      'https://upos-backup.example/video.m4s',
    ]);
    expect(h.transports.last.url, 'https://upos.example/audio.m4s');

    h.plan = (_) => dashPlan();
    h.service.startDownload(s);
    await until(() => h.transportsOf(s).isNotEmpty);
    await settle();
    expect(
      [for (final t in h.transportsOf(s)) path.basename(t.path)],
      ['video.m4s'],
    );
  });

  /// [entry]'s entry.json once the service has saved it again: only its
  /// time is looked at until then (Windows: a read while the service
  /// renames over the file makes the rename fail).
  Future<Map<String, dynamic>> savedAgain(String entry, DateTime before) async {
    final file = File(path.join(h.root.path, entry, 'entry.json'));
    await until(
      () =>
          file.lastModifiedSync().isAfter(before) &&
          !File('${file.path}.tmp').existsSync(),
      reason: 'entry.json saved',
    );
    await settle();
    return readEntryJson(h.root.path, entry);
  }

  DateTime modified(String entry) =>
      File(path.join(h.root.path, entry, 'entry.json')).lastModifiedSync();

  test('the width and height of the stream picked are saved', () async {
    await start();
    h.plan = (_) => dashPlan(width: 1280, height: 720);
    expect(p1.pageData!.width, 1920);
    var before = modified(fixtureP1);
    h.service.startDownload(p1);
    await until(() => h.transports.isNotEmpty);
    expect((p1.pageData!.width, p1.pageData!.height), (1280, 720));
    final page = (await savedAgain(fixtureP1, before))['page_data'] as Map;
    expect((page['width'], page['height']), (1280, 720));

    // a bangumi episode keeps them in its ep
    h.plan = (_) => dashPlan(width: 720, height: 1280);
    before = modified(fixtureS);
    h.service.startDownload(s);
    await until(() => h.transportsOf(s).isNotEmpty);
    expect((s.ep!.width, s.ep!.height), (720, 1280));
    final ep = (await savedAgain(fixtureS, before))['ep'] as Map;
    expect((ep['width'], ep['height']), (720, 1280));
  });

  test('the stream index is written with the start', () async {
    await start();
    final plan = dashPlan(audio: true, size: 4096);
    h.plan = (_) => plan;
    h.service.startDownload(p1);
    await until(() => h.transports.length == 2);
    final index = File(path.join(streamDir(p1), 'index.json'));
    expect(index.existsSync(), isTrue);
    expect(jsonDecode(index.readAsStringSync()), plan.toJson());
    expect(File('${index.path}.tmp').existsSync(), isFalse);
  });

  test('durl segments: the next one once the one before is done', () async {
    await start();
    h.plan = (_) => durlPlan([1000, 2000]);
    h.service.startDownload(p1);
    await until(() => h.transports.length == 1);
    final first = h.transports.single;
    expect(first.path, path.join(streamDir(p1), '0.mp4'));
    expect(first.expectedTotal, 1000);

    first.complete(bytes: 1000);
    await until(() => h.transports.length == 2);
    final second = h.transports.last;
    expect(second.path, path.join(streamDir(p1), '1.mp4'));
    expect(second.expectedTotal, 2000);
    // and it is the running transfer: a pause stops it
    await h.service.cancelDownload(isDelete: false, downloadNext: false);
    expect(second.cancels, [false]);
  });

  test('durl segments: paused before the first is done, no next one '
      'follows', () async {
    await start();
    h.plan = (_) => durlPlan([1000, 2000]);
    h.service.startDownload(p1);
    await until(() => h.transports.length == 1);
    final first = h.transports.single;
    await h.service.cancelDownload(isDelete: false, downloadNext: false);
    expect(first.cancels, [false]);
    // the first one's success arriving after the pause
    first.onDone();
    await settle();
    expect(h.transports, hasLength(1));
  });
}
