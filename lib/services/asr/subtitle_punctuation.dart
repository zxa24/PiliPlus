/// LibrePili: punctuation as subtitles show it, which is not how text is
/// written.
///
/// Subtitling drops the marks a line break or a gap already makes, by
/// language (research/subtitle-punctuation-2026-09-24.md; Netflix's Timed
/// Text Style Guides are the only source found with rules per language —
/// no Chinese broadcast standard read has any):
/// - Simplified Chinese: no commas or full stops, one space instead;
///   question and exclamation marks stay; an enumeration comma is not left
///   at the end of a line.
/// - Traditional Chinese: no full stops of any kind; the comma stays inside
///   a line but not at its end; question and exclamation marks stay.
/// - Japanese: 。 becomes a full-width space and 、 a half-width one; ？ and
///   ！ stay, a full-width space after them when a sentence follows.
/// - Everything else — English and the rest — keeps normal punctuation.
///
/// Applied only when a line is shown. Where to break a line and what to
/// translate are decided on the punctuated text, and only subtitles made on
/// the device are changed: a video's own were written by someone.
library;

import 'package:PiliPlus/services/asr/asr_cue.dart';

/// [line] with its punctuation as a subtitle in [language] shows it. Lines
/// in a language without such rules come back as they are.
String punctuateForDisplay(String line, String? language) {
  final rules = _rulesFor(language);
  if (rules == null || line.isEmpty) return line;
  return rules(line);
}

/// Each line of each cue's content, the way [punctuateForDisplay] shows it.
extension AsrCueDisplay on List<AsrCue> {
  List<AsrCue> forDisplay(String? language) {
    if (_rulesFor(language) == null) return this;
    return [
      for (final cue in this)
        AsrCue(
          from: cue.from,
          to: cue.to,
          content: cue.content
              .split('\n')
              .map((line) => punctuateForDisplay(line, language))
              .join('\n'),
        ),
    ];
  }
}

String Function(String)? _rulesFor(String? language) {
  final tag = language?.toLowerCase() ?? '';
  if (tag.isEmpty) return null;
  if (tag == 'zh-hant' || tag == 'zh-tw' || tag == 'zh-hk') {
    return _traditionalChinese;
  }
  if (tag == 'zh' || tag.startsWith('zh-') || tag == 'yue') {
    return _simplifiedChinese;
  }
  if (tag == 'ja' || tag.startsWith('ja-')) return _japanese;
  return null;
}

const _fullWidthSpace = '　';

String _simplifiedChinese(String line) {
  var out = line.replaceAll(RegExp('[，。]+'), ' ');
  // "？ then the next sentence" ran together once the full stops were
  // gone; a space after it, as after every other end (inference: the guide
  // says nothing about it)
  out = out.replaceAllMapped(
    RegExp(r'([？！])(?=[^\s？！”’」』）)])'),
    (m) => '${m[1]} ',
  );
  out = _collapse(out);
  // an enumeration comma is for inside a list, not the end of a line
  while (out.endsWith('、')) {
    out = out.substring(0, out.length - 1).trimRight();
  }
  return out;
}

String _traditionalChinese(String line) {
  // no full stop of any kind; one in mid-line leaves a space so the two
  // sentences do not run together (inference: the guide does not say)
  var out = line.replaceAll(RegExp('[。．]+'), ' ');
  out = out.replaceAllMapped(
    RegExp(r'([？！])(?=[^\s？！”’」』）)])'),
    (m) => '${m[1]} ',
  );
  out = _collapse(out);
  // the comma stays inside a line, not at its end
  while (out.isNotEmpty && '，、'.contains(out[out.length - 1])) {
    out = out.substring(0, out.length - 1).trimRight();
  }
  return out;
}

String _japanese(String line) {
  var out = line
      .replaceAll(RegExp('。+'), _fullWidthSpace)
      .replaceAll(RegExp('、+'), ' ');
  // a sentence after ？ or ！ on the same line starts after a full-width
  // space
  out = out.replaceAllMapped(
    RegExp('([？！])(?=[^\\s$_fullWidthSpace？！」』）)])'),
    (m) => '${m[1]}$_fullWidthSpace',
  );
  // nothing at either end, and no two spaces in a row
  out = out
      .replaceAll(
        RegExp('[ $_fullWidthSpace]*$_fullWidthSpace[ $_fullWidthSpace]*'),
        _fullWidthSpace,
      )
      .replaceAll(RegExp(' {2,}'), ' ');
  return out.replaceAll(
    RegExp('^[ $_fullWidthSpace]+|[ $_fullWidthSpace]+\$'),
    '',
  );
}

String _collapse(String text) => text.replaceAll(RegExp(' {2,}'), ' ').trim();
