/// A source that cannot seek (an Android document read through
/// `fdclose://`, the durl/FLV fallback) is one run from 0: what the session
/// does while that run is not going.
library;

import 'package:PiliPlus/services/asr/asr_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('unseekable source with no run', () {
    test('its run ended by a suspend: it starts again from 0 on resume', () {
      // the model guard's suspend ends the run short of the end; resume
      // must start another, as a seekable source starts one where its
      // text ends (TODO 31: it sat in standby for good, the old check
      // starting a run only while none had ever run). The first start
      // is the same case: nothing has read the source through yet
      final step = decideUnseekableIdle(
        coveredWhole: false,
        readThrough: false,
        backingOff: false,
      );
      expect(step, isA<AsrStartAt>());
      expect((step as AsrStartAt).at, 0);
    });

    test('a run failed a moment ago: it waits out the backoff', () {
      final step = decideUnseekableIdle(
        coveredWhole: false,
        readThrough: false,
        backingOff: true,
      );
      expect(step, isA<AsrKeep>());
    });

    test('a run read the source to its end: done', () {
      for (final backingOff in [false, true]) {
        final step = decideUnseekableIdle(
          coveredWhole: false,
          readThrough: true,
          backingOff: backingOff,
        );
        expect(step, isA<AsrComplete>());
      }
    });

    test('covered whole, by the cache or a run: done', () {
      final step = decideUnseekableIdle(
        coveredWhole: true,
        readThrough: false,
        backingOff: false,
      );
      expect(step, isA<AsrComplete>());
    });
  });
}
