import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// The classification that decides whether a player error gets a retry and a
/// toast, or is swallowed into the log file. A phone that sat on "加载中..."
/// forever is what put these cases here.
void main() {
  group('transport failures are retried', () {
    const retryable = [
      // the one that was missed: mpv's TLS module, seen on a stale network
      'tls: mbedtls_ssl_handshake returned -0x7280',
      'tls: mbedtls_ssl_handshake returned -0x4e',
      'Failed to open https://upos-sz-mirrorcos.bilivideo.com/x.m4s',
      'Can not open external file https://example.com/a.m4s',
      'tcp: ffurl_read returned 0xdfb9b0bb',
      'stream: error opening, path not found',
      'https: HTTP error 403 Forbidden',
    ];

    for (final event in retryable) {
      test(event, () {
        expect(PlPlayerController.debugIsTransportFailure(event), isTrue);
      });
    }
  });

  group('everything else is left alone', () {
    const notRetryable = [
      // a decoder problem fails again the same way; retrying is pointless
      'Could not open codec.',
      'Failed to open file /storage/emulated/0/x.mp4',
      'error running rendering filter',
      'Cannot open ao driver',
      '',
    ];

    for (final event in notRetryable) {
      test(event.isEmpty ? '(empty)' : event, () {
        expect(PlPlayerController.debugIsTransportFailure(event), isFalse);
      });
    }
  });

  group('what to do about a source that will not deliver', () {
    test('the first failure re-opens the same URL', () {
      expect(
        PlPlayerController.transportRecovery(0),
        TransportRecovery.retrySameUrl,
      );
    });

    test('a second failure on the same host moves to another CDN', () {
      expect(
        PlPlayerController.transportRecovery(1),
        TransportRecovery.switchCdn,
      );
      expect(
        PlPlayerController.transportRecovery(5),
        TransportRecovery.switchCdn,
      );
    });

    test('quality is never the first answer to a stall', () {
      // the enum has no "drop quality" case on purpose: automatic quality
      // switching belongs after the CDNs run out, and a dead host must not
      // cost the user their resolution
      expect(TransportRecovery.values, hasLength(2));
    });
  });

  group('where a stream ended early', () {
    test("read from mpv's line, reconnect or not", () {
      expect(
        PlPlayerController.prematureEndAt(
          'https: Stream ends prematurely at 1060331, should be 101224217',
        ),
        '1060331',
      );
      // after mpv's own reconnect got an empty reply at the same byte
      expect(
        PlPlayerController.prematureEndAt(
          'https: Stream ends prematurely at 1060331, '
          'should be 18446744073709551615',
        ),
        '1060331',
      );
    });

    test('other lines say nothing about it', () {
      expect(
        PlPlayerController.prematureEndAt(
          'https: Error reading HTTP response: End of file',
        ),
        isNull,
      );
    });
  });

  group('a track that ran dry while playback goes on', () {
    bool dry(double? position, double? cacheEnd, [double? duration = 600]) =>
        PlPlayerController.trackRanDry(
          position: position,
          cacheEnd: cacheEnd,
          duration: duration,
        );

    test('the playhead past the end of what arrived', () {
      // probed on a CDN whose copy of the video ended at 1 MB: the cache
      // stayed at 8.93 s while the audio carried the playhead on
      expect(dry(10.6, 8.93), isTrue);
      expect(dry(30.6, 8.93), isTrue);
    });

    test('normal playback has the cache ahead of the playhead', () {
      expect(dry(4.2, 8.9), isFalse);
      expect(dry(8.7, 8.93), isFalse);
      // within a second of it: the next packets may be a moment away
      expect(dry(9.5, 8.93), isFalse);
    });

    test('the end of the video is not a stream running dry', () {
      expect(dry(599, 596), isFalse);
    });

    test('an unknown cache or position is not a reason to act', () {
      expect(dry(null, 8.9), isFalse);
      expect(dry(10, null), isFalse);
      expect(dry(10.6, 8.93, null), isTrue);
    });
  });
}
