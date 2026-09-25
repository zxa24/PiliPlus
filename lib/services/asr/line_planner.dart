/// LibrePili: where a long Chinese sentence breaks into subtitle lines,
/// planned over the whole sentence.
///
/// The line builder used to fill a line and break where the width ran out
/// or at a clause mark once a line was long; a sentence a little wider than
/// a line then kept its comma and lost a word to the next line
/// (「3个月前，我徒手打造了一个」/「生态缸。」). This chooses every break of the
/// sentence at once by dynamic programming over a cost — the method
/// research/line-breaking-2026-09-25.md found closest to human subtitlers:
/// against TED's human Chinese subtitles F1 0.58 against 0.35 for the old
/// rule (95% interval of the gain +18.7 to +26.5), with a parser (0.60) and
/// Gemma (0.61) not better by the margin their cost would need.
///
/// The weights are the ones tuned there on half the talks and scored on the
/// other half; the speaker's pauses (method M3) come on top.
library;

import 'dart:math' as math;

import 'package:PiliPlus/services/asr/asr_cue.dart';

/// The tuned weights (research/line-breaking-2026-09-25.md, frozen.json).
abstract final class _Weights {
  static const clause = -4.0;
  static const phrase = 6.0;
  static const any = 10.0;
  static const leftAttach = 3.0;
  static const rightAttach = 1.5;
  static const de = 1.0;
  static const numeral = 4.0;
  static const measure = 8.0;
  static const short3 = 12.0;
  static const short5 = 1.5;
  static const balance = 4.0;
  static const perLine = 2.0;

  /// A line on screen for less than [_minShown]: the old builder folded
  /// those into the line before, which undid the plan (a sentence's first
  /// words joined the sentence before). Not in the study — it had no clock.
  static const brief = 6.0;

  /// M3: a pause where the line breaks, up to this much…
  static const pauseBonus = 2.0;

  /// …and a break with neither a pause nor a mark.
  static const noPause = 1.0;
}

const _minShown = 1.0;

const _sentenceEnd = '。！？!?…';
const _clauseEnd = '，、；：,;:';
const _closers = '”’」』）)】》〉"\'';
const _openers = '“‘「『（(【《〈';
const _trailing = '$_sentenceEnd$_clauseEnd”’」』）)】》〉';

final _numerals = '0123456789零一二三四五六七八九十百千万亿两几半多'.split('').toSet();
final _measures =
    '个只条张本位件种次场座台部辆头把名家些点群批份片段句层篇年月天周岁块元米度倍分秒项门棵朵颗匹架艘首节届期所间类样套双对滴口声步'
        .split('')
        .toSet();
final _demonstratives = '这那每哪某几'.split('').toSet();
final _leftAttach = '了着过们的地得吗呢吧啊呀么嘛哦啦呐'.split('').toSet();
final _rightAttach = '在把被给对从向和与跟及或将让使比于为自往朝当'.split('').toSet();

bool _alnum(String c) => c.length == 1 && RegExp('[A-Za-z0-9]').hasMatch(c);

bool _fullWidth(String c) => AsrCueBuilder.displayWidth(c) == 2;

/// Where a sentence of [text] may break at all: before [k], never before a
/// mark that ends what came before, after an opening bracket, or inside a
/// number or a Latin word.
bool _allowed(String text, int k) {
  final a = text[k - 1];
  final rest = text.substring(k).trimLeft();
  if (rest.isEmpty) return false;
  if (_trailing.contains(rest[0]) || '"\'.'.contains(rest[0])) return false;
  if (_openers.contains(a)) return false;
  final b = text[k];
  if (_alnum(a) && _alnum(b)) return false;
  if (k >= 2 &&
      a == '.' &&
      RegExp(r'\d').hasMatch(text[k - 2]) &&
      RegExp(r'\d').hasMatch(b)) {
    return false;
  }
  if (RegExp(r'\d').hasMatch(a) && '.%'.contains(b)) return false;
  return true;
}

double _breakCost(String text, int k, Set<int> phraseStarts) {
  var j = k - 1;
  while (j > 0 && _closers.contains(text[j])) {
    j--;
  }
  final a = text[k - 1];
  final rest = text.substring(k).trimLeft();
  final b = rest.isEmpty ? ' ' : rest[0];
  double cost;
  if (_sentenceEnd.contains(text[j])) {
    cost = 0;
  } else if (_clauseEnd.contains(text[j])) {
    cost = _Weights.clause;
  } else if (phraseStarts.contains(k) || text[k] == ' ' || a == ' ') {
    cost = _Weights.phrase;
  } else {
    cost = _Weights.any;
  }
  if (_leftAttach.contains(b)) cost += _Weights.leftAttach;
  if (_rightAttach.contains(a)) cost += _Weights.rightAttach;
  if ('的之'.contains(a) && _fullWidth(b) && !_trailing.contains(b)) {
    cost += _Weights.de;
  }
  if (_numerals.contains(a) &&
      (_measures.contains(b) || _numerals.contains(b))) {
    cost += _Weights.numeral;
  }
  if (_measures.contains(a) &&
      k >= 2 &&
      (_numerals.contains(text[k - 2]) ||
          _demonstratives.contains(text[k - 2]))) {
    cost += _Weights.measure;
  }
  return cost;
}

