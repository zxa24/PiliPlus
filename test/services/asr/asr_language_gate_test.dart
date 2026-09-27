import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// "The same language" at the level a viewer cares about. It no longer
/// stops a transcription (design 2026-09-26, 3); it is what the probes use
/// to compare the speech with the app's language.
void main() {
  group('same language', () {
    const same = [
      ('zh', 'zh'),
      ('en', 'en'),
      // SenseVoice reports yue for accented Mandarin often enough that
      // treating it as foreign would transcribe Chinese videos for Chinese
      // speakers
      ('yue', 'zh'),
      ('zh', 'yue'),
      ('cmn', 'zh'),
      ('ZH', 'zh'),
      (' zh ', 'zh'),
    ];
    for (final (spoken, app) in same) {
      test('$spoken vs $app', () {
        expect(AsrService.isSameMajorLanguage(spoken, app), isTrue);
      });
    }
  });

  group('different language — transcribe', () {
    const different = [
      ('en', 'zh'),
      ('ja', 'zh'),
      ('ko', 'zh'),
      ('zh', 'en'),
      ('yue', 'en'),
    ];
    for (final (spoken, app) in different) {
      test('$spoken vs $app', () {
        expect(AsrService.isSameMajorLanguage(spoken, app), isFalse);
      });
    }
  });

  test('an unknown language is not treated as the app language', () {
    // SenseVoice returning nothing must not silently cancel the run
    expect(AsrService.isSameMajorLanguage('', 'zh'), isFalse);
    expect(AsrService.isSameMajorLanguage('zh', ''), isFalse);
  });
}
