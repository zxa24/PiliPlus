/// The translation models on offer (user 2026-09-30: Index-Translate-2B in
/// place of Hy-MT2, and the phones' default).
library;

import 'package:PiliPlus/services/translate/translation_models.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Hy-MT2, still in a setting, reads as the model that replaced it', () {
    expect(
      TranslationModelCatalog.byId('hy-mt2-1.8b-q4_k_m'),
      TranslationModelCatalog.indexTranslate,
    );
  });

  test('nothing chosen: the platform default', () {
    final expected = PlatformUtils.isMobile
        ? TranslationModelCatalog.indexTranslate
        : TranslationModelCatalog.gemma;
    expect(TranslationModelCatalog.platformDefault, expected);
    expect(TranslationModelCatalog.byId(null), expected);
    expect(TranslationModelCatalog.byId('unknown'), expected);
  });

  test('a stored choice is kept', () {
    for (final model in TranslationModelCatalog.all) {
      expect(TranslationModelCatalog.byId(model.id), model);
    }
  });

  test('only the default is marked 推荐', () {
    final marked = [
      for (final c in TranslationModelChoice.values)
        if (c.label.contains('推荐')) c.model,
    ];
    expect(marked, [TranslationModelCatalog.platformDefault]);
  });

  test('Index-Translate: the measured file, mirrored', () {
    final file = TranslationModelCatalog.indexTranslate.files.single;
    expect(file.size, 1312164896);
    expect(
      file.sha256,
      '9314fffbfc0f43bf08ad383e6772994bae139276d41d48e835af6690645f2d4d',
    );
    expect(file.sources.first.url, contains('github.com/zxa24/PiliPlus'));
    expect(
      file.sources.last.url,
      contains('3bf9ed110c93beb0363fd12c3c935f191df6d9b8'),
    );
  });
}
