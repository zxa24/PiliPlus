import 'package:PiliPlus/services/asr/asr_schedule.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/asr_status.dart';
import 'package:PiliPlus/utils/subtitle_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatMediaTime', () {
    test('minutes and seconds, hours from an hour', () {
      expect(formatMediaTime(0), '0:00');
      expect(formatMediaTime(59.9), '0:59');
      expect(formatMediaTime(750), '12:30');
      expect(formatMediaTime(3600 + 65), '1:01:05');
      expect(formatMediaTime(double.infinity), '0:00');
    });
  });

  group('asrCoverageLabel', () {
    String? label(
      AsrStage stage,
      List<({double from, double to})> covered, {
      double? duration = 1800,
      double playhead = 60,
      String? message,
    }) => asrCoverageLabel(
      stage: stage,
      message: message,
      covered: covered,
      duration: duration,
      playhead: playhead,
    );

    test('one stretch: how far it reaches', () {
      expect(
        label(AsrStage.transcribing, [(from: 0, to: 750)]),
        '已生成到 12:30',
      );
    });

    test('gaps: how many stretches and how much in all', () {
      expect(
        label(AsrStage.transcribing, [
          (from: 0, to: 300),
          (from: 600, to: 1000),
          (from: 1200, to: 1810),
        ]),
        // 300 + 400 + 610 s
        '已生成 3 段，共 21:50',
      );
    });

    test('a stretch just begun does not count as one', () {
      expect(
        label(AsrStage.transcribing, [
          (from: 0, to: 300),
          (from: 900, to: 900.4),
        ]),
        '已生成到 5:00',
      );
      expect(label(AsrStage.extracting, const []), '生成中');
    });

    test('standby: paused, and how far ahead of the viewer', () {
      expect(
        label(AsrStage.standby, [(from: 0, to: 300)], playhead: 60),
        '已暂停（已领先 4:00）',
      );
      // the viewer where nothing is known: nothing ahead to speak of
      expect(
        label(AsrStage.standby, [(from: 0, to: 300)], playhead: 400),
        '已暂停',
      );
      // stopped for a reason, which is what the viewer needs to know
      expect(
        label(
          AsrStage.standby,
          [(from: 0, to: 300)],
          message: '应用已切到后台，已停止转录',
        ),
        '应用已切到后台，已停止转录',
      );
    });

    test('all of it: 已全部生成', () {
      expect(label(AsrStage.done, [(from: 0, to: 1799.5)]), '已全部生成');
      // covered before the session has said so
      expect(
        label(AsrStage.transcribing, [(from: 0, to: 1799.5)]),
        '已全部生成',
      );
      expect(
        label(AsrStage.standby, [(from: 0, to: 1800)]),
        '已全部生成',
      );
    });

    test('stages that are not about coverage say nothing here', () {
      expect(label(AsrStage.models, const []), isNull);
      expect(label(AsrStage.failed, [(from: 0, to: 300)]), isNull);
      expect(label(AsrStage.idle, const []), isNull);
    });
  });

  test('a kept VTT reads back as the cues it was written from', () {
    final list = [
      {'from': 1.5, 'to': 3.25, 'content': '第一行'},
      {'from': 3661.0, 'to': 3662.5, 'content': 'two\nlines'},
    ];
    expect(SubtitleUtils.vtt2Json(SubtitleUtils.json2Vtt(list)), list);
  });

  group('full coverage on the session', () {
    test('a save waiting lifts the lead rule until it is done', () {
      final session = AsrSession.debugFor('t')
        ..power = AsrPower.battery
        ..debugPowerFixed = true;
      expect(session.leadWindow.pauses, isTrue);
      session.requestFullCoverage();
      expect(session.fullCoverageRequested, isTrue);
      expect(session.leadWindow.pauses, isFalse);
      // two saves, two releases
      session
        ..requestFullCoverage()
        ..endFullCoverage();
      expect(session.leadWindow.pauses, isFalse);
      session.endFullCoverage();
      expect(session.leadWindow.pauses, isTrue);
      // one too many does not go negative
      session
        ..endFullCoverage()
        ..requestFullCoverage();
      expect(session.leadWindow.pauses, isFalse);
    });

    test('a paused run resumes under a lead that never pauses', () {
      final pace = AsrPace(speed: 20, restartCost: 2);
      AsrStep step(AsrPower power) => decideAsrStep(
        playhead: 60,
        duration: 1800,
        covered: const [(from: 0, to: 700)],
        run: (start: 0, frontier: 700, paused: true),
        lead: asrLeadWindow(speed: 20, restartCost: 2, power: power),
        pace: pace,
      );
      // on battery 640 s ahead is plenty: it stays paused
      expect(step(AsrPower.battery), isA<AsrKeep>());
      // filling for a save (or on a charger): it goes on
      expect(step(AsrPower.unlimited), isA<AsrResume>());
    });
  });
}
