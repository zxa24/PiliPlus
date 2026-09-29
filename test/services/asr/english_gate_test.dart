/// When a session switches to the English model (AsrEnglishGate), and
/// whether it may at all (asrEnglishChoice).
library;

import 'package:PiliPlus/services/asr/english_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AsrEnglishGate', () {
    test('says English once 20 s of tagged speech is mostly English', () {
      final gate = AsrEnglishGate();
      expect(gate.add('en', 8), isFalse);
      expect(gate.add('en', 8), isFalse);
      expect(gate.english, isFalse);
      // 22 s tagged, all English
      expect(gate.add('en', 6), isTrue);
      expect(gate.english, isTrue);
      // and stays so: nothing after it changes the answer
      expect(gate.add('zh', 100), isFalse);
      expect(gate.english, isTrue);
    });

    test('never on a first English segment alone', () {
      final gate = AsrEnglishGate()..add('en', 12);
      expect(gate.english, isFalse);
    });

    test('untagged segments do not count', () {
      final gate = AsrEnglishGate()
        ..add('', 30)
        ..add('en', 0)
        ..add('en', 10);
      expect(gate.tagged, 10);
      expect(gate.english, isFalse);
    });

    test('a mixed session below the share stays with SenseVoice', () {
      final gate = AsrEnglishGate()
        ..add('en', 14)
        ..add('zh', 8);
      // 14 / 22 = 64 %
      expect(gate.english, isFalse);
    });

    test('an opening in another language is outgrown', () {
      final gate = AsrEnglishGate()..add('zh', 10);
      for (var i = 0; i < 5; i++) {
        gate.add('en', 5);
      }
      // 25 / 35 = 71 %: not yet
      expect(gate.english, isFalse);
      gate.add('en', 5);
      // 30 / 40 = 75 %
      expect(gate.english, isTrue);
    });

    test('Cantonese counts with Mandarin, against English', () {
      final gate = AsrEnglishGate()
        ..add('en', 15)
        ..add('yue', 3)
        ..add('zh', 3);
      // 15 / 21 = 71 %
      expect(gate.english, isFalse);
    });

    test('a Chinese or Japanese session never switches', () {
      for (final language in ['zh', 'ja', 'ko', 'yue']) {
        final gate = AsrEnglishGate();
        for (var i = 0; i < 100; i++) {
          gate.add(language, 5);
          if (i % 10 == 0) gate.add('en', 1);
        }
        expect(gate.english, isFalse, reason: language);
      }
    });
  });

  group('asrEnglishChoice', () {
    test('used where switched on and downloaded, and nothing forced', () {
      expect(
        asrEnglishChoice(enabled: true, installed: true, forced: ''),
        (use: true, first: false),
      );
    });

    test('not when switched off or not downloaded', () {
      expect(
        asrEnglishChoice(enabled: false, installed: true, forced: ''),
        (use: false, first: false),
      );
      expect(
        asrEnglishChoice(enabled: true, installed: false, forced: ''),
        (use: false, first: false),
      );
      expect(
        asrEnglishChoice(enabled: true, installed: false, forced: 'en'),
        (use: false, first: false),
      );
    });

    test('forced to English starts with it; forced to another, never', () {
      expect(
        asrEnglishChoice(enabled: true, installed: true, forced: 'en'),
        (use: true, first: true),
      );
      for (final forced in ['zh', 'ja', 'ko', 'yue']) {
        expect(
          asrEnglishChoice(enabled: true, installed: true, forced: forced),
          (use: false, first: false),
          reason: forced,
        );
      }
    });
  });
}
