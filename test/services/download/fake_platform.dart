// LibrePili: a platform of the tests' own, registered on the download
// service (`addPlatformForTest`), to drive the service's steps and its
// handle (`DownloadHost`, stage-2 plan §2.2) with no real platform: its
// start resolves to one stream folder, its transport attaches a transfer
// the test holds and reports through, its merge writes a file into the
// export the service gives it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_progress.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:flutter/widgets.dart' show SizedBox;
import 'package:material_ui/material_ui.dart' show ColorScheme, Widget;
import 'package:path/path.dart' as path;

/// An entry of [FakePlatform], in `<root>/fake_<id>/main`.
class FakeEntry extends DownloadEntry {
  FakeEntry(this.id);

  final String id;

  @override
  DownloadKey get key => 'fake:$id';
  @override
  String get platform => FakePlatform.platformId;
  @override
  String get logLabel => 'fake:$id';
  @override
  String get groupId => 'fake_$id';
  @override
  String get groupTitle => 'fake $id';
  @override
  int get sortKey => 0;
  @override
  String get title => 'fake $id';
  @override
  String get showTitle => title;
  @override
  String get cover => '';
  @override
  String? get ownerName => null;
  @override
  int get totalTimeMilli => 60000;
  @override
  String? get qualityLabel => null;
  @override
  int get timeUpdateStamp => 0;
  @override
  String get streamTypeTag => FakePlatform.streamTag;

  @override
  int totalBytes = 0;
  @override
  int downloadedBytes = 0;
  @override
  bool isCompleted = false;
  @override
  String? mergedPath;
  @override
  List<String>? mergedParts;
  @override
  bool extrasPending = false;
  @override
  bool transcriptPending = false;
}

/// [id]'s entry in [root], its folders made, waiting in [service]'s queue.
FakeEntry queueFakeEntry(DownloadService service, String root, String id) {
  final page = Directory(path.join(root, 'fake_$id'));
  final dir = Directory(path.join(page.path, 'main'))
    ..createSync(recursive: true);
  final entry = FakeEntry(id)
    ..pageDirPath = page.path
    ..entryDirPath = dir.path
    ..status = DownloadStatus.wait;
  service.waitDownloadQueue.add(entry);
  return entry;
}

/// A transfer the test drives through its report ([FakePlatform.reports]).
class FakeTransfer implements DownloadTransfer {
  @override
  DownloadStatus status = DownloadStatus.downloading;

  final _task = Completer<void>();
  @override
  Future<void> get task => _task.future;

  /// The `isDelete` of each [cancel].
  final cancels = <bool>[];

  @override
  Future<void> cancel({required bool isDelete}) {
    cancels.add(isDelete);
    if (!isDelete && status == DownloadStatus.downloading) {
      status = DownloadStatus.pause;
    }
    if (!_task.isCompleted) _task.complete();
    return task;
  }
}

class _FakePlan implements DownloadPlan {
  @override
  String get streamTag => FakePlatform.streamTag;
  @override
  int? get mediaGuess => null;
  @override
  bool get expectAudio => true;
}

class FakePlatform implements DownloadPlatform {
  FakePlatform(this.host);

  static const platformId = 'fake';
  static const streamTag = 'tag';

  final DownloadHost host;

  /// [extrasEnabled].
  bool extrasOn = true;

  /// Waited for inside [resolve] / [save].
  Future<void>? Function()? resolveGate;
  Future<void>? Function()? saveGate;

  var resolves = 0;
  var saves = 0;
  var extrasCalls = 0;

  /// [DownloadEntry.extrasPending] of each record saved.
  final savedExtrasPending = <bool>[];

  /// The generation each transport was given, the transfers it attached
  /// and the service's report of each.
  final gens = <int>[];
  final transfers = <FakeTransfer>[];
  final reports = <DownloadTransferReport>[];

  @override
  String get id => platformId;
  @override
  String get recordFile => 'fake.json';

  @override
  DownloadEntry parse(Map<String, dynamic> json) => throw UnimplementedError();

