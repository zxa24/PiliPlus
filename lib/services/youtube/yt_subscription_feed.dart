/// LibrePili: the pieces of the subscription feed that need no network —
/// reading YouTube's 「3天前」 back into an age, ordering the merged feed by
/// it, and asking many channels a few at a time.
library;

/// How long ago [text] says something was published, or null when it says
/// nothing this can read.
///
/// The channel feed only ever gives relative text, in whatever language
/// `hl` asked for: 「10天前」 / 「1个月前」 (measured 2026-10-19, zh-CN),
/// "3 days ago", "Streamed 2 weeks ago", 「3 日前」. A month is read as 30
/// days and a year as 365, which is what YouTube's own rounding means. Text
/// without a 「前」 / "ago" (an absolute date, 「直播中」) is not guessed at.
Duration? parseYtRelativeAge(String? text) {
  if (text == null || text.isEmpty) return null;
  final t = text.toLowerCase();
  if (!_agoMarker.hasMatch(t)) return null;
  final m = _amountUnit.firstMatch(t);
  if (m == null) return null;
  final n = int.tryParse(m.group(1)!);
  if (n == null) return null;
  final unit = m.group(2)!;
  for (final (pattern, step) in _units) {
    if (pattern.hasMatch(unit)) return step * n;
  }
  return null;
}

final _agoMarker = RegExp(r'前|ago|전');

final _amountUnit = RegExp(
  r'(\d+)\s*(秒|分钟|分鐘|分|小时|小時|時間|天|日|周|週|个月|個月|か月|ヶ月|月|年|'
  r'seconds?|minutes?|mins?|hours?|days?|weeks?|months?|years?|초|분|시간|일|주|개월|년)',
);

const _second = Duration(seconds: 1);

final _units = <(RegExp, Duration)>[
  (RegExp(r'^(秒|seconds?|초)$'), _second),
  (RegExp(r'^(分钟|分鐘|分|minutes?|mins?|분)$'), _second * 60),
  (RegExp(r'^(小时|小時|時間|hours?|시간)$'), _second * 3600),
  (RegExp(r'^(天|日|days?|일)$'), const Duration(days: 1)),
  (RegExp(r'^(周|週|weeks?|주)$'), const Duration(days: 7)),
  (RegExp(r'^(个月|個月|か月|ヶ月|月|months?|개월)$'), const Duration(days: 30)),
  (RegExp(r'^(年|years?|년)$'), const Duration(days: 365)),
];

/// [items] as one list, newest first by [publishedText]'s age. Items it
/// cannot date go after every dated one, in the order they came (channel by
/// channel); equal ages keep that order too.
List<T> sortYtFeedByAge<T>(
  List<T> items,
  String? Function(T) publishedText,
) {
  final keyed =
      [
        for (final (i, item) in items.indexed)
          (i, parseYtRelativeAge(publishedText(item)), item),
      ]..sort((a, b) {
        final (ia, aa, _) = a;
        final (ib, ab, _) = b;
        if (aa != null && ab != null) {
          final c = aa.compareTo(ab);
          if (c != 0) return c;
        } else if (aa != null) {
          return -1;
        } else if (ab != null) {
          return 1;
        }
        return ia.compareTo(ib);
      });
  return [for (final (_, _, item) in keyed) item];
}

/// [task] for every one of [inputs], at most [concurrency] at a time. The
/// answers come back in [inputs]' order; [task] is expected not to throw
/// (a failed channel is an answer, not an exception).
Future<List<R>> runYtPooled<T, R>(
  List<T> inputs,
  int concurrency,
  Future<R> Function(T) task,
) async {
  final out = List<R?>.filled(inputs.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < inputs.length) {
      final i = next++;
      out[i] = await task(inputs[i]);
    }
  }

  await Future.wait([
    for (var w = 0; w < concurrency && w < inputs.length; w++) worker(),
  ]);
  return [for (final r in out) r as R];
}
