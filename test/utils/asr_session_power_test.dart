/// The self-test's `--asr-session` power: `--asr-power` as given, or with no
/// playhead to move, unlimited.
library;

import 'package:PiliPlus/services/asr/asr_schedule.dart';
import 'package:PiliPlus/utils/self_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no playhead and no --asr-power: unlimited', () {
    // the playhead stays at 0: under the battery rule a lead cap shorter
    // than the clip left the session in standby until the 30 min deadline
    // (TODO 30)
    expect(
      SelfTest.asrSessionPower(null, playhead: false),
      AsrPower.unlimited,
    );
  });

  test('a playhead and no --asr-power: the device decides', () {
    expect(SelfTest.asrSessionPower(null, playhead: true), isNull);
  });

  test('--asr-power wins either way', () {
    for (final playhead in [false, true]) {
      expect(
        SelfTest.asrSessionPower('battery', playhead: playhead),
        AsrPower.battery,
      );
      expect(
        SelfTest.asrSessionPower('saver', playhead: playhead),
        AsrPower.saver,
      );
    }
  });

  test('an unknown --asr-power name is as none given', () {
    expect(
      SelfTest.asrSessionPower('turbo', playhead: false),
      AsrPower.unlimited,
    );
    expect(SelfTest.asrSessionPower('turbo', playhead: true), isNull);
  });
}
