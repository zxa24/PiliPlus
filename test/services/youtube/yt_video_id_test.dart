import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tryParseYouTubeVideoId', () {
    test('a bare id passes through', () {
      expect(tryParseYouTubeVideoId('dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
      expect(tryParseYouTubeVideoId('  dQw4w9WgXcQ  '), 'dQw4w9WgXcQ');
      expect(tryParseYouTubeVideoId('_-aBcDeFgHi'), '_-aBcDeFgHi');
    });

    test('the standard watch URL', () {
      expect(
        tryParseYouTubeVideoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
      expect(
        tryParseYouTubeVideoId('http://m.youtube.com/watch?v=dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });

    test('short, shorts, embed, live and /v/ forms', () {
      const cases = {
        'https://youtu.be/dQw4w9WgXcQ': 'dQw4w9WgXcQ',
        'https://www.youtube.com/shorts/dQw4w9WgXcQ': 'dQw4w9WgXcQ',
        'https://www.youtube.com/embed/dQw4w9WgXcQ': 'dQw4w9WgXcQ',
        'https://www.youtube.com/live/dQw4w9WgXcQ': 'dQw4w9WgXcQ',
        'https://www.youtube.com/v/dQw4w9WgXcQ': 'dQw4w9WgXcQ',
      };
      cases.forEach((input, expected) {
        expect(tryParseYouTubeVideoId(input), expected, reason: input);
      });
    });

    // The privacy property: everything except the 11 characters is discarded
    // by EXTRACTION, not by a denylist, so a tracking parameter nobody has
    // heard of yet is dropped by default.
    test('share tokens and tracking parameters are discarded', () {
      const pasted =
          'https://youtu.be/dQw4w9WgXcQ?si=kR8_TRACKING&pp=OPAQUE%3D%3D'
          '&t=42&utm_source=whatsapp&feature=shared';
      expect(tryParseYouTubeVideoId(pasted), 'dQw4w9WgXcQ');
    });

    test('a playlist parameter does not leak either', () {
      expect(
        tryParseYouTubeVideoId(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc&index=3',
        ),
        'dQw4w9WgXcQ',
      );
    });

    test('non-videos return null rather than a guess', () {
      const bad = [
        '',
        'hello',
        'https://www.youtube.com/',
        'https://www.youtube.com/@SomeChannel',
        'https://www.youtube.com/playlist?list=PLabc',
        'https://example.com/watch?v=tooshort',
        'dQw4w9WgXc', // 10 chars
        'dQw4w9WgXcQQ', // 12 chars
        'dQw4w9WgXc!', // illegal character
      ];
      for (final s in bad) {
        expect(tryParseYouTubeVideoId(s), isNull, reason: s);
      }
    });

    test('isYouTubeVideoId agrees', () {
      expect(isYouTubeVideoId('dQw4w9WgXcQ'), isTrue);
      expect(isYouTubeVideoId('dQw4w9WgXc'), isFalse);
      expect(isYouTubeVideoId('https://youtu.be/dQw4w9WgXcQ'), isFalse);
    });
  });

  group('parseYouTubeVideoId', () {
    test('throws on a non-video', () {
      expect(() => parseYouTubeVideoId('nope'), throwsArgumentError);
    });

    // An exception message ends up in logs; a pasted URL may carry a share
    // token, so the input is deliberately not echoed.
    test('the exception does NOT echo the input', () {
      try {
        parseYouTubeVideoId('https://example.com/?si=SECRET_SHARE_TOKEN');
        fail('should have thrown');
      } on ArgumentError catch (e) {
        expect(e.toString(), isNot(contains('SECRET_SHARE_TOKEN')));
      }
    });
  });
}
