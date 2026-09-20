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
