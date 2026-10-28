// LibrePili: what the download tests of the download-platforms baseline
// share (design feature-logs/download-platforms/design.md, AC1): the key an
// entry is known by, the fixture download folders, and the download service
// run on a temporary folder through its test hooks — no network, fake
// transfers, a fake merge.
//
// The tests are written so that the refactor after them (phase 1: a
// platform-neutral entry type, string keys) changes nothing under test/ but
// the body of [keyOf]: lambdas carry no parameter types, bilibili members
// are read only off the test's own BiliDownloadEntryInfo variables, keys are
// typed Object.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/bili_download_media_file_info.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/services/download/download_progress.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;

/// The key the download service knows [entry] by. The one function under
/// test/ that phase 1 changes (to `(entry as DownloadEntry).key`).
Object keyOf(Object entry) => (entry as BiliDownloadEntryInfo).cid;

/// [keyOf] for a parameter the service types (an `int` now): passes as
/// whatever that type is.
dynamic keyArg(Object entry) => keyOf(entry);

/// The entry of [list] whose key is [key].
BiliDownloadEntryInfo entryIn(Iterable<Object?> list, Object key) =>
    list.firstWhere((e) => keyOf(e!) == key) as BiliDownloadEntryInfo;

/// Whether one of [list] has [key].
bool hasKey(Iterable<Object?> list, Object key) =>
    list.any((e) => keyOf(e!) == key);

// ------------------------------------------------------------------ fixtures

/// The three `entry.json` of AC1 记录 (this app's ugc and pgc, the official
/// client's bangumi episode), in a download root's layout.
const recordFixtures = 'test/fixtures/download/input';
const recordExpected = 'test/fixtures/download/expected';

/// The download root of AC1 列表: [recordFixtures]' three plus the ugc
/// video's second part, each with `cover.jpg`; and a second episode of
/// [fixtureS]' season (`s_41001/733002`), so the self test's list shots
/// (`--download-list-shots`) have a bangumi group with its 番剧 badge.
const listFixtures = 'test/fixtures/download_list';

/// Entry folders of [listFixtures], relative to it.
const fixtureP1 = '170001/c_279001';
const fixtureP2 = '170001/c_279002';
const fixtureS = 's_41001/733001';
const fixtureOfficial = 's_42002/744002';

/// Entry folders of [recordFixtures].
const recordUgc = '170001/c_279001';
const recordPgc = 's_41001/733001';
const recordOfficial = 's_42002/744002';

Map<String, dynamic> readEntryJson(String root, String entry) =>
    jsonDecode(File(path.join(root, entry, 'entry.json')).readAsStringSync())
        as Map<String, dynamic>;

/// An entry read from a fixture folder, its paths there.
BiliDownloadEntryInfo fixtureEntry(String root, String entry) =>
    BiliDownloadEntryInfo.fromJson(readEntryJson(root, entry))
      ..entryDirPath = path.normalize(path.absolute(root, entry))
      ..pageDirPath = path.normalize(path.absolute(root, path.dirname(entry)));

void copyFolder(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync()) {
    final target = path.join(to.path, path.basename(e.path));
    if (e is Directory) {
      copyFolder(e, Directory(target));
    } else if (e is File) {
      e.copySync(target);
    }
  }
}

// ------------------------------------------------------------------ storage

/// Hive under a temporary folder with the boxes the downloads read
/// (settings, local watch progress), once per test file. Background
/// transcription off unless a test turns it on (design AC1: it would leave
/// a 30 s timer behind).
///
/// [inMemory] for a widget test that builds a network image: that image's
/// cache opens Hive storage of its own inside the test's fake clock, and
/// closing any box then waits on it for ever. The boxes are kept in memory
/// and not closed.
Future<Directory> initDownloadStorage({bool inMemory = false}) async {
  final dir = await Directory.systemTemp.createTemp('librepili-dl-test-');
  Hive.init(dir.path);
  final bytes = inMemory ? Uint8List(0) : null;
  _inMemory = inMemory;
  GStorage.setting = await Hive.openBox('setting', bytes: bytes);
  GStorage.localCache = await Hive.openBox('localCache', bytes: bytes);
  GStorage.watchProgress = await Hive.openBox<int>(
    'watchProgress',
    bytes: bytes,
  );
  await GStorage.setting.put(SettingBoxKey.dlTranscribe, false);
  return dir;
}

var _inMemory = false;

Future<void> closeDownloadStorage(Directory dir) async {
  if (!_inMemory) await Hive.close();
  try {
    await dir.delete(recursive: true);
  } catch (_) {}
}

// ---------------------------------------------------------------- transfers

/// A transfer the test drives: [complete], [fail], or left running.
class FakeTransport implements DownloadManager {
  FakeTransport({
    required this.url,
    this.backupUrls = const [],
    required this.path,
    required this.onReceiveProgress,
    required this.onDone,
    this.expectedTotal = 0,
  }) {
    task = _task.future;
    created?.call(this);
  }

  /// Told of every one made.
  static void Function(FakeTransport transport)? created;

