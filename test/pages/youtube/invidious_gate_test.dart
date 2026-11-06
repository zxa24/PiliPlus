import 'package:PiliPlus/pages/youtube/invidious_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the in-app browser's pass is made of: when its cookies end, and the
/// headers its page requests carry.
void main() {
  group('a cookie’s end', () {
    test('seconds, as WebView2 gives them (Gandalf’s token, 2026-11-06)', () {
      expect(
        InvidiousGate.expiry(1793950725),
        DateTime.fromMillisecondsSinceEpoch(1793950725000),
      );
    });

    test('milliseconds, as documented', () {
      expect(
        InvidiousGate.expiry(1793950725123),
        DateTime.fromMillisecondsSinceEpoch(1793950725123),
      );
    });

    test('none: with the session', () {
      expect(InvidiousGate.expiry(null), isNull);
      expect(InvidiousGate.expiry(0), isNull);
      expect(InvidiousGate.expiry(-1), isNull);
    });
  });

  group('the headers of a page request', () {
    test('the brands as the web view states them', () {
      final h = InvidiousGate.pageHeaders({
        'b': [
          {'brand': 'Chromium', 'version': '156'},
          {'brand': 'Microsoft Edge WebView2', 'version': '156'},
        ],
        'm': false,
        'p': 'Windows',
      });
      expect(
        h['sec-ch-ua'],
        '"Chromium";v="156", "Microsoft Edge WebView2";v="156"',
      );
      expect(h['sec-ch-ua-mobile'], '?0');
      expect(h['sec-ch-ua-platform'], '"Windows"');
      expect(h['Sec-Fetch-Mode'], 'navigate');
      expect(h['Upgrade-Insecure-Requests'], '1');
    });

    test('a web view without userAgentData: no client hints', () {
      final h = InvidiousGate.pageHeaders(null);
      expect(h.containsKey('sec-ch-ua'), isFalse);
      expect(h['Sec-Fetch-Dest'], 'document');
    });
  });
}
