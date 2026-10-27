// LibrePili: what the play URL's resolve writes into an entry (design
// feature-logs/download-platforms/design.md, AC1, `resolve` 写进条目的值):
// `media_type`, `type_tag`, `video_quality`, `quality_pithy_description`,
// `has_dash_audio`, and the requested quality left as it was.
//
// The self test `--download` sees these only where they differ from what
// the entry was created with: it asks for 1080P and gets 1080P, and a new
// entry is created with `media_type` 2 and the requested quality's name, so
// a resolve that no longer wrote them would not show there (AC1 变异检查:
// M16, M18). Here the entry starts with other values — a quality asked for
// above what the video has, a stream type of an earlier start — and the
// real resolve runs against a canned play URL answer: the HTTP client
// answers every request itself, nothing leaves the process.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_test_support.dart';

/// The play URL request answered with [answer]; anything else refused.
class _PlayUrl implements HttpClientAdapter {
  Map<String, Object?> answer = const {};
  final asked = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    asked.add(options.uri.path);
    final playUrl = options.uri.path.endsWith('/x/player/wbi/playurl');
    return ResponseBody.fromString(
      jsonEncode(
        playUrl
            ? {'code': 0, 'data': answer}
            : {'code': -1, 'message': 'offline test'},
      ),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The formats a video of 1080P at most offers.
const _formats = [
  {
    'quality': 80,
    'format': 'flv',
    'new_description': '1080P 高清',
    'display_desc': '1080P',
    'codecs': ['avc1.640032'],
  },
  {
    'quality': 64,
    'format': 'flv720',
    'new_description': '720P 准高清',
    'display_desc': '720P',
    'codecs': ['avc1.640028'],
  },
];

/// A dash answer: 1080P at most, with an audio stream.
const _dash = {
  'quality': 80,
  'format': 'flv',
  'timelength': 125000,
  'accept_quality': [80, 64],
  'video_codecid': 7,
  'support_formats': _formats,
  'dash': {
    'duration': 125,
    'video': [
      {
        'id': 80,
        'baseUrl': 'https://upos.example/video-80.m4s',
        'backupUrl': <String>[],
        'bandwidth': 2000000,
        'codecs': 'avc1.640032',
        'width': 1920,
        'height': 1080,
        'frameRate': '30',
        'codecid': 7,
      },
      {
        'id': 64,
        'baseUrl': 'https://upos.example/video-64.m4s',
        'backupUrl': <String>[],
        'bandwidth': 1000000,
        'codecs': 'avc1.640028',
        'width': 1280,
        'height': 720,
        'frameRate': '30',
        'codecid': 7,
      },
    ],
    'audio': [
      {
        'id': 30280,
        'baseUrl': 'https://upos.example/audio.m4s',
        'backupUrl': <String>[],
        'bandwidth': 128000,
        'codecs': 'mp4a.40.2',
        'width': 0,
        'height': 0,
        'frameRate': '',
        'codecid': 0,
      },
    ],
  },
};

/// A durl (segments) answer at 720P.
const _durl = {
  'quality': 64,
  'format': 'mp4720',
  'timelength': 125000,
  'accept_quality': [80, 64],
  'video_codecid': 7,
  'support_formats': _formats,
  'durl': [
    {
      'order': 1,
      'length': 125000,
      'size': 4096,
      'url': 'https://upos.example/segment-1.mp4',
      'backup_url': <String>[],
    },
  ],
};

void main() {
  late Directory storage;
  final h = DownloadHarness();
  final http = _PlayUrl();

  setUpAll(() async {
    storage = await initDownloadStorage();
    // the signing key of today: the play URL request does not fetch one
    await GStorage.localCache.put(LocalCacheKey.mixinKey, 'librepilitestkey');
    await GStorage.localCache.put(
      LocalCacheKey.timeStamp,
      DateTime.now().millisecondsSinceEpoch,
    );
    // built as the app builds it, then answering on its own
    Request();
    Request.dio.httpClientAdapter = http;
  });
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  /// P1 in the queue, nothing downloaded, its record changed by [record];
  /// the real resolve (the service's play URL hook left unset), the
  /// transfers left running.
  Future<BiliDownloadEntryInfo> start(
    Map<String, Object?> Function(Map<String, dynamic> json) record,
  ) async {
    h.onTransport = (_) {};
    await h.start(
      entries: const [fixtureP1],
      patch: (entry, json) => record({
        ...json,
        'is_completed': false,
        'downloaded_bytes': 0,
      }),
    );
    DownloadService.getVideoUrlForTest = null;
    return h.entry(fixtureP1);
  }

  /// The record as saved once the start's resolve has run.
  Future<Map<String, dynamic>> savedAfterStart(
    BiliDownloadEntryInfo p1,
    int transfers,
  ) async {
    h.service.startDownload(p1);
    await until(
      () => h.transports.length == transfers,
      reason: '$transfers transfer(s) started',
    );
    await h.service.saveEntryForTest(p1);
    return readEntryJson(h.root.path, fixtureP1);
  }

  test('dash: the quality got, its name, the stream type and the audio '
      'flag are written; the quality asked for stays', () async {
    http.answer = _dash;
    final p1 = await start(
      (json) => {
        ...json,
        // asked for above what the video has, by an earlier durl start
        'prefered_video_quality': 116,
        'type_tag': '116',
        'quality_pithy_description': '1080P 60帧',
        'media_type': 1,
        'has_dash_audio': false,
      }..remove('video_quality'),
    );
    final saved = await savedAfterStart(p1, 2);
    expect(
      http.asked.where((p) => p.endsWith('/x/player/wbi/playurl')),
      hasLength(1),
    );
    expect(
      {
        for (final key in const [
          'media_type',
          'type_tag',
          'video_quality',
          'quality_pithy_description',
          'has_dash_audio',
          'prefered_video_quality',
        ])
          key: saved[key],
      },
      {
        'media_type': 2,
        'type_tag': '80',
        'video_quality': 80,
        'quality_pithy_description': '1080P 高清',
        'has_dash_audio': true,
        'prefered_video_quality': 116,
      },
    );
  });

  test('durl: the quality got, its name and the stream type are written; '
      'the audio flag is left as it was', () async {
    http.answer = _durl;
    final p1 = await start(
      (json) => {
        ...json,
        'prefered_video_quality': 80,
        'type_tag': '80',
        'video_quality': 80,
        'quality_pithy_description': '1080P 高清',
        'media_type': 2,
        'has_dash_audio': true,
      },
    );
    final saved = await savedAfterStart(p1, 1);
    expect(
      {
        for (final key in const [
          'media_type',
          'type_tag',
          'video_quality',
          'quality_pithy_description',
          'has_dash_audio',
          'prefered_video_quality',
        ])
          key: saved[key],
      },
      {
        'media_type': 1,
        'type_tag': '64',
        'video_quality': 64,
        'quality_pithy_description': '720P 准高清',
        'has_dash_audio': true,
        'prefered_video_quality': 80,
      },
    );
  });
}
