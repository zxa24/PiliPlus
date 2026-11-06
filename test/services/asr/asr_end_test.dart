/// Whether a read mpv ended as the end of the file reached the media's end.
library;

import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('402 s of 2050 s: cut short, not the end (the user’s copy, '
      '2026-11-06, a reconnect answered 403)', () {
    expect(AsrSession.endedShort(402.3, 2050), isTrue);
  });

  test('a few seconds short of the video: its audio’s end', () {
    expect(AsrSession.endedShort(2045, 2050), isFalse);
    expect(AsrSession.endedShort(2050.4, 2050), isFalse);
  });

  test('no length from the player: as mpv says', () {
    expect(AsrSession.endedShort(402.3, null), isFalse);
    expect(AsrSession.endedShort(402.3, 0), isFalse);
  });
}
