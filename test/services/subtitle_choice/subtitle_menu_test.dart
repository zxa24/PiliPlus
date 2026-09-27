import 'package:PiliPlus/models/common/subtitle_source_preference.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_choice.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_menu.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:flutter_test/flutter_test.dart';

const _author = PlatformTrackKind.author;
const _generated = PlatformTrackKind.generated;
const _translated = PlatformTrackKind.translated;

void main() {
  group('the rows', () {
    List<SubtitleMenuRow> rows({
      String? picked = 'zh',
      SubtitleSourcePreference? active,
      List<PlatformTrack> tracks = const [],
      bool canTranscribe = true,
      bool canTranslate = true,
      List<String> languages = const ['zh', 'en'],
      List<String> spoken = const [],
      SubtitleStatus? Function(String code)? status,
    }) => subtitleMenuRows(
      picked: picked,
      active: active,
      tracks: tracks,
      canTranscribe: canTranscribe,
      canTranslate: canTranslate,
      languages: languages,
      spoken: spoken,
      status: status ?? (_) => null,
    );

    String icons(SubtitleMenuRow r) =>
        '${r.device ? 'D' : '-'}${r.platform ? 'P' : '-'}';

    test('a video with nothing of its own: the device icon alone', () {
      final all = rows();
      expect([for (final r in all) r.label], ['原文', '中文', '英语']);
      expect([for (final r in all) icons(r)], ['D-', 'D-', 'D-']);
      expect([for (final r in all) r.checked], [false, true, false]);
    });

    test('the platform icon only where the video has that language', () {
      final all = rows(
        tracks: const [
          (language: 'ai-zh', kind: _generated),
          (language: 'ai-en', kind: _translated),
        ],
      );
      // its transcript is the speech as it is; its machine translation is
      // English, but never 原文
      expect([for (final r in all) icons(r)], ['DP', 'DP', 'DP']);
      final english = rows(
        tracks: const [(language: 'ai-en', kind: _translated)],
      );
      expect([for (final r in english) icons(r)], ['D-', 'D-', 'DP']);
    });

    test('a row nothing can supply is left out', () {
      // no audio, no translation on this device, one English track
      final all = rows(
        canTranscribe: false,
        canTranslate: false,
        tracks: const [(language: 'en', kind: _author)],
      );
      // the lone author's track stands for the speech, and is English
      expect([for (final r in all) (r.code, icons(r))], [
        ('asr', '-P'),
        ('en', '-P'),
      ]);
      // translation from the video's own track needs no audio
      final translated = rows(
        canTranscribe: false,
        tracks: const [(language: 'en', kind: _author)],
      );
      expect([for (final r in translated) (r.code, icons(r))], [
        ('asr', '-P'),
        ('zh', 'D-'),
        // English is there already: nothing for the device to make it from
        ('en', '-P'),
      ]);
    });

    test('the source on screen, for the row picked only', () {
      final all = rows(
        picked: 'en',
        active: SubtitleSourcePreference.platform,
        tracks: const [(language: 'en', kind: _author)],
      );
      expect([for (final r in all) r.active], [
        null,
        null,
        SubtitleSourcePreference.platform,
      ]);
      expect(rows(picked: null).every((r) => !r.checked), isTrue);
    });

    test('named by the speech: 原文 · 日语, 原文 · 日语/中文, 原文', () {
      expect(rows(spoken: const ['ja']).first.label, '原文 · 日语');
      expect(rows(spoken: const ['ja', 'zh']).first.label, '原文 · 日语/中文');
      expect(rows().first.label, '原文');
    });

    test('statuses are asked row by row', () {
      final all = rows(
        status: (code) =>
            code == 'zh' ? const SubtitleStatus('生成中', busy: true) : null,
      );
      expect([for (final r in all) r.status?.text], [null, '生成中', null]);
      expect(all[1].toJson()['busy'], isTrue);
    });
  });

  group('the languages spoken', () {
    test('those with a fifth of the speech, two at most, most first', () {
      expect(
        spokenLanguages(const [
          (language: 'ja', duration: 60),
          (language: 'zh', duration: 30),
          (language: 'en', duration: 5),
        ]),
        ['ja', 'zh'],
      );
      // a stray mistagged line is not a second language
      expect(
        spokenLanguages(const [
          (language: 'zh', duration: 170),
          (language: 'en', duration: 1.2),
        ]),
        ['zh'],
      );
      // Cantonese is Chinese to the viewer; untagged speech does not count
      expect(
        spokenLanguages(const [
          (language: 'yue', duration: 20),
          (language: 'zh', duration: 20),
          (language: '', duration: 100),
        ]),
        ['zh'],
      );
      expect(spokenLanguages(const []), isEmpty);
    });

    test('before any speech is heard: the platform transcript\'s', () {
      expect(
        spokenOf(null, const [
          (language: 'zh-CN', kind: _author),
          (language: 'ai-ja', kind: _generated),
        ]),
        ['ja'],
      );
      expect(spokenOf(null, const [(language: 'en', kind: _author)]), isEmpty);
    });
  });

  group('statuses', () {
    SubtitleStatus? transcript(
      AsrState? state, {
      List<({double from, double to})> covered = const [],
      bool modelsMissing = false,
    }) => transcriptStatus(
      state: state,
      covered: covered,
      duration: 1800,
      playhead: 60,
      modelsMissing: modelsMissing,
    );

    test('the transcript, stage by stage', () {
      expect(transcript(null), isNull);
      expect(
        transcript(null, modelsMissing: true),
        const SubtitleStatus('需要下载模型'),
      );
      expect(
        transcript(
          const AsrState(stage: AsrStage.models, message: '下载模型 42%'),
        ),
        const SubtitleStatus('下载模型 42%', busy: true),
      );
      expect(
        transcript(
          const AsrState(stage: AsrStage.transcribing),
          covered: const [(from: 0, to: 100)],
        ),
        const SubtitleStatus('生成中', busy: true),
      );
      // paused ahead: ready, not 已暂停
      expect(
        transcript(
          const AsrState(stage: AsrStage.standby),
          covered: const [(from: 0, to: 750)],
        ),
        const SubtitleStatus('字幕已就绪至 12:30'),
      );
      expect(
        transcript(
          const AsrState(stage: AsrStage.standby, message: asrWoundDownMessage),
          covered: const [(from: 0, to: 414)],
        ),
        const SubtitleStatus('已关闭（已生成到 6:54）'),
      );
      expect(
        transcript(const AsrState(stage: AsrStage.done)),
        const SubtitleStatus('已全部生成'),
      );
      expect(
        transcript(const AsrState(stage: AsrStage.failed, message: 'x')),
        const SubtitleStatus('失败，点击重试', error: true),
      );
      expect(transcript(const AsrState.idle()), isNull);
    });

    test('a translation, and the transcript it rests on', () {
      const ready = SubtitleStatus('字幕已就绪至 12:30');
      expect(
        translationStatus(
          state: const TranslationState(
            TranslationStage.loading,
            message: '下载模型 7%',
          ),
        ),
        const SubtitleStatus('下载模型 7%', busy: true),
      );
      expect(
        translationStatus(
          state: const TranslationState(TranslationStage.translating),
        ),
        const SubtitleStatus('生成中', busy: true),
      );
      // resting while the transcript is far enough ahead: as ready as it
      expect(
        translationStatus(
          state: const TranslationState(TranslationStage.waiting),
          transcript: ready,
        ),
        ready,
      );
      // waiting on a transcript still being made
      expect(
        translationStatus(
          state: const TranslationState(TranslationStage.waiting),
          transcript: const SubtitleStatus('生成中', busy: true),
        ),
        const SubtitleStatus('生成中', busy: true),
      );
      expect(
        translationStatus(
          state: const TranslationState(TranslationStage.failed),
        ),
        const SubtitleStatus('失败，点击重试', error: true),
      );
      expect(
        translationStatus(state: const TranslationState(TranslationStage.idle)),
        isNull,
      );
    });
  });

  test('the languages listed by name', () {
    final app = AsrService.appLanguage;
    expect(listedLanguages(null, const ['en']), [app, 'en']);
    expect(listedLanguages('ja', const ['en']), [app, 'en', 'ja']);
    // the speech as it is, and a track picked by hand, are not languages
    expect(listedLanguages('asr', const []), [app]);
    expect(listedLanguages(pickedTrack, const []), [app]);
    expect(listedLanguages(app, const []), [app]);
  });
}
