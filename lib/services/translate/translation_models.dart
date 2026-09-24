/// LibrePili: the translation models, where they come from, and the hash
/// each must have.
///
/// Described with the same types as the recogniser's models so the same
/// store downloads, resumes and verifies them. Downloaded on demand into the
/// app's data directory, never bundled.
///
/// Both are the exact files measured in
/// research/translation-bench-2026-09-23.md (hashes checked against the
/// benchmarked copies), from the publishers' own repositories, pinned to a
/// commit so a later upload under the same name cannot change what arrives.
/// There is no mirror: at 2.8 GB Gemma is over GitHub's release asset limit.
library;

import 'package:PiliPlus/models/common/enum_with_label.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';

abstract final class TranslationModelCatalog {
  /// The default on every platform (decision 1C, 2026-09-23): best quality
  /// measured, EN chrF 36.3 vs 30.7 for Hy-MT2 on recognised speech.
  /// llama.cpp's own organisation; Apache-2.0.
  static const gemma = AsrModel(
    id: 'gemma-4-e2b-it-q4_0',
    label: 'Gemma 4 E2B（推荐）',
    languages: [],
    files: [
      AsrModelFile(
        name: 'gemma-4-E2B-it-Q4_0.gguf',
        size: 2841481184,
        sha256:
            '8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52',
        sources: [
          AsrSource(
            url:
                'https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/'
                'b4243c156154b6dca9324415f8c7ccc098b4aed1/'
                'gemma-4-E2B-it-Q4_0.gguf',
          ),
        ],
      ),
    ],
  );

  /// The smaller choice: 1.1 GB, a dedicated translation model, measured
  /// faithful and a little weaker. Tencent's own repository; Apache-2.0.
  static const hy = AsrModel(
    id: 'hy-mt2-1.8b-q4_k_m',
    label: 'Hy-MT2 1.8B（体积小）',
    languages: [],
    files: [
      AsrModelFile(
        name: 'Hy-MT2-1.8B-Q4_K_M.gguf',
        size: 1133080448,
        sha256:
            'dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699',
        sources: [
          AsrSource(
            url:
                'https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/'
                'a0c709d9fac510f2c807aa3af52872340dc37a4a/'
                'Hy-MT2-1.8B-Q4_K_M.gguf',
          ),
        ],
      ),
    ],
  );

  static const all = <AsrModel>[gemma, hy];

  /// The model for a stored id; the default for anything unknown.
  static AsrModel byId(String? id) =>
      all.where((model) => model.id == id).firstOrNull ?? gemma;
}

/// The catalog as a settings choice.
enum TranslationModelChoice implements EnumWithLabel {
  gemma(TranslationModelCatalog.gemma, 'Gemma 4 E2B（推荐，2.8 GB）'),
  hy(TranslationModelCatalog.hy, 'Hy-MT2 1.8B（体积小，1.1 GB）');

  const TranslationModelChoice(this.model, this.label);
  final AsrModel model;

  @override
  final String label;

  static TranslationModelChoice of(AsrModel model) =>
      values.firstWhere((choice) => choice.model.id == model.id);
}
