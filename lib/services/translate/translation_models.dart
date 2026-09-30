/// LibrePili: the translation models, where they come from, and the hash
/// each must have.
///
/// Described with the same types as the recogniser's models so the same
/// store downloads, resumes and verifies them. Downloaded on demand into the
/// app's data directory, never bundled.
///
/// Both are the exact files measured in
/// research/translation-bench-2026-09-23.md (hashes checked against the
/// benchmarked copies), pinned to a commit so a later upload under the same
/// name cannot change what arrives. Gemma has no mirror: at 2.8 GB it is
/// over GitHub's release asset limit.
library;

import 'package:PiliPlus/models/common/enum_with_label.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/utils/platform_utils.dart';

abstract final class TranslationModelCatalog {
  /// The desktops' default (decision 1C, 2026-09-23; phones since
  /// 2026-09-30 take [indexTranslate]): best quality measured then, EN chrF 36.3 vs
  /// 30.7 for Hy-MT2 on recognised speech. llama.cpp's own organisation;
  /// Apache-2.0.
  static const gemma = AsrModel(
    id: 'gemma-4-e2b-it-q4_0',
    label: 'Gemma 4 E2B',
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

  /// The smaller choice, and the phones' default (user 2026-09-30, 1A 2B):
  /// Index-Translate-2B, bilibili's own translation model (Qwen3.5, Apache
  /// 2.0), in place of Hy-MT2-1.8B. On the app's recognised speech it tied
  /// Gemma in English (chrF 33.3 vs 34.5, CI across 0) and scored higher in
  /// Japanese (20.1 vs 18.6), and beat Hy-MT2 everywhere (Japanese +3.0,
  /// significant); on a Pixel 6 Pro 17-26 % faster than Gemma with 1.7 GB
  /// less memory (research/translation-bench-2026-09-23.md, Index-Translate).
  /// The GGUF is the community quantisation (mradermacher; the publisher
  /// ships safetensors only), pinned to a commit, hash checked against the
  /// measured copy; under 2 GB, so the project's mirror carries it too.
  static const indexTranslate = AsrModel(
    id: 'index-translate-2b-q4_k_m',
    label: 'Index-Translate 2B',
    languages: [],
    files: [
      AsrModelFile(
        name: 'Index-Translate-2B.Q4_K_M.gguf',
        size: 1312164896,
        sha256:
            '9314fffbfc0f43bf08ad383e6772994bae139276d41d48e835af6690645f2d4d',
        sources: [
          AsrSource(
            url:
                'https://github.com/zxa24/PiliPlus/releases/download/'
                'asr-models/Index-Translate-2B.Q4_K_M.gguf',
          ),
          AsrSource(
            url:
                'https://huggingface.co/mradermacher/Index-Translate-2B-GGUF/'
                'resolve/3bf9ed110c93beb0363fd12c3c935f191df6d9b8/'
                'Index-Translate-2B.Q4_K_M.gguf',
          ),
        ],
      ),
    ],
  );

  /// Hy-MT2-1.8B's id, which a setting may still hold: it reads as
  /// [indexTranslate], the model that took its place.
  static const _replacedHy = 'hy-mt2-1.8b-q4_k_m';

  /// Models no longer offered, whose downloaded files are deleted at start
  /// (user 2026-09-30): the models page no longer lists them, so nothing
  /// else could free the space.
  static const retiredIds = [_replacedHy];

  static const all = <AsrModel>[gemma, indexTranslate];

  /// With nothing chosen: Index-Translate on a phone, where it is faster
  /// and 1.7 GB lighter; Gemma on a desktop, which has the room and where
  /// Gemma may be a little better on clean English.
  static AsrModel get platformDefault =>
      PlatformUtils.isMobile ? indexTranslate : gemma;

  /// The model for a stored id; [platformDefault] for anything unknown.
  static AsrModel byId(String? id) => id == _replacedHy
      ? indexTranslate
      : all.where((model) => model.id == id).firstOrNull ?? platformDefault;
}

/// The catalog as a settings choice.
enum TranslationModelChoice implements EnumWithLabel {
  gemma(TranslationModelCatalog.gemma, 'Gemma 4 E2B', '2.8 GB'),
  indexTranslate(
    TranslationModelCatalog.indexTranslate,
    'Index-Translate 2B',
    '1.3 GB',
  );

  const TranslationModelChoice(this.model, this._name, this._size);
  final AsrModel model;
  final String _name;
  final String _size;

  /// Which is recommended depends on the device (see
  /// TranslationModelCatalog.platformDefault).
  @override
  String get label => identical(model, TranslationModelCatalog.platformDefault)
      ? '$_name（推荐，$_size）'
      : '$_name（$_size）';

  static TranslationModelChoice of(AsrModel model) =>
      values.firstWhere((choice) => choice.model.id == model.id);
}
