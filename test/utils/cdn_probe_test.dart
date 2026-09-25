import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/cdn_probe.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_test/flutter_test.dart';

/// The numbers are BV18yt46NEC5's, measured on a network routed abroad:
/// Akamai 1.41 MB/s, cosov 0.22 MB/s, the 1080P AVC stream 3.8 Mbps.
void main() {
  const akamai = 'upos-hz-mirrorakam.akamaized.net';
  const cosov = 'upos-sz-mirrorcosov.bilivideo.com';

  group('which host to play from', () {
    test('the fastest', () {
      expect(
        CdnProbe.pick({cosov: 221e3, akamai: 1413e3}),
        akamai,
      );
    });

    test('the current one while it is nearly as fast', () {
      expect(
        CdnProbe.pick({akamai: 1413e3, cosov: 1200e3}, current: cosov),
        cosov,
      );
      expect(
        CdnProbe.pick({akamai: 1413e3, cosov: 900e3}, current: cosov),
        akamai,
      );
    });

    test('never one that did not deliver', () {
      expect(CdnProbe.pick({akamai: null, cosov: 221e3}), cosov);
      expect(CdnProbe.pick({akamai: null, cosov: null}), isNull);
      expect(CdnProbe.pick({}), isNull);
    });
  });

  group('whether a host keeps up with the stream', () {
    test('with a margin', () {
      expect(CdnProbe.keepsUp(1413e3, 3800000), isTrue);
      // 1.8 Mbps for a 3.8 Mbps stream: the switch that made it worse
      expect(CdnProbe.keepsUp(221e3, 3800000), isFalse);
      // exactly the bitrate leaves nothing for a dropped connection
      expect(CdnProbe.keepsUp(475e3, 3800000), isFalse);
    });

    test('an unknown bitrate asks only that it delivers', () {
      expect(CdnProbe.keepsUp(1, null), isTrue);
      expect(CdnProbe.keepsUp(null, null), isFalse);
    });
  });

  group('how big the buffer is made', () {
    const mib = 1048576.0;

    test('16 s of a 3.8 Mbps stream, not a fixed 4 MiB', () {
      expect(
        Pref.sizeBuffer(
          setBytes: 4 * mib,
          seconds: 16,
          bitsPerSecond: 3800000,
          mobile: false,
        ),
        closeTo(3800000 / 8 * 16 * 1.25, 1),
      );
    });

    test('the setting when it is already enough', () {
      expect(
        Pref.sizeBuffer(
          setBytes: 4 * mib,
          seconds: 16,
          bitsPerSecond: 885330,
          mobile: false,
        ),
        4 * mib,
      );
    });

    test('no more than the cap, unless the setting asks for more', () {
      // 4K at 40 Mbps would want 100 MB
      expect(
        Pref.sizeBuffer(
          setBytes: 4 * mib,
          seconds: 16,
          bitsPerSecond: 40000000,
          mobile: true,
        ),
        32 * mib,
      );
      expect(
        Pref.sizeBuffer(
          setBytes: 100 * mib,
          seconds: 16,
          bitsPerSecond: 40000000,
          mobile: true,
        ),
        100 * mib,
      );
    });
  });

  group('how much the buffer can hold', () {
    test('the bytes fill before the seconds at a high bitrate', () {
      // 4 MiB at 3.8 Mbps: about 8.8 s, not the 16 s asked for
      expect(
        PlPlayerController.bufferTarget(
          seconds: 16,
          bytes: 4 * 1048576,
          bitsPerSecond: 3800000,
        ),
        closeTo(8.83, 0.01),
      );
    });

    test('the seconds at a low one, or with no bitrate known', () {
      expect(
        PlPlayerController.bufferTarget(
          seconds: 16,
          bytes: 4 * 1048576,
          bitsPerSecond: 885330,
        ),
        16,
      );
      expect(
        PlPlayerController.bufferTarget(
          seconds: 16,
          bytes: 4 * 1048576,
          bitsPerSecond: null,
        ),
        16,
      );
    });
  });
}
