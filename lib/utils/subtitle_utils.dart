import 'package:PiliPlus/models/common/enum_with_label.dart';
import 'package:collection/collection.dart' show IterableExtension;

enum SubtitleFormat implements EnumWithLabel {
  json('JSON'),
  vtt('WEBVTT'),
  srt('SRT');

  @override
  final String label;
  const SubtitleFormat(this.label);
}

abstract final class SubtitleUtils {
  static String _vttTimecode(num seconds) {
    // round to whole milliseconds first: formatting the seconds remainder on
    // its own turns 59.9996 into "60.000", which strict players reject
    final total = (seconds * 1000).round();
    final ms = (total % 1000).toString().padLeft(3, '0');
    final s = total ~/ 1000;
    final h = (s ~/ 3600).toString().padLeft(2, '0');
    final m = (s % 3600 ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toString().padLeft(2, '0');
    return "$h:$m:$sec.$ms";
  }

  static String json2Vtt(List list) {
    final sb = StringBuffer('WEBVTT\n\n')
      ..writeAll(
        list.map(
          (item) =>
              '${_vttTimecode(item['from'])} --> ${_vttTimecode(item['to'])}\n${item['content'].trim()}',
        ),
        '\n\n',
      );
    return sb.toString();
  }

  static final _vttCue = RegExp(
    r'^(?:(\d+):)?(\d{1,2}):(\d{2})\.(\d{3})\s+-->\s+(?:(\d+):)?(\d{1,2}):(\d{2})\.(\d{3})',
  );

  static double _vttSeconds(RegExpMatch m, int at) =>
      int.parse(m[at] ?? '0') * 3600 +
      int.parse(m[at + 1]!) * 60 +
      int.parse(m[at + 2]!) +
      int.parse(m[at + 3]!) / 1000;

  /// LibrePili: [json2Vtt] backwards — `{from, to, content}` for each cue
  /// of [vtt]. For a track kept only as the VTT it was shown as (an
  /// on-device subtitle whose session was stopped), saved in another format.
  static List<Map<String, dynamic>> vtt2Json(String vtt) {
    final out = <Map<String, dynamic>>[];
    final blocks = vtt.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      final lines = block.split('\n');
      final at = lines.indexWhere((l) => _vttCue.hasMatch(l.trim()));
      if (at == -1) continue;
      final m = _vttCue.firstMatch(lines[at].trim())!;
      out.add({
        'from': _vttSeconds(m, 1),
        'to': _vttSeconds(m, 5),
        'content': lines.skip(at + 1).join('\n').trim(),
      });
    }
    return out;
  }

  static String _srtTimecode(num seconds) {
    // as in [_vttTimecode]: rounding the millisecond part on its own can
    // produce ",1000"
    final total = (seconds * 1000).round();
    final ms = (total % 1000).toString().padLeft(3, '0');
    final s = total ~/ 1000;
    final h = (s ~/ 3600).toString().padLeft(2, '0');
    final m = (s % 3600 ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$h:$m:$sec,$ms';
  }

  static String json2Srt(List list) {
    final sb = StringBuffer()
      ..writeAll(
        list.mapIndexed(
          (i, e) =>
              '${i + 1}\n${_srtTimecode(e['from'])} --> ${_srtTimecode(e['to'])}\n${e['content'].trim()}',
        ),
        '\n\n',
      );
    return sb.toString();
  }
}
