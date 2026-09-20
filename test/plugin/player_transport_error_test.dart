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
}
