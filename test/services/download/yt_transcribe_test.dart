// LibrePili: a YouTube download's background transcript (stage-2 plan
// §3.5, §10-7 Q3 a; AC-T's unit part). A completion through the service
// marks it (`transcript_pending`) as bilibili's do; its keys are YouTube's:
// the cache's `yt:<id>` — so what was transcribed while it was watched
// online is where the list starts, not 0 % — and the session
// `download:yt:<id>`.
import 'dart:io';

import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_test_support.dart';
import 'yt_download_test_support.dart';

/// [seconds] of media transcribed, as the subtitle cache keeps it (as in
/// finished_progress_test.dart).
TranscriptStore transcribed(double seconds) {
  final store = TranscriptStore();
  final run = store.startRun(0);
  store.advance(run, seconds);
  run.finish();
  return store;
}

void main() {
  late Directory storage;
  final h = YtHarness();
  setUpAll(() async => storage = await initDownloadStorage());
  tearDownAll(() => closeDownloadStorage(storage));
  setUp(() => GStorage.setting.put(SettingBoxKey.dlTranscribe, true));
  tearDown(() async {
    h.service.transcripts.dispose();
    await h.stop();
    await GStorage.setting.put(SettingBoxKey.dlTranscribe, false);
  });

  test(
    'completed: marked, its start the coverage the cache has under yt:<id>',
    () async {
      await h.start(records: [(root) => ytEntry(root, maxHeight: 1080)]);
      final e = h.entry();
      // 53.25 s of its 213 transcribed while it was watched online
      final cache = SubtitleCache.instance;
      final kept = await cache.open(
        SubtitleCacheKey.youtube(ytId),
        AsrService.recogniserId,
      );
      kept.captureTranscript(transcribed(53.25));
      await cache.save(kept);
      await h.run(e);
      await until(
        () => (h.service.transcripts.progress[e.key] ?? 0) > 0,
        reason: 'the starting progress',
      );
      expect(h.service.transcripts.progress[e.key], closeTo(0.25, 1e-9));
      expect(e.transcriptPending, isTrue);
      expect((await h.record(e))['transcript_pending'], isTrue);
    },
  );

  test(
    'the keys: the cache\'s yt:<id>, the session download:yt:<id>',
    () async {
      await h.start(records: [ytEntry]);
      final e = h.entry();
      final platform = h.service.platformOf(e);
      expect(platform.transcriptKey(e), SubtitleCacheKey.youtube(ytId));
      expect(platform.transcriptSessionKey(e), 'download:yt:$ytId');
    },
  );
}
