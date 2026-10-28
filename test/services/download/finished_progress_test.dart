// LibrePili: a download that finishes shows the transcript the cache
// already has of its part from the start (design feature-logs/
// download-platforms/design.md, §3.2 完成时的起始进度, AC1 1b): what was
// transcribed while it was watched counts, so the list says so at once
// instead of 0 %. The self tests run on an empty cache and cannot see it.
import 'dart:io';

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_test_support.dart';

/// [seconds] of media transcribed, as the subtitle cache keeps it.
TranscriptStore transcribed(double seconds) {
  final store = TranscriptStore();
  final run = store.startRun(0);
  store.advance(run, seconds);
  run.finish();
  return store;
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
}
