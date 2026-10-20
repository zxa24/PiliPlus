import 'package:PiliPlus/services/youtube/yt_subscription_feed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('relative ages, in the languages YouTube answers in', () {
    expect(parseYtRelativeAge('10天前'), const Duration(days: 10));
    expect(parseYtRelativeAge('1个月前'), const Duration(days: 30));
    expect(parseYtRelativeAge('2周前'), const Duration(days: 14));
    expect(parseYtRelativeAge('3 小时前'), const Duration(hours: 3));
    expect(parseYtRelativeAge('5分钟前'), const Duration(minutes: 5));
    expect(parseYtRelativeAge('1 年前'), const Duration(days: 365));
    expect(parseYtRelativeAge('2 個月前'), const Duration(days: 60));
    expect(parseYtRelativeAge('3 days ago'), const Duration(days: 3));
    expect(
      parseYtRelativeAge('Streamed 2 weeks ago'),
      const Duration(days: 14),
    );
    expect(parseYtRelativeAge('1 hour ago'), const Duration(hours: 1));
    expect(parseYtRelativeAge('3 日前'), const Duration(days: 3));
    // not relative: not guessed at
    expect(parseYtRelativeAge('2025年1月5日'), isNull);
    expect(parseYtRelativeAge('直播中'), isNull);
    expect(parseYtRelativeAge(null), isNull);
  });

  test('one list, newest first; undated last in the order they came', () {
    // (channel, published) in channel-by-channel order
    final items = [
      ('a', '3天前'),
      ('a', null),
      ('a', '2个月前'),
      ('b', '5小时前'),
      ('b', '2025年1月5日'),
      ('c', '3天前'),
      ('c', '1周前'),
    ];
    expect(sortYtFeedByAge(items, (e) => e.$2), [
      ('b', '5小时前'),
      ('a', '3天前'),
      ('c', '3天前'),
      ('c', '1周前'),
      ('a', '2个月前'),
      ('a', null),
      ('b', '2025年1月5日'),
    ]);
  });

  test('the pool answers in order and never runs more than asked', () async {
    var running = 0;
    var peak = 0;
    final out = await runYtPooled([1, 2, 3, 4, 5, 6, 7], 3, (n) async {
      running++;
      if (running > peak) peak = running;
      await Future<void>.delayed(Duration(milliseconds: 8 - n));
      running--;
      return n * 10;
    });
    expect(out, [10, 20, 30, 40, 50, 60, 70]);
    expect(peak, 3);
    expect(await runYtPooled(<int>[], 3, (n) async => n), isEmpty);
  });
}
