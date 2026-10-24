// LibrePili: the transcript step of a download's extras (design
// feature-logs/download-platforms/design.md, AC1, p7#6): what the device
// transcribed of the part before it was downloaded — kept by the subtitle
// cache under `bili:<cid>` — is written beside the video as `.asr.srt`.
// The self tests run on an empty cache and cannot see it.
//
// The real export runs (the service's extras hook left unset), with every
// step it can skip switched off; the intro and the subtitle list still ask
// bilibili, so the HTTP client answers every request itself with a
// refusal, and nothing leaves the process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';

/// Every request refused (bilibili's `code` not 0), and counted.
class _Refusing implements HttpClientAdapter {
  final asked = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    asked.add(options.uri.toString());
    return ResponseBody.fromString(
      jsonEncode({'code': -1, 'message': 'offline test'}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory storage;
  final h = DownloadHarness();
  final offline = _Refusing();

  setUpAll(() async {
    storage = await initDownloadStorage();
    for (final key in [
      SettingBoxKey.dlSaveCover,
      SettingBoxKey.dlSaveDanmakuXml,
      SettingBoxKey.dlSaveDanmakuAss,
      SettingBoxKey.dlSaveComments,
    ]) {
      await GStorage.setting.put(key, false);
    }
    await GStorage.setting.put(SettingBoxKey.dlSaveSubtitle, true);
    // built as the app builds it, then answering on its own
    Request();
    Request.dio.httpClientAdapter = offline;
  });
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  late BiliDownloadEntryInfo p1;

  /// P1 in the queue, nothing downloaded.
  Future<void> start() async {
    await h.start(
      entries: const [fixtureP1],
      patch: (entry, json) => {
        ...json,
        'is_completed': false,
        'downloaded_bytes': 0,
      },
    );
    DownloadService.exportExtrasForTest = null;
    p1 = h.entry(fixtureP1);
  }

  /// 30 s of P1 transcribed before it was downloaded.
  Future<void> transcribedBefore() async {
    final cache = SubtitleCache.instance;
    final kept = await cache.open(
      SubtitleCacheKey.bilibili(p1.cid),
      AsrService.recogniserId,
    );
    final store = TranscriptStore();
    final run = store.startRun(0);
    store
      ..addSegment(
        run,
        1,
        2,
        const [
          AsrCue(from: 1, to: 3, content: '下载之前转写的一句'),
        ],
        language: 'zh',
        weight: 10,
      )
      ..advance(run, 30);
    run.finish();
    kept.captureTranscript(store);
    await cache.save(kept);
  }

  /// P1 downloaded and merged, its extras exported.
  Future<String> download() async {
    h.service.startDownload(p1);
    await until(() => h.merged.isNotEmpty);
    await until(
      () => p1.status == DownloadStatus.completed && !p1.extrasPending,
      timeout: const Duration(seconds: 20),
      reason: 'the extras',
    );
    return p1.mergedPath!;
  }

  String srtBeside(String video) => '${path.withoutExtension(video)}.asr.srt';

  test('a transcript the cache has of the part is written beside the '
      'video', () async {
    await start();
    await transcribedBefore();
    final video = await download();
    final srt = File(srtBeside(video));
    expect(srt.existsSync(), isTrue);
    expect(srt.readAsStringSync(), contains('下载之前转写的一句'));
    // what the export asked for was answered here
    expect(offline.asked, isNotEmpty);
  });

  test('none in the cache: no transcript file', () async {
    await start();
    final video = await download();
    expect(File(video).existsSync(), isTrue);
    expect(File(srtBeside(video)).existsSync(), isFalse);
  });
}