  @override
  final String url;
  @override
  final List<String> backupUrls;
  @override
  final String path;
  @override
  final void Function(int, int)? onReceiveProgress;
  @override
  final void Function([Object? error]) onDone;
  @override
  final int expectedTotal;

  @override
  late Future<void> task;
  final _task = Completer<void>();

  DownloadStatus _status = DownloadStatus.downloading;
  @override
  DownloadStatus get status => _status;

  /// The `isDelete` of each [cancel].
  final cancels = <bool>[];

  bool get settled => _task.isCompleted;

  /// Received [bytes] of [bytes] (written to [path]), then done.
  void complete({int bytes = 1024}) {
    if (settled) return;
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List.filled(bytes, 1));
    onReceiveProgress?.call(bytes, bytes);
    _status = DownloadStatus.completed;
    _task.complete();
    onDone();
  }

  void receive(int received, int total) =>
      onReceiveProgress?.call(received, total);

  void fail([Object error = const HttpException('fake transfer failed')]) {
    if (settled) return;
    _status = DownloadStatus.failDownload;
    _task.complete();
    onDone(error);
  }

  /// As [DownloadManager.cancel]: a running transfer stops and reports
  /// the cancel through [onDone] before the returned future completes.
  @override
  Future<void> cancel({required bool isDelete}) async {
    cancels.add(isDelete);
    if (!isDelete && _status == DownloadStatus.downloading) {
      _status = DownloadStatus.pause;
    }
    if (settled) return task;
    await Future<void>.value();
    if (settled) return task;
    if (_status == DownloadStatus.downloading) {
      _status = DownloadStatus.failDownload;
    }
    _task.complete();
    onDone('cancelled');
    return task;
  }
}

typedef MergeResult = ({
  String? output,
  List<String> inputs,
  bool damaged,
  bool corrupt,
});

/// A dash play URL with one video stream (and an audio one when [audio]).
Type2 dashPlan({
  int id = 80,
  int width = 1280,
  int height = 720,
  bool audio = false,
  int size = 0,
}) => Type2(
  duration: 100,
  video: [
    Type2File(
      id: id,
      baseUrl: 'https://upos.example/video-$id.m4s',
      backupUrl: const ['https://upos-backup.example/video.m4s'],
      bandwidth: 800000,
      codecid: 7,
      size: size,
      md5: '',
      noRexcode: false,
      width: width,
      height: height,
    ),
  ],
  audio: audio
      ? [
          Type2File(
            id: 30280,
            baseUrl: 'https://upos.example/audio.m4s',
            bandwidth: 128000,
            codecid: 0,
            size: 0,
            md5: '',
            noRexcode: false,
          ),
        ]
      : null,
);

// ------------------------------------------------------------------ service

/// The download service on a temporary download root holding the
/// [listFixtures] entries asked for, with every hook set (design AC1
/// 「基线提交加的注入点」): play URLs from [plan], transfers [FakeTransport]
/// (completed a moment after they are made unless [onTransport] says
/// otherwise), merges [merge], extras [export], toasts in [toasts], retry
/// waits of 1 ms.
class DownloadHarness {
  late Directory dir;
  late Directory root;
  late DownloadService service;

  final transports = <FakeTransport>[];
  final toasts = <String>[];

  /// Entries merged, in order.
  final merged = <Object>[];

  /// Entries whose extras were exported, in order.
  final exported = <Object>[];

  /// What a new transfer does; default: completes a moment later.
  void Function(FakeTransport transport) onTransport = _completeSoon;
  static void _completeSoon(FakeTransport t) => scheduleMicrotask(t.complete);

  /// The play URL of each start; default [dashPlan].
  BiliDownloadMediaInfo Function(BiliDownloadEntryInfo entry) plan = _dash;
  static BiliDownloadMediaInfo _dash(BiliDownloadEntryInfo entry) => dashPlan();

  /// What the fake merge returns for an entry; null: a merge that works.
  MergeResult? Function(BiliDownloadEntryInfo entry)? mergeAnswer;

  /// Waited for before the fake merge returns (holds an entry "merging").
  Future<void>? Function(BiliDownloadEntryInfo entry)? mergeGate;

  /// Waited for inside the fake extras export.
  Future<void>? Function(BiliDownloadEntryInfo entry)? exportGate;

  /// Event log lines added since [start].
  List<String> get log => EventLog.recent.sublist(_logFrom);
  var _logFrom = 0;

