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

    test('running: 生成中, however much there is (kept short, 9)', () {
      expect(label(AsrStage.transcribing, [(from: 0, to: 750)]), '生成中');
      expect(
        label(AsrStage.transcribing, [
          (from: 0, to: 300),
          (from: 600, to: 1000),
        ]),
        '生成中',
      );
      expect(label(AsrStage.extracting, const []), '生成中');
    });

    test('standby ahead: how far the subtitles are ready, not 已暂停', () {
      expect(
        label(AsrStage.standby, [(from: 0, to: 750)], playhead: 60),
        '字幕已就绪至 12:30',
      );
      // the stretch the viewer is in, not the furthest one
      expect(
        label(
          AsrStage.standby,
          [(from: 0, to: 300), (from: 600, to: 900)],
          playhead: 620,
        ),
        '字幕已就绪至 15:00',
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

    test('switched off and wound down: 已关闭, and what it made', () {
      expect(
        label(
          AsrStage.standby,
          [(from: 0, to: 414)],
          message: asrWoundDownMessage,
        ),
        '已关闭（已生成到 6:54）',
      );
      expect(
        label(
          AsrStage.standby,
          [(from: 0, to: 300), (from: 600, to: 900)],
          message: asrWoundDownMessage,
        ),
        '已关闭（已生成 2 段，共 10:00）',
      );
      expect(
        label(AsrStage.standby, const [], message: asrWoundDownMessage),
        '已关闭',
      );
      // whole before it was switched off: that is what matters
      expect(
        label(
          AsrStage.standby,
          [(from: 0, to: 1800)],
          message: asrWoundDownMessage,
        ),
        '已全部生成',
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

  group('the switch on the session (design 2026-09-26, 3 and 4)', () {
    test('only a failure has ended it', () {
      final session = AsrSession.debugFor('t');
      expect(session.hasEnded, isFalse);
      for (final stage in [
        AsrStage.transcribing,
        AsrStage.standby,
        AsrStage.done,
      ]) {
        session.debugSet(AsrState(stage: stage));
        expect(session.hasEnded, isFalse, reason: stage.name);
      }
      session.debugSet(
        const AsrState(stage: AsrStage.standby, message: asrWoundDownMessage),
      );
      expect(session.hasEnded, isFalse);
      session.debugSet(const AsrState(stage: AsrStage.failed));
      expect(session.hasEnded, isTrue);
    });

    test('off: a mark the wind-down window past the playhead; on lifts it', () {
      final session = AsrSession.debugFor('t')
        ..power = AsrPower.battery
        ..debugPowerFixed = true
        ..debugSet(const AsrState(stage: AsrStage.transcribing));
      expect(session.isSwitchedOff, isFalse);
      session.windDown();
      expect(session.isSwitchedOff, isTrue);
      // no playhead: 0, plus the window at the guessed pace (s 10, c 2)
      expect(
        session.windDownUntil,
        asrWindDownWindow(
          speed: session.pace.speed,
          restartCost: session.pace.restartCost,
          power: AsrPower.battery,
        ),
      );
      // a second switch-off keeps the first mark
      final mark = session.windDownUntil;
      session
        ..power = AsrPower.unlimited
        ..windDown();
      expect(session.windDownUntil, mark);
      session.resumeOn();
      expect(session.isSwitchedOff, isFalse);
      expect(session.isWoundDown, isFalse);
      expect(session.windDownUntil, isNull);
    });

    test('a finished or failed session has nothing to wind down', () {
      for (final stage in [AsrStage.done, AsrStage.failed]) {
        final session = AsrSession.debugFor('t')
          ..debugSet(AsrState(stage: stage))
          ..windDown();
        expect(session.isSwitchedOff, isFalse, reason: stage.name);
      }
    });
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
