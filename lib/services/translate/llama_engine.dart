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
          // added by lib/scripts/llamadart/extra_buffers.patch, which
          // lib/scripts/patch.ps1 applies after `pub get`. If this line does
          // not compile, the patch is missing — any `pub get` that fetched
          // llamadart afresh undoes it — and the fix is to run patch.ps1,
          // not to delete the line.
          useExtraBuffers: repacks,
        ),
      );
    } catch (_) {
      await engine.dispose();
      rethrow;
    }
    return LlamaTranslationEngine._(engine);
  }

  @override
  Future<String> complete(String prompt) async {
    final out = StringBuffer();
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
      if (text != null) out.write(text);
    }
    return out.toString();
  }

  @override
  Future<void> dispose() => _engine.dispose();
}