  /// [entries] (folders of [fixtures]) copied in, each `entry.json`
  /// changed by [patch] first (e.g. `is_completed: false` to queue it).
  Future<void> start({
    String fixtures = listFixtures,
    List<String> entries = const [fixtureP1, fixtureP2, fixtureS],
    Map<String, Object?> Function(String entry, Map<String, dynamic> json)?
    patch,
  }) async {
    _fixtures = fixtures;
    dir = await Directory.systemTemp.createTemp('librepili-dl-');
    root = Directory(path.join(dir.path, 'download'))..createSync();
    for (final entry in entries) {
      final to = Directory(path.join(root.path, entry));
      copyFolder(Directory(path.join(fixtures, entry)), to);
      // the danmaku is there: the start does not fetch it
      File(path.join(to.path, PathUtils.danmakuName)).writeAsBytesSync([]);
      if (patch != null) {
        final file = File(path.join(to.path, 'entry.json'));
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        file.writeAsStringSync(jsonEncode(patch(entry, json)));
      }
    }
    downloadPath = root.path;
    SubtitleCache.debugInstance = SubtitleCache(
      Directory(path.join(dir.path, 'subtitle_cache')),
      limitBytes: () => 1 << 29,
    );
    FakeTransport.created = (t) {
      transports.add(t);
      onTransport(t);
    };
    DownloadService.getVideoUrlForTest = ({
      required entry,
      source,
      pageData,
      ep,
    }) async => plan(entry);
    DownloadService.newManagerForTest = FakeTransport.new;
    DownloadService.mergeForTest = _merge;
    DownloadService.exportExtrasForTest = _export;
    DownloadService.toastForTest = toasts.add;
    DownloadService.retryWaitsForTest = const [
      Duration(milliseconds: 1),
      Duration(milliseconds: 1),
      Duration(milliseconds: 1),
    ];
    _logFrom = EventLog.recent.length;
    service = Get.put(DownloadService());
    await service.waitForInitialization;
  }

  Future<void> stop() async {
    // a retry timer or a queued start of this run must find nothing to do
    // once the hooks are gone (it would reach the network)
    await service.cancelDownload(isDelete: true, downloadNext: false);
    // and no save of an entry.json still writing into the folder
    for (final Object entry in [
      ...service.waitDownloadQueue,
      ...service.downloadList,
    ]) {
      try {
        await service.saveEntryForTest(entry as BiliDownloadEntryInfo);
      } catch (_) {}
    }
    service.waitDownloadQueue.clear();
    await settle();
    Get.delete<DownloadService>(force: true);
    DownloadService.getVideoUrlForTest = null;
    DownloadService.newManagerForTest = null;
    DownloadService.mergeForTest = null;
    DownloadService.exportExtrasForTest = null;
    DownloadService.toastForTest = null;
    DownloadService.retryWaitsForTest = null;
    DownloadService.selfTestBeforeMerge = null;
    FakeTransport.created = null;
    SubtitleCache.debugInstance = null;
    SubtitleCache.onSaved = null;
    transports.clear();
    toasts.clear();
    merged.clear();
    exported.clear();
    onTransport = _completeSoon;
    plan = _dash;
    mergeAnswer = null;
    mergeGate = null;
    exportGate = null;
    // what is still running (a retry, an extras job) is let go of first
    await Future<void>.delayed(const Duration(milliseconds: 20));
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  var _fixtures = listFixtures;

  /// The service's own object for the fixture [entry].
  BiliDownloadEntryInfo entry(String entry) {
    final key = keyOf(fixtureEntry(_fixtures, entry));
    return entryIn(
      [...service.waitDownloadQueue, ...service.downloadList],
      key,
    );
  }

  /// Transfers made for [entry] so far (by the folder they write into).
  List<FakeTransport> transportsOf(BiliDownloadEntryInfo entry) => [
    for (final t in transports)
      if (path.isWithin(entry.entryDirPath, t.path)) t,
  ];

  Future<MergeResult> _merge(BiliDownloadEntryInfo entry) async {
    merged.add(entry);
    await mergeGate?.call(entry);
    final inputs = [
      path.join(entry.entryDirPath, entry.streamTypeTag, 'video.m4s'),
    ];
    if (mergeAnswer?.call(entry) case final answer?) return answer;
    final name = 'export ${merged.length}';
    final output = path.join(root.path, name, '$name.mp4');
    File(output)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('merged');
    // as _mergeDownload does (design AC1, mergeForTest)
    entry.mergedPath = output;
    return (output: output, inputs: inputs, damaged: false, corrupt: false);
  }

  Future<Map<String, Object?>> _export({
    required BiliDownloadEntryInfo entry,
    required String folder,
    required String base,
    bool Function()? cancelled,
    DownloadProgress? progress,
  }) async {
    exported.add(entry);
    await exportGate?.call(entry);
    return {};
  }
}

/// Waits (really: files, timers) until [done], at most [timeout]. [done]
/// looks at the service and the fakes, not at entry.json: on Windows a read
/// of it while a save renames entry.json.tmp over it can make that rename
/// fail, and the save is lost. A save is seen landing through an
/// IOOverrides that wraps the rename (`_SaveWatch` in start_args_test.dart).
/// [quiet]: no error at the end of the wait, the assertions after it say
/// what went wrong (a queue that stalled).
Future<void> until(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
  bool quiet = false,
}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) {
      if (quiet) return;
      throw TimeoutException('waited for ${reason ?? 'a condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

/// A moment for what is under way to settle (microtasks, short timers).
Future<void> settle([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));
