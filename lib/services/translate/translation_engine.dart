/// LibrePili: the one thing translation asks of a model runtime.
///
/// The runtime is llama.cpp through llamadart, with its weight repacking
/// turned off on phones (LiteRT-LM was measured and not adopted, see
/// pubspec.yaml). Everything above this line — units, scheduling, layout —
/// is written against a single chat turn in, text out, and does not know or
/// care, so another runtime can still be put behind it.
library;

import 'package:PiliPlus/services/asr/asr_cue.dart';

abstract interface class TranslationEngine {
  /// One user turn, one reply. Greedy decoding: the same input must give
  /// the same output, or a republished track could change under the viewer.
  ///
  /// With the model's thinking mode off. Gemma 4 thinks by default, and a
  /// replay without the switch came back empty or cut to one character for
  /// 24 of 71 English units: the thinking used up the token budget before
  /// any translation was written.
  Future<String> complete(String prompt);

  /// Ends a [complete] in progress early, so a stop does not wait out a
  /// unit of up to a few hundred tokens with the model still resident. What
  /// the cut-short call returns is not used.
  void cancel();

  /// Frees the model. The engine is not used again afterwards.
  Future<void> dispose();
}

/// The prompt a unit is sent with.
///
/// The Chinese wording is the model card's "Default Translation" prompt,
/// the one every model in research/translation-bench-2026-09-23.md was
/// scored with. Asking for 简体中文 instead was tried against a report of
/// traditional characters: none turned up in 117 segments with either
/// wording (the one case seen came from a prompt with context), and the
/// scores moved by −1.0 / −0.2 chrF, within noise. Kept as measured.
String translationPrompt(
  String text, {
  required String target,
}) => switch (target) {
  'zh' => '将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释：\n\n$text',
  _ =>
    'Translate the following text into ${_languageNames[target] ?? target}. '
        'Output only the translation, with no explanation:\n\n$text',
};

const _languageNames = {
  'en': 'English',
  'ja': 'Japanese',
  'ko': 'Korean',
};

final _think = RegExp(r'<think>.*?</think>', dotAll: true);

/// What of a model's reply is the translation, or null if none of it is.
///
/// Null sends the caller back to the source text. A reply is rejected when
/// it is empty, or when it is so much longer than the source that the model
/// has plainly written something other than a translation — the failure
/// small models have is continuing, explaining or repeating, and a
/// subtitle that runs for three lines is worse than the original words.
String? cleanTranslation(String reply, {required String source}) {
  var text = reply.replaceAll(_think, '').trim();
  // a reply wrapped in quotes or a code fence is the model being helpful
  for (final (open, close) in const [
    ('```', '```'),
    ('"', '"'),
    ('“', '”'),
    ('「', '」'),
  ]) {
    if (text.length > open.length + close.length &&
        text.startsWith(open) &&
        text.endsWith(close) &&
        !source.trim().startsWith(open)) {
      final inner = text.substring(open.length, text.length - close.length);
      // only a pair around the whole reply: `"Yes," he said, "no."` starts
      // and ends with a quote, but they are two quotations
      if (inner.contains(open) || inner.contains(close)) continue;
      text = inner.trim();
    }
  }
  if (text.isEmpty) return null;
  final limit = AsrCueBuilder.displayWidth(source) * 3 + 24;
  if (AsrCueBuilder.displayWidth(text) > limit) return null;
  return text;
}
