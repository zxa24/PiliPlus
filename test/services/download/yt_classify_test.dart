// LibrePili: how a YouTube download's failures are read (stage-2 plan
// §3.3 「失败的归类」 and §3.5, design §4.3's table), row by row: a
// resolve's verdict — the cause first, then the signal — and the
// transfer's own exception types.
import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/stream_relay.dart';
import 'package:PiliPlus/services/youtube/yt_source_store.dart';
import 'package:PiliPlus/services/youtube/yt_transfer_errors.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:flutter_test/flutter_test.dart';

import 'yt_download_test_support.dart';

class _NoHost extends Fake implements DownloadHost {}

void main() {
  final platform = YtDownloadPlatform(_NoHost());
  late FormatYtSource direct;
  late FormatYtSource invidious;

  setUp(() {
    final formats = [
      ytVideoFormat(137, bytes: 1000),
      ytAudioFormat(140, bytes: 100),
    ];
    direct = FormatYtSource('direct', formats);
    invidious = FormatYtSource('invidious', formats);
    YtDownloadPlatform.routerForTest =
        (mode, {required own, required health}) => YtSourceRouter(
          direct,
          fallback: invidious,
          mode: mode,
          health: health,
          sleep: (_) async {},
        );
    // the direct source alone: a refusal or a timeout does not move on
    YtSourceStore.debugMode = YtSourceMode.directOnly;
  });
  tearDown(() {
    YtDownloadPlatform.routerForTest = null;
    YtSourceStore.debugMode = YtSourceMode.auto;
    YtSourceRouter.sharedHealth.clear();
  });

  Future<DownloadResolveFailure> failure() async {
    try {
      await platform.resolve(ytEntry(Directory.systemTemp, maxHeight: 1080));
    } on DownloadResolveFailure catch (e) {
      return e;
    }
    fail('the resolve did not fail');
  }

  group('a resolve that fails (§3.3)', () {
    for (final (cause, signal, kind) in [
      (
        YtCause.contentUnavailable,
        'no-playable-pair',
        DownloadFailure.noFormat,
      ),
      (YtCause.clientBroken, 'no-playable-pair', DownloadFailure.other),
      (YtCause.transient, 'timeout', DownloadFailure.network),
      (YtCause.ipBlocked, 'playability:bot-check', DownloadFailure.network),
      (
        YtCause.contentUnavailable,
        'playability:private',
        DownloadFailure.other,
      ),
      (YtCause.clientBroken, 'needs-javascript', DownloadFailure.other),
      (
        YtCause.contentUnavailable,
        'invidious:no-playable-pair',
        DownloadFailure.other,
      ),
      (YtCause.contentUnavailable, 'invidious:live', DownloadFailure.noFormat),
    ]) {
      test('the streams: ${cause.name} <$signal> → ${kind.name}', () async {
        direct.streamFailures.addAll(List.filled(8, YtVerdict(cause, signal)));
        final e = await failure();
        expect(e.kind, kind);
        expect(e.message, '${cause.name}<$signal>');
      });
    }

    test('the detail: ${YtCause.transient.name} → network', () async {
      direct.detailFailures.addAll(
        List.filled(8, const YtVerdict(YtCause.transient, 'timeout')),
      );
      expect((await failure()).kind, DownloadFailure.network);
    });

    test('the real pick: only WebM on offer → noFormat', () async {
      direct.formats = [
        ytVideoFormat(248, codec: 'vp9'),
        {
          ...ytAudioFormat(251),
          'mimeType': 'audio/webm; codecs="opus"',
        },
      ];
      final e = await failure();
      expect(e.kind, DownloadFailure.noFormat);
      expect(e.message, 'contentUnavailable<no-playable-pair>');
    });
  });

  group("the transfer's failures (§4.3)", () {
    for (final (error, kind) in <(Object, DownloadFailure)>[
      (const SocketException('down'), DownloadFailure.network),
      (const TlsException('bad'), DownloadFailure.network),
      (TimeoutException('quiet'), DownloadFailure.network),
      (const HttpException('Connection closed'), DownloadFailure.network),
      (const YtShortBody(10, 20), DownloadFailure.network),
      (
        YtHopRefused(Uri.parse('https://x.example'), 'no address'),
        DownloadFailure.network,
      ),
      (
        YtHopRefused(Uri.parse('https://x.example'), 'not a public address'),
        DownloadFailure.other,
      ),
      (const YtHttpStatus(403), DownloadFailure.refused),
      (const YtHttpStatus(404), DownloadFailure.refused),
      (const YtHttpStatus(410), DownloadFailure.refused),
      (const YtHttpStatus(429), DownloadFailure.other),
      (const YtHttpStatus(503), DownloadFailure.other),
      (const YtHttpStatus(400), DownloadFailure.other),
      (const YtRangeError.total('7'), DownloadFailure.range),
      (const YtRangeError.overlap('at 1'), DownloadFailure.range),
      (const YtTooManyRedirects('x.example'), DownloadFailure.other),
      (const FileSystemException('full'), DownloadFailure.other),
      (StateError('odd'), DownloadFailure.other),
      (
        const DownloadResolveFailure(DownloadFailure.qualityUnavailable, 'q'),
        DownloadFailure.qualityUnavailable,
      ),
    ]) {
      test('$error → ${kind.name}', () {
        expect(platform.classify(YtTransferError('audio', error)), kind);
        // as the resolve throws them too, unwrapped
        expect(platform.classify(error), kind);
      });
    }
  });
}
