import 'dart:convert';

import 'package:PiliPlus/services/youtube/yt_subscription_io.dart';
import 'package:flutter_test/flutter_test.dart';

const _a = 'UCsXVk37bltHxD1rDPwtNM8Q';
const _b = 'UC_x5XG1OV2P6uZZ5FSM9Ttw';

void main() {
  group('NewPipe / PipePipe JSON in', () {
    test('keeps YouTube rows, counts the rest', () {
      final file = parseYtSubscriptionFile(
        jsonEncode({
          'app_version': '0.27.6',
          'app_version_int': 1000,
          'subscriptions': [
            {
              'service_id': 0,
              'url': 'https://www.youtube.com/channel/$_a',
              'name': 'Kurzgesagt',
            },
            {
              'service_id': 1,
              'url': 'https://soundcloud.com/someone',
              'name': 'someone',
            },
            {
              'service_id': 0,
              'url': 'https://www.youtube.com/@handle',
              'name': 'by handle',
            },
            {
              'service_id': 0,
              'url': 'https://www.youtube.com/channel/UCtooShort',
              'name': 'bad id',
            },
            // no service_id: YouTube, as NewPipe's reader defaults it
            {'url': 'https://youtube.com/channel/$_b/videos', 'name': 'Dev'},
            {
              'service_id': 0,
              'url': 'https://www.youtube.com/channel/$_a',
              'name': 'again',
            },
          ],
        }),
      );
      expect(file.channels, [
        (channelId: _a, name: 'Kurzgesagt'),
        (channelId: _b, name: 'Dev'),
      ]);
      expect(file.otherService, 1);
      expect(file.invalid, 2);
      expect(file.duplicates, 1);
    });

    test('a JSON file of another shape is refused', () {
      expect(
        () => parseYtSubscriptionFile('{"foo": []}'),
        throwsFormatException,
      );
    });
  });

  test('NewPipe JSON out reads back the same', () {
    final out = toNewPipeSubscriptionsJson(
      [(channelId: _a, name: 'Kurzgesagt'), (channelId: _b, name: '')],
      appVersion: 'LibrePili 0.3.0',
      appVersionInt: 1,
    );
    final map = jsonDecode(out) as Map;
    expect(map['app_version'], 'LibrePili 0.3.0');
    expect(map['app_version_int'], 1);
    expect(map['subscriptions'][0], {
      'service_id': 0,
      'url': 'https://www.youtube.com/channel/$_a',
      'name': 'Kurzgesagt',
    });
    final back = parseYtSubscriptionFile(out);
    expect(back.channels, [
      (channelId: _a, name: 'Kurzgesagt'),
      // an empty name is written as the id: NewPipe drops rows without one
      (channelId: _b, name: _b),
    ]);
  });

  test('Takeout subscriptions.csv, quoted titles and a BOM', () {
    final file = parseYtSubscriptionFile(
      '﻿Channel Id,Channel Url,Channel Title\r\n'
      '$_a,http://www.youtube.com/channel/$_a,"Kurzgesagt, In a Nutshell"\r\n'
      'nonsense,http://example.com,"x"\r\n'
      '$_b,http://www.youtube.com/channel/$_b,"Say ""hi"""\r\n',
    );
    expect(file.channels, [
      (channelId: _a, name: 'Kurzgesagt, In a Nutshell'),
      (channelId: _b, name: 'Say "hi"'),
    ]);
    expect(file.invalid, 1);
  });

  test('a text file with no channel in it is refused', () {
    expect(
      () => parseYtSubscriptionFile('hello\nworld\n'),
      throwsFormatException,
    );
  });

  test('channel ids', () {
    expect(ytChannelIdFrom(_a), _a);
    expect(ytChannelIdFrom('https://www.youtube.com/channel/$_a?x=1'), _a);
    expect(ytChannelIdFrom('UC${'a' * 21}'), isNull);
    expect(ytChannelIdFrom('UC${'a' * 23}'), isNull);
    expect(
      ytChannelIdFrom(
        'https://www.youtube.com/channel/$_a'
        'x',
      ),
      isNull,
    );
  });
}
