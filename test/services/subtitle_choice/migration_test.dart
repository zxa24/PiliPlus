import 'package:PiliPlus/services/asr/model_download_copy.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_choice.dart';
import 'package:flutter_test/flutter_test.dart';

/// Decision 1B (research/subtitle-switch-design-2026-09-26.md): the switch
/// starts as what the old settings did.
void main() {
  group('migrating the old settings', () {
    String migrate(
      Object? asrMode,
      Object? asrAsked,
      Object? translateMode,
      Object? translateAsked,
    ) => migrateSubtitleChoice(
      asrMode: asrMode,
      asrAsked: asrAsked,
      translateMode: translateMode,
      translateAsked: translateAsked,
      appLanguage: 'zh',
    );

    test('the cases as the decision names them', () {
      // never answered either prompt: a new user
      expect(migrate(null, null, null, null), SubtitleChoice.off);
      // 外语视频自动转录 + 外语时自动翻译
      expect(migrate(1, true, 1, true), 'zh');
      // 无字幕时自动转录 + 外语时自动翻译
      expect(migrate(2, true, 1, true), 'zh');
      // automatic transcription alone
      expect(migrate(1, true, 0, true), SubtitleChoice.original);
      expect(migrate(2, true, null, null), SubtitleChoice.original);
      // automatic translation alone: off
      expect(migrate(0, true, 1, true), SubtitleChoice.off);
      expect(migrate(null, null, 1, true), SubtitleChoice.off);
      // both manual
      expect(migrate(0, true, 0, true), SubtitleChoice.off);
    });

    test('the app language is what an automatic translation went into', () {
      expect(
        migrateSubtitleChoice(
          asrMode: 1,
          asrAsked: true,
          translateMode: 1,
          translateAsked: true,
          appLanguage: 'en',
        ),
        'en',
      );
    });

    test('every stored combination', () {
      // what could be in the box: never set, a wrong type, each index, and
      // one past the last
      const asrModes = <Object?>[null, 'foreign', 0, 1, 2, 3];
      const translateModes = <Object?>[null, 'auto', 0, 1, 2];
      const asked = <Object?>[null, false, true, 1];
      var seen = 0;
      for (final a in asrModes) {
        for (final aa in asked) {
          for (final t in translateModes) {
            for (final ta in asked) {
              seen++;
              // automatic transcription counted only once its prompt was
              // answered, and only as foreign (1) or always (2)
              final transcribed = identical(aa, true) && {1, 2}.contains(a);
              final translated = identical(ta, true) && t == 1;
              final expected = transcribed
                  ? (translated ? 'zh' : SubtitleChoice.original)
                  : SubtitleChoice.off;
              expect(
                migrate(a, aa, t, ta),
                expected,
                reason: 'asrMode=$a asked=$aa translateMode=$t asked=$ta',
              );
            }
          }
        }
      }
      expect(seen, 6 * 4 * 5 * 4);
    });
  });

  group('the choice and the pages\' codes', () {
    test('both ways', () {
      expect(SubtitleChoice.codeOf(SubtitleChoice.off), isNull);
      expect(SubtitleChoice.codeOf(''), isNull);
      expect(SubtitleChoice.codeOf(SubtitleChoice.original), 'asr');
      expect(SubtitleChoice.codeOf('zh-Hant'), 'zh-Hant');
      expect(SubtitleChoice.fromCode(null), SubtitleChoice.off);
      expect(SubtitleChoice.fromCode('asr'), SubtitleChoice.original);
      expect(SubtitleChoice.fromCode('en'), 'en');
    });
  });

  group('the model download prompt', () {
    const gemma = 2841481184;

    test('on Wi-Fi: the size, once', () {
      final note = modelDownloadNote(
        what: 'Gemma 4 E2B',
        bytes: gemma,
        mobileData: false,
      );
      expect(note, startsWith('Gemma 4 E2B，共 2.65G，'));
      expect(note, isNot(contains('流量')));
      expect(note, isNot(contains('移动网络')));
    });

    test('on mobile data: says so, and what it costs', () {
      final note = modelDownloadNote(
        what: 'Gemma 4 E2B',
        bytes: gemma,
        mobileData: true,
      );
      expect(note, startsWith('正在使用移动网络'));
      expect(note, contains('约 2.65G 流量'));
      expect(note, contains('Wi-Fi'));
    });

    test('the recogniser, which has no one name', () {
      expect(
        modelDownloadNote(bytes: 239877735, mobileData: false),
        startsWith('共 228.77M，'),
      );
      expect(
        modelDownloadNote(bytes: 239877735, mobileData: true),
        contains('共 228.77M，下载会消耗约 228.77M 流量'),
      );
    });
  });
}
