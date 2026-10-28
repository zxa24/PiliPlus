// LibrePili: a download that finishes shows the transcript the cache
// already has of its part from the start (design feature-logs/
// download-platforms/design.md, §3.2 完成时的起始进度, AC1 1b): what was
// transcribed while it was watched counts, so the list says so at once
// instead of 0 %. The self tests run on an empty cache and cannot see it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';

/// [seconds] of media transcribed, as the subtitle cache keeps it.
TranscriptStore transcribed(double seconds) {
  final store = TranscriptStore();
  final run = store.startRun(0);
  store.advance(run, seconds);
  run.finish();
  return store;
}

/// The subtitle cache, its opens held once [hold] is called until
/// [release]; [opening] completes when the first held one starts.
class _HeldCache extends SubtitleCache {
  _HeldCache(super.dir) : super(limitBytes: () => 1 << 29);

  Completer<void>? _gate;
  final opening = Completer<void>();

  void hold() => _gate = Completer<void>();
  void release() => _gate?.complete();

  @override
  Future<SubtitleCacheEntry> open(
    SubtitleCacheKey key,
    String recogniser,
  ) async {
    if (_gate case final gate?) {
      if (!opening.isCompleted) opening.complete();
      await gate.future;
    }
    return super.open(key, recogniser);
  }
}

/// Saves of entry.json seen landing, by folder: the rename of
/// `entry.json.tmp` is wrapped (as `_SaveWatch` in start_args_test.dart),
/// the file is never looked at while a save may be running.
final class _SaveWatch extends IOOverrides {
  final saved = <String>[];

  @override
  File createFile(String file) {
    final made = super.createFile(file);
    return file.endsWith('entry.json.tmp') ? _WatchedTmp(made, saved) : made;
  }
}

String _folderOf(String file) => path.dirname(file);

/// An `entry.json.tmp` that tells [saved] once it is renamed into place.
/// Only what the service's save does with it is passed on.
class _WatchedTmp implements File {
  _WatchedTmp(this._file, this._saved);

  final File _file;
  final List<String> _saved;

  @override
  String get path => _file.path;

  @override
  bool existsSync() => _file.existsSync();

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => _file.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );

  @override
  Future<File> rename(String newPath) async {
    final renamed = await _file.rename(newPath);
    _saved.add(_folderOf(newPath));
    return renamed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not passed on: ${invocation.memberName}');
}

void main() {
  late Directory storage;
  final h = DownloadHarness();

  setUpAll(() async => storage = await initDownloadStorage());
  tearDownAll(() => closeDownloadStorage(storage));
  setUp(() => GStorage.setting.put(SettingBoxKey.dlTranscribe, true));
  tearDown(() async {
    h.service.transcripts.dispose();
    await h.stop();
    await GStorage.setting.put(SettingBoxKey.dlTranscribe, false);
  });

  late BiliDownloadEntryInfo p1;

  /// P1 in the list, two minutes long.
  Future<void> start() async {
    await h.start(entries: const [fixtureP1]);
    p1 = h.entry(fixtureP1)..totalTimeMilli = 120000;
  }

  test('the starting progress is the coverage the cache already has', () async {
    await start();
    // 30 s of its 120 transcribed while it was watched
    final cache = SubtitleCache.instance;
    final kept = await cache.open(
      SubtitleCacheKey.bilibili(p1.cid),
      AsrService.recogniserId,
    );
    kept.captureTranscript(transcribed(30));
    await cache.save(kept);
    final transcripts = h.service.transcripts;
    expect(transcripts.progress[keyOf(p1)], isNull);

    await transcripts.finished(p1);
    expect(transcripts.progress[keyOf(p1)], closeTo(0.25, 1e-9));
    expect(transcripts.stateOf(keyArg(p1))?.fraction, closeTo(0.25, 1e-9));
    expect(p1.transcriptPending, isTrue);
    expect(
      readEntryJson(h.root.path, fixtureP1)['transcript_pending'],
      isTrue,
    );
  });

  test('none in the cache: from 0', () async {
    await start();
    final transcripts = h.service.transcripts;
    await transcripts.finished(p1);
    expect(transcripts.progress[keyOf(p1)], 0);
    expect(p1.transcriptPending, isTrue);
  });

  test('deleted while the cache is read: forgotten, not saved again', () async {
    await start();
    final cache = _HeldCache(
      Directory(path.join(h.dir.path, 'subtitle_cache')),
    );
    SubtitleCache.debugInstance = cache;
    final kept = await cache.open(
      SubtitleCacheKey.bilibili(p1.cid),
      AsrService.recogniserId,
    );
    kept.captureTranscript(transcribed(30));
    await cache.save(kept);
    cache.hold();
    final watch = _SaveWatch();
    final transcripts = h.service.transcripts;
    final done = IOOverrides.runWithIOOverrides(
      () => transcripts.finished(p1),
      watch,
    );

    await cache.opening.future;
    final saves = watch.saved.length;
    await h.service.deleteDownload(entry: p1, removeList: true);
    expect(transcripts.progress[keyOf(p1)], isNull);
    cache.release();
    await done;
    expect(transcripts.progress.containsKey(keyOf(p1)), isFalse);
    expect(watch.saved.length, saves, reason: 'saved after the delete');
  });
}