/// A bonus for a pause where the line breaks (M3). [times] is when each
/// character of [text] starts; [typical] how long one takes.
double _pauseCost(String text, int k, List<double> times, double typical) {
  var j = k - 1;
  while (j >= 0 && '$_sentenceEnd$_clauseEnd$_closers'.contains(text[j])) {
    j--;
  }
  if (j < 0) return 0;
  final excess = times[k] - times[j] - typical * (k - j);
  if (excess > 0) {
    return -_Weights.pauseBonus * math.min(excess, 0.6) / 0.6;
  }
  final marked = '$_sentenceEnd$_clauseEnd$_closers'.contains(text[k - 1]);
  return marked ? 0 : _Weights.noPause;
}

/// Where [text] — one sentence — breaks into lines of at most [cap] wide:
/// the offsets lines start at, after the first. None when it fits.
///
/// [phraseStarts] are BudouX's phrase starts, [breakable] where the caller
/// can end a line at all (a token boundary). With [times] (start of each
/// character) and [typical], pauses count (M3), and a line held longer
/// than [maxDuration] is out; a line shown for less than a second costs.
List<int> planLineBreaks(
  String text, {
  required Set<int> phraseStarts,
  bool Function(int offset)? breakable,
  List<double>? times,
  double typical = 0.3,
  int cap = 32,
  double maxDuration = 6,
}) {
  final n = text.length;
  int widthOf(int a, int b) =>
      AsrCueBuilder.displayWidth(text.substring(a, b).trim());
  double? spanOf(int a, int b) =>
      times == null ? null : times[b - 1] + typical - times[a];
  final total = AsrCueBuilder.displayWidth(text);
  final wholeSpan = spanOf(0, n);
  if (total <= cap && (wholeSpan == null || wholeSpan <= maxDuration)) {
    return const [];
  }
  final candidates = [
    for (var k = 1; k < n; k++)
      if (_allowed(text, k) && (breakable?.call(k) ?? true)) k,
  ];
  final breakCost = {
    for (final k in candidates)
      k:
          _breakCost(text, k, phraseStarts) +
          (times == null ? 0 : _pauseCost(text, k, times, typical)),
  };
  final nodes = [0, ...candidates, n];
  double? lineCost(int a, int b, double target) {
    final w = widthOf(a, b);
    if (w > cap) return null;
    final span = spanOf(a, b);
    // one piece held too long is still one piece
    if (span != null && span > maxDuration && b - a > 1) return null;
    final chars = text.substring(a, b).trim().length;
    var cost = _Weights.perLine;
    if (chars <= 3) {
      cost += _Weights.short3;
    } else if (chars <= 5) {
      cost += _Weights.short5;
    }
    cost += _Weights.balance * math.pow((w - target) / cap, 2);
    if (span != null && span < _minShown) cost += _Weights.brief;
    return cost;
  }

  final fewest = math.max(1, (total / cap).ceil());
  (double, List<int>)? best;
  for (var lines = math.max(fewest, 1); lines < fewest + 4; lines++) {
    final target = total / lines;
    const inf = double.infinity;
    final cost = List.generate(
      lines + 1,
      (_) => List<double>.filled(nodes.length, inf),
    );
    final back = List.generate(
      lines + 1,
      (_) => List<int>.filled(nodes.length, -1),
    );
    cost[0][0] = 0;
    for (var l = 1; l <= lines; l++) {
      for (var j = 1; j < nodes.length; j++) {
        if (l < lines && j == nodes.length - 1) continue;
        if (l == lines && j != nodes.length - 1) continue;
        final end = nodes[j];
        for (var i = j - 1; i >= 0; i--) {
          if (cost[l - 1][i] == inf) continue;
          final start = nodes[i];
          if (widthOf(start, end) > cap) {
            // only wider further back
            if (AsrCueBuilder.displayWidth(text.substring(start, end)) >
                cap + 2) {
              break;
            }
            continue;
          }
          final line = lineCost(start, end, target);
          if (line == null) continue;
          final c = cost[l - 1][i] + line + (end == n ? 0 : breakCost[end]!);
          if (c < cost[l][j]) {
            cost[l][j] = c;
            back[l][j] = i;
          }
        }
      }
    }
    final last = cost[lines][nodes.length - 1];
    if (last < inf && (best == null || last < best.$1)) {
      final breaks = <int>[];
      var j = nodes.length - 1;
      for (var l = lines; l > 0; l--) {
        final i = back[l][j];
        if (i > 0) breaks.add(nodes[i]);
        j = i;
      }
      best = (last, breaks.reversed.toList());
    }
  }
  if (best != null) return best.$2;
  // nothing satisfies every rule (an unbreakable run wider than a line):
  // fill lines to the width
  final breaks = <int>[];
  var width = 0;
  for (var k = 0; k < n; k++) {
    final w = AsrCueBuilder.displayWidth(text[k]);
    if (width + w > cap && k > 0 && (breakable?.call(k) ?? true)) {
      breaks.add(k);
      width = 0;
    }
    width += w;
  }
  return breaks;
}
