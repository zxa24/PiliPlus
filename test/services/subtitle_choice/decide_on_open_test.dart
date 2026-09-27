import 'package:PiliPlus/models/common/subtitle_source_preference.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_choice.dart';
import 'package:flutter_test/flutter_test.dart';

const _author = PlatformTrackKind.author;
const _generated = PlatformTrackKind.generated;
const _translated = PlatformTrackKind.translated;

/// The platform tracks a video can come with, as named in the matrix.
const Map<String, List<PlatformTrack>> _videos = {
  'none': [],
  'zh author': [(language: 'zh-CN', kind: _author)],
  // bilibili's own transcript
  'ai-zh': [(language: 'ai-zh', kind: _generated)],
  'en only': [(language: 'en', kind: _author)],
  // bilibili's machine translation, and nothing else
  'en machine-translated': [(language: 'ai-en', kind: _translated)],
  'en+zh': [
    (language: 'en', kind: _author),
    (language: 'zh-CN', kind: _author),
  ],
};

String _describe(OpenPlan plan) => switch (plan.action) {
  OpenAction.none => 'none',
  OpenAction.platform => 'platform ${plan.track}',
  OpenAction.onDevice => 'device ${plan.code}',
};

void main() {
  group('what a video opens with', () {
    // choice -> video -> [platform first, device first]
    const expected = <String, Map<String, List<String>>>{
      SubtitleChoice.off: {
        'none': ['none', 'none'],
        'zh author': ['none', 'none'],
        'ai-zh': ['none', 'none'],
        'en only': ['none', 'none'],
        'en machine-translated': ['none', 'none'],
        'en+zh': ['none', 'none'],
      },
      SubtitleChoice.original: {
        'none': ['device asr', 'device asr'],
        // the one track there is, and no transcript to say otherwise
        'zh author': ['platform 0', 'device asr'],
        'ai-zh': ['platform 0', 'device asr'],
        'en only': ['platform 0', 'device asr'],
        // a machine translation is never the speech as it is
        'en machine-translated': ['device asr', 'device asr'],
        // two authors' tracks: which is the original cannot be told
        'en+zh': ['device asr', 'device asr'],
      },
      'zh': {
        'none': ['device zh', 'device zh'],
        'zh author': ['platform 0', 'device zh'],
        'ai-zh': ['platform 0', 'device zh'],
        // the English track is translated on the device
        'en only': ['device zh', 'device zh'],
        'en machine-translated': ['device zh', 'device zh'],
        'en+zh': ['platform 1', 'device zh'],
      },
      'zh-Hant': {
        // Simplified Chinese is not what was asked for: converted instead
        'none': ['device zh-Hant', 'device zh-Hant'],
        'zh author': ['device zh-Hant', 'device zh-Hant'],
        'ai-zh': ['device zh-Hant', 'device zh-Hant'],
        'en only': ['device zh-Hant', 'device zh-Hant'],
        'en machine-translated': ['device zh-Hant', 'device zh-Hant'],
        'en+zh': ['device zh-Hant', 'device zh-Hant'],
      },
      'en': {
        'none': ['device en', 'device en'],
        'zh author': ['device en', 'device en'],
        'ai-zh': ['device en', 'device en'],
        'en only': ['platform 0', 'device en'],
        // a machine translation counts as the platform's subtitle
        'en machine-translated': ['platform 0', 'device en'],
        'en+zh': ['platform 0', 'device en'],
      },
    };

    for (final MapEntry(key: choice, value: videos) in expected.entries) {
      for (final MapEntry(key: video, value: plans) in videos.entries) {
        for (final (i, source) in SubtitleSourcePreference.values.indexed) {
          test('$choice, $video, ${source.label}', () {
            final plan = decideOnOpen(
              choice: choice,
              tracks: _videos[video]!,
              source: source,
              canTranscribe: true,
              asrReady: true,
              translateReady: true,
            );
            expect(_describe(plan), plans[i]);
          });
        }
      }
    }

    test('the whole matrix is there', () {
      expect(expected.length, 5);
      for (final videos in expected.values) {
        expect(videos.keys, unorderedEquals(_videos.keys));
      }
    });
  });

  group('when the device cannot make it', () {
    OpenPlan plan(
      String choice,
      List<PlatformTrack> tracks, {
      SubtitleSourcePreference source = SubtitleSourcePreference.device,
      bool canTranscribe = true,
      bool asrReady = true,
      bool translateReady = true,
    }) => decideOnOpen(
      choice: choice,
      tracks: tracks,
      source: source,
      canTranscribe: canTranscribe,
      asrReady: asrReady,
      translateReady: translateReady,
    );

    test('本机优先 without the model falls back to the platform', () {
      expect(
        _describe(plan('zh', _videos['zh author']!, translateReady: false)),
        'platform 0',
      );
      expect(
        _describe(plan(SubtitleChoice.original, _videos['ai-zh']!,
            asrReady: false)),
        'platform 0',
      );
    });

    test('and with nothing to fall back to, nothing starts', () {
      expect(
        _describe(plan('zh', const [], translateReady: false)),
        'none',
      );
      expect(
        _describe(plan(SubtitleChoice.original, _videos['en+zh']!,
            asrReady: false)),
        'none',
      );
      expect(
        _describe(plan(SubtitleChoice.original, const [],
            canTranscribe: false)),
        'none',
      );
    });

    test('a video\'s own foreign track needs no audio to be translated', () {
      expect(
        _describe(plan('zh', _videos['en only']!, canTranscribe: false,
            asrReady: false)),
        'device zh',
      );
      // but a machine translation is not translated again
      expect(
        _describe(plan('zh', _videos['en machine-translated']!,
            canTranscribe: false)),
        'none',
      );
    });
  });

  group('which platform track', () {
    test('an author before the platform, and that before a translation', () {
      expect(
        platformTrackFor([
          (language: 'ai-en', kind: _translated),
          (language: 'en-US', kind: _generated),
          (language: 'en', kind: _author),
        ], 'en'),
        2,
      );
      expect(
        platformTrackFor([
          (language: 'ai-en', kind: _translated),
          (language: 'en-US', kind: _generated),
        ], 'en'),
        1,
      );
    });

    test('Chinese in the script asked for first', () {
      final both = [
        (language: 'zh-Hant', kind: _author),
        (language: 'zh-CN', kind: _author),
      ];
      expect(platformTrackFor(both, 'zh'), 1);
      expect(platformTrackFor(both, 'zh-Hant'), 0);
      // Traditional only, for someone reading Chinese: better than nothing
      expect(platformTrackFor([both.first], 'zh'), 0);
      expect(platformTrackFor([(language: 'zh-TW', kind: _author)],
          'zh-Hant'), 0);
    });

    test('the speech as it is: the language the transcript is in', () {
      // an author's track in the language spoken, before the transcript
      expect(
        platformTrackFor([
          (language: 'ai-zh', kind: _generated),
          (language: 'zh-CN', kind: _author),
        ], 'asr'),
        1,
      );
      // an author's track in another language is a translation
      expect(
        platformTrackFor([
          (language: 'ai-ja', kind: _generated),
          (language: 'zh-CN', kind: _author),
        ], 'asr'),
        0,
      );
      expect(
        platformTrackFor([
          (language: 'ai-zh', kind: _generated),
          (language: 'ai-en', kind: _translated),
        ], 'asr'),
        0,
      );
      expect(platformTrackFor(const [], 'asr'), isNull);
      expect(platformTrackFor(const [], null), isNull);
    });

    test('languages by their major tag', () {
      expect(trackInLanguage('en-GB', 'en'), isTrue);
      expect(trackInLanguage('ai-en', 'en'), isTrue);
      expect(trackInLanguage('zh-Hans', 'zh'), isTrue);
      expect(trackInLanguage('zh-HK', 'zh-Hant'), isTrue);
      expect(trackInLanguage('zh-CN', 'zh-Hant'), isFalse);
      expect(trackInLanguage('ja', 'en'), isFalse);
    });

    test('what the device would translate', () {
      expect(captionToTranslateFor(_videos['en only']!, 'zh'), 0);
      // the video has Chinese already
      expect(captionToTranslateFor(_videos['en+zh']!, 'zh'), isNull);
      // a machine translation is not translated again
      expect(
        captionToTranslateFor(_videos['en machine-translated']!, 'zh'),
        isNull,
      );
      // Chinese into Traditional Chinese: converted
      expect(captionToTranslateFor(_videos['zh author']!, 'zh-Hant'), 0);
    });
  });
}
