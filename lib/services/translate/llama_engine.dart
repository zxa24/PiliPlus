/// LibrePili: [TranslationEngine] on llama.cpp, through llamadart.
///
/// Settings are the ones the model was measured with
/// (research/translation-bench-2026-09-23.md), not llamadart's defaults:
/// greedy, no repetition penalty (llamadart defaults to 1.1), no prompt
/// prefix reuse, thinking off.
library;

import 'package:PiliPlus/services/translate/translation_engine.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:llamadart/llamadart.dart';

class LlamaTranslationEngine implements TranslationEngine {
  LlamaTranslationEngine._(this._engine);

  final LlamaEngine _engine;

  /// Whether the CPU backend may repack weights here: on desktops only.
  static bool get repacks => !PlatformUtils.isMobile;

  /// Loads the GGUF at [path]. Throws if it cannot be loaded.
  static Future<LlamaTranslationEngine> load(String path) async {
    final engine = LlamaEngine(LlamaBackend());
    try {
      await engine.loadModel(
        path,
        modelParams: ModelParams(
          // a unit is one VAD segment: at most two 20 s stretches of speech,
          // a few hundred tokens with the prompt and the reply
          contextSize: 2048,
          gpuLayers: 0,
          // the phone measurements ran with four; the recogniser has the rest
          numberOfThreads: PlatformUtils.isMobile ? 4 : 0,
          // Off on phones ([repacks]): repacked weights are a second,
          // anonymous copy of the model — +1.8 GB measured on a 6 GB Pixel 4
          // XL, where the mapped file alone is paged in and out as needed.
          // Desktops have the room and get the faster layout.
          //
          // This parameter does not exist in llamadart as published. It is
          // added by lib/scripts/llamadart/extra_buffers.patch, which CI's
          // lib/scripts/patch.ps1 applies after `pub get`. If this line does
          // not compile, the patch is missing — any `pub get` that fetched
          // llamadart afresh undoes it — and the fix is not to delete the
          // line. Locally, apply the patch inside the package in the pub
          // cache: `git apply <repo>/lib/scripts/llamadart/
          // extra_buffers.patch`, run in its llamadart-0.8.24 directory
          // (hosted/pub.dev). patch.ps1 itself is for CI only: it fetches
          // llamadart afresh, reads the patch through $GITHUB_WORKSPACE and
          // patches the Flutter SDK as well.
          useExtraBuffers: repacks,
        ),
      );
    } catch (_) {
      await engine.dispose();
      rethrow;
    }
    return LlamaTranslationEngine._(engine);
  }

  /// How the last [complete] went, for the event log: whether a slow line
  /// is slow reading its prompt (up to the first piece of the reply) or
  /// writing the reply.
  ({int promptTokens, int replyTokens, int firstMs, int totalMs})? lastStats;

  @override
  Future<String> complete(String prompt) async {
    final out = StringBuffer();
    final clock = Stopwatch()..start();
    int? firstMs;
    await for (final chunk in _engine.create(
      [LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt)],
      params: const GenerationParams(
        maxTokens: 384,
        temp: 0,
        penalty: 1.0,
        reusePromptPrefix: false,
      ),
      enableThinking: false,
    )) {
      final text = chunk.choices.first.delta.content;
      if (text != null) {
        firstMs ??= clock.elapsedMilliseconds;
        out.write(text);
      }
    }
    final totalMs = clock.elapsedMilliseconds;
    final reply = out.toString();
    // counted after the reply, off the clock: a tokenisation is cheap
    // beside the generation, and the reply is what it measures
    lastStats = (
      promptTokens: await _engine.getTokenCount(prompt),
      replyTokens: await _engine.getTokenCount(reply),
      firstMs: firstMs ?? totalMs,
      totalMs: totalMs,
    );
    return reply;
  }

  @override
  void cancel() => _engine.cancelGeneration();

  @override
  Future<void> dispose() => _engine.dispose();
}
