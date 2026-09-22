import 'package:PiliPlus/services/asr/asr_publish.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldPublishAsr', () {
    test('the first cues always go out', () {
      // nothing is on screen yet, so there is no reload to be paid for
      expect(
        shouldPublishAsr(
          publishedTo: Duration.zero,
          position: Duration.zero,
          isFirst: true,
          isFinal: false,
        ),
        isTrue,
      );
    });

    test('a transcript far ahead of the playhead is not republished', () {
      // The blinking-subtitle case. Recognition outruns playback, so the
      // track already covers minutes the viewer has not reached; rebuilding
      // it reloads the track and takes the line off screen for nothing.
      expect(
        shouldPublishAsr(
          publishedTo: const Duration(minutes: 5),
          position: const Duration(seconds: 12),
          isFirst: false,
          isFinal: false,
        ),
        isFalse,
      );
    });

    test('it is republished before the viewer runs out of subtitle', () {
      expect(
        shouldPublishAsr(
          publishedTo: const Duration(seconds: 40),
          position: const Duration(seconds: 20),
          isFirst: false,
          isFinal: false,
        ),
        isTrue,
      );
    });

    test('the end of the run always publishes, however far ahead', () {
      // the only chance to deliver the tail
      expect(
        shouldPublishAsr(
          publishedTo: const Duration(hours: 1),
          position: Duration.zero,
          isFirst: false,
          isFinal: true,
        ),
        isTrue,
      );
    });

    test('exactly at the lead it still publishes', () {
      expect(
        shouldPublishAsr(
          publishedTo: asrPublishLead,
          position: Duration.zero,
          isFirst: false,
          isFinal: false,
        ),
        isFalse,
      );
      expect(
        shouldPublishAsr(
          publishedTo: asrPublishLead - const Duration(milliseconds: 1),
          position: Duration.zero,
          isFirst: false,
          isFinal: false,
        ),
        isTrue,
      );
    });
  });
}
