import 'package:PiliPlus/services/youtube/invidious_instances.dart';
import 'package:flutter_test/flutter_test.dart';

/// Which public instances are tried for opening a video in the browser.
void main() {
  // the shape of api.invidious.io/instances.json (2026-10-03, trimmed)
  final list = [
    [
      'inv.nadeko.net',
      {
        'type': 'https',
        'uri': 'https://inv.nadeko.net',
        'monitor': {'down': false, 'uptime': 99.6},
      },
    ],
    [
      'gone.example',
      {
        'type': 'https',
        'uri': 'https://gone.example',
        'monitor': {'down': true},
      },
    ],
    [
      'x.onion',
      {'type': 'onion', 'uri': 'http://x.onion', 'monitor': null},
    ],
    [
      'new.example',
      {'type': 'https', 'uri': 'https://new.example/', 'monitor': null},
    ],
    'not an entry',
  ];

  test('https instances not marked down, in the list order', () {
    expect(InvidiousInstances.candidates(list), [
      'https://inv.nadeko.net',
      'https://new.example',
    ]);
  });

  test('anything else is no instance', () {
    expect(InvidiousInstances.candidates({'a': 1}), isEmpty);
    expect(InvidiousInstances.candidates(null), isEmpty);
  });

  test('the watch page', () {
    expect(
      InvidiousInstances.watchUrl('https://inv.nadeko.net', 'dQw4w9WgXcQ'),
      'https://inv.nadeko.net/watch?v=dQw4w9WgXcQ',
    );
  });
}