  /// Counted before the write: a save into a folder that is gone throws
  /// (the service logs it), it does not make the folder again.
  @override
  Future<void> save(DownloadEntry entry) async {
    saves++;
    await saveGate?.call();
    savedExtrasPending.add(entry.extrasPending);
    await File(path.join(entry.entryDirPath, recordFile)).writeAsString(
      jsonEncode({'key': entry.key, 'extras_pending': entry.extrasPending}),
    );
  }

  @override
  Future<void> prepare(DownloadEntry entry, DownloadReport report) async {}

  @override
  bool streamsComplete(DownloadEntry entry) => false;

  @override
  Future<DownloadPlan> resolve(DownloadEntry entry) async {
    resolves++;
    await resolveGate?.call();
    return _FakePlan();
  }

  @override
  String? streamKey(DownloadPlan plan) => null;
  @override
  Future<String?> readStreamKey(DownloadEntry entry) async => null;
  @override
  Future<void> writeStreamKey(DownloadEntry entry, DownloadPlan plan) async {}
  @override
  Future<bool> cover(DownloadEntry entry) async => true;

  @override
  Future<void> transport(
    DownloadEntry entry,
    DownloadPlan? plan,
    int gen,
  ) async {
    gens.add(gen);
    host.attach(gen, entry, (report) {
      reports.add(report);
      final transfer = FakeTransfer();
      transfers.add(transfer);
      return transfer;
    });
  }

  @override
  bool get playUrlFailuresAreNetwork => false;
  @override
  bool get extrasEnabled => extrasOn;
  @override
  void beforeRetry(DownloadEntry entry, DownloadFailure? kind) {}

  @override
  ({(int, int) video, (int, int)? audio, int? mediaGuess, bool? expectAudio})
  initialBytes(DownloadEntry entry) => (
    video: (0, 0),
    audio: (0, 0),
    mediaGuess: null,
    expectAudio: null,
  );

  @override
  ({String name, String suffix}) exportName(DownloadEntry entry) =>
      (name: entry.title, suffix: '');

  @override
  Future<DownloadMergeResult> merge(
    DownloadEntry entry,
    DownloadExport export,
  ) async {
    final output = await export.claim();
    try {
      await File(output).writeAsString('merged');
      entry.mergedPath = output;
      return (
        output: output,
        inputs: <String>[],
        damaged: false,
        corrupt: false,
      );
    } finally {
      export.release(output);
    }
  }

  @override
  Future<Map<String, Object?>> extras({
    required DownloadEntry entry,
    required String folder,
    required String base,
    bool Function()? cancelled,
    DownloadProgress? progress,
  }) async {
    extrasCalls++;
    return {};
  }

  @override
  Map<String, int> extrasPlan() => {};
  @override
  SubtitleCacheKey transcriptKey(DownloadEntry entry) =>
      SubtitleCacheKey.youtube(entry.key);
  @override
  String transcriptSessionKey(DownloadEntry entry) => 'download:${entry.key}';
  @override
  DownloadFailure classify(Object error) => error is SocketException
      ? DownloadFailure.network
      : DownloadFailure.other;
  @override
  int? groupBadge(DownloadEntry entry) => null;
  @override
  ({DownloadTitleLine first, List<DownloadTitleLine> more}) titleLines(
    DownloadEntry entry,
    bool showTitle,
  ) => (first: (text: entry.title, maxLines: 2), more: const []);
  @override
  String? platformBadge(DownloadEntry entry) => null;
  @override
  DownloadFailureAction? failureAction(DownloadEntry entry) => null;
  @override
  bool? coverCacheWidth(DownloadEntry entry) => false;
  @override
  ({File? file, String? network}) localCover(DownloadEntry entry) =>
      (file: null, network: null);
  @override
  ({int positionMs, bool finished})? progressOf(DownloadEntry entry) => null;
  @override
  List<DownloadMenuItem> menu(DownloadEntry entry) => const [];
  @override
  List<DownloadMenuItem> groupMenu(List<DownloadEntry> entries) => const [];
  @override
  Widget actions(DownloadEntry entry, ColorScheme colorScheme) =>
      const SizedBox();
  @override
  Future<void> onDeleted(List<DownloadEntry> entries) async {}
  @override
  Future<void> openOffline(DownloadEntry entry) async {}
}
