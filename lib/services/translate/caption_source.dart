/// LibrePili: a video's own captions as translation input.
///
/// A video that ships captions in a language the user does not read is
/// better served by translating those than by transcribing the audio: the
/// text is what the author (or the platform) wrote, punctuation included,
/// and nothing has to be recognised (decision B, 2026-09-23). Transcription
/// still covers videos with no captions at all.
library;

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/translate/translation_unit.dart';

final _timing = RegExp(
  r'((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})',
);
final _tag = RegExp(r'<[^>]*>');

/// A line that is only a sound event: `[Music]`, `[音楽]`, `(laughs)`, `♪`.
///
/// Short on purpose: TED's tracks put on-screen text in brackets too —
/// `[This is not a toilet. It's over there]` — and that is text to
/// translate, not a noise.
final _event = RegExp(r'^(\[[^\]]{1,15}\]|\([^)]{1,15}\)|（[^）]{1,15}）|♪+)$');

double _seconds(String stamp) {
  final parts = stamp.replaceAll(',', '.').split(':');
  var total = 0.0;
  for (final part in parts) {
    total = total * 60 + double.parse(part);
  }
  return total;
}

/// The cues of a WebVTT (or SRT) caption file, as text to translate.
///
/// YouTube's automatic captions are written for a rolling display: every
/// cue repeats the line before it, carries per-word timing tags, and is
/// followed by a 10 ms cue that holds the finished line. Read naively, each
/// sentence would arrive two or three times. So tags are stripped, a line
/// the previous cue already showed is dropped, cues too brief to be seen
/// are skipped, and sound events (`[Music]`) are not speech.
List<AsrCue> parseCaptionCues(String text) {
  // Line by line, not block by block: the rolling format pads its cues with
  // lines holding a single space, which a split on blank lines took for a
  // cue boundary and so lost every cue's first line.
  final blocks = <({double from, double to, List<String> body})>[];
  for (final line in text.replaceAll('\r\n', '\n').split('\n')) {
    final match = _timing.firstMatch(line);
    if (match != null) {
      // an SRT counter or a VTT cue id sits right above its timing line
      if (blocks.isNotEmpty && blocks.last.body.isNotEmpty) {
        final last = blocks.last.body.last;
        if (RegExp(r'^\d+$').hasMatch(last)) blocks.last.body.removeLast();
      }
      blocks.add((
        from: _seconds(match[1]!),
        to: _seconds(match[2]!),
        body: <String>[],
      ));
      continue;
    }
    final clean = line.replaceAll(_tag, '').trim();
    if (clean.isNotEmpty && blocks.isNotEmpty) blocks.last.body.add(clean);
  }

  final cues = <AsrCue>[];
  var previous = const <String>[];
  for (final (:from, :to, :body) in blocks) {
    if (to - from < 0.05) {
      // the rolling display's hold cue: its text is the line just shown
      if (body.isNotEmpty) previous = body;
      continue;
    }
    final fresh = [
      for (final line in body)
        if (!previous.contains(line) && !_event.hasMatch(line)) line,
    ];
    previous = body;
    if (fresh.isEmpty) continue;
    cues.add(AsrCue(from: from, to: to, content: fresh.join(' ')));
  }
  return cues;
}

/// A pause longer than this ends a unit even without punctuation.
const _captionGap = 1.5;

/// Units are kept to about what a VAD segment gives transcription.
const _captionMaxCues = 4;
const _captionMaxWidth = 200;

const _sentenceEnd = '。！？.!?…';
const _closers = '"”’」』）)】';

bool _endsSentence(String text) {
  var t = text.trimRight();
  while (t.isNotEmpty && _closers.contains(t[t.length - 1])) {
    t = t.substring(0, t.length - 1);
  }
  return t.isNotEmpty && _sentenceEnd.contains(t[t.length - 1]);
}

/// Groups caption cues into sentences to translate.
///
/// A caption line is cut for the screen, like a transcript's, so a sentence
/// spans several. Unlike a transcript, an author's punctuation is real: a
/// unit ends at a sentence end. Captions with little punctuation (YouTube's
/// automatic ones) fall back on pauses, and every unit is capped so none
/// runs on.
List<TranslationUnit> buildCaptionUnits(List<AsrCue> cues) {
  final units = <TranslationUnit>[];
  var current = <AsrCue>[];
  var width = 0;
  void close() {
    if (current.isEmpty) return;
    units.add(
      TranslationUnit(
        from: current.first.from,
        to: current.last.to,
        text: joinCueText([for (final c in current) c.content]),
        cues: current,
      ),
    );
    current = [];
    width = 0;
  }

  for (var i = 0; i < cues.length; i++) {
    final cue = cues[i];
    current.add(cue);
    width += AsrCueBuilder.displayWidth(cue.content);
    final next = i + 1 < cues.length ? cues[i + 1] : null;
    if (next == null ||
        _endsSentence(cue.content) ||
        next.from - cue.to > _captionGap ||
        current.length >= _captionMaxCues ||
        width >= _captionMaxWidth) {
      close();
    }
  }
  close();
  return units;
}

/// A caption track as far as choosing one is concerned.
typedef CaptionChoice = ({String language, bool generated});

/// The major language of a platform's language tag: `en-US` → `en`,
/// bilibili's AI tracks `ai-zh` → `zh`, `zh-Hans` → `zh`.
String captionLanguage(String tag) {
  var t = tag.trim().toLowerCase();
  if (t.startsWith('ai-')) t = t.substring(3);
  return t.split(RegExp('[-_]')).first;
}

/// Which of [tracks] to translate into [appLanguage], by index, or null.
///
/// None when a track is already in the app's language — the user reads that
/// one. Otherwise an author's track before a generated one: it is the
/// better-written text, and on YouTube the generated one is a transcript.
///
/// Among authors' tracks, the one in the language spoken: translating a
/// translation compounds two sets of errors. A generated track says what
/// that language is (it is a transcript of the audio); without one, English
/// is the likeliest original — "Me at the zoo" ships German and English,
/// German first, and is in English. With the spoken language known and no
/// author's track in it, the generated track itself: a transcript of the
/// audio beats a translation into a third language.
int? pickCaptionToTranslate(
  List<CaptionChoice> tracks, {
  required String appLanguage,
}) {
  if (tracks.any(
    (t) => AsrService.isSameMajorLanguage(
      captionLanguage(t.language),
      appLanguage,
    ),
  )) {
    return null;
  }
  final usable = [
    for (final (i, t) in tracks.indexed)
      if (captionLanguage(t.language).isNotEmpty) i,
  ];
  if (usable.isEmpty) return null;
  final spoken = [
    for (final i in usable)
      if (tracks[i].generated) captionLanguage(tracks[i].language),
  ].firstOrNull;
  final authors = [
    for (final i in usable)
      if (!tracks[i].generated) i,
  ];
  int? authorIn(String language) => authors
      .where((i) => captionLanguage(tracks[i].language) == language)
      .firstOrNull;
  if (spoken != null) {
    // no author wrote in the spoken language: the transcript of the audio
    // beats someone's translation into a third language
    return authorIn(spoken) ?? usable.firstWhere((i) => tracks[i].generated);
  }
  return authorIn('en') ?? authors.firstOrNull ?? usable.first;
}
