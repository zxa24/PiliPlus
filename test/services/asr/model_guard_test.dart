import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_guard.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldStopOnDeviceWork', () {
    ModelStopReason? decide({
      bool pressure = false,
      AppLifecycleState? state,
      bool playing = false,
      bool mobile = true,
    }) => shouldStopOnDeviceWork(
      memoryPressure: pressure,
      lifecycle: state,
      playing: playing,
      mobile: mobile,
    );

    test('memory pressure stops it anywhere, playing or not', () {
      expect(decide(pressure: true), ModelStopReason.memoryPressure);
      expect(decide(pressure: true, playing: true), ModelStopReason.memoryPressure);
      expect(decide(pressure: true, mobile: false), ModelStopReason.memoryPressure);
    });

    test('paused in the background with nothing playing stops it', () {
      // the cached-process case: no foreground service left, first to be killed
      expect(decide(state: AppLifecycleState.paused), ModelStopReason.background);
    });

    test('background playback keeps it running', () {
      // audio_service holds a mediaPlayback foreground service while playing
      expect(decide(state: AppLifecycleState.paused, playing: true), isNull);
    });

    test('picture-in-picture and other transient states keep it running', () {
      // PiP is inactive, not paused: the video is still on screen
      expect(decide(state: AppLifecycleState.inactive), isNull);
      expect(decide(state: AppLifecycleState.hidden), isNull);
      expect(decide(state: AppLifecycleState.resumed), isNull);
    });

    test('desktop never stops for being in the background', () {
      expect(decide(state: AppLifecycleState.paused, mobile: false), isNull);
    });
  });

  group('AsrService.stop with a reason', () {
    test('marks the running session failed before closing it', () async {
      // a closed session no longer reports state; without this the page never
      // learns its job ended and its loading gate waits out the full cap
      final service = AsrService();
      final session = AsrSession.debugFor('t')
        ..debugSet(const AsrState(stage: AsrStage.transcribing));
      service.debugAdopt(session);
      expect(service.isBusy, isTrue);

      await service.stop(reason: ModelStopReason.memoryPressure.message);

      expect(session.state.value.stage, AsrStage.failed);
      expect(session.state.value.message, ModelStopReason.memoryPressure.message);
      expect(service.isBusy, isFalse);
    });

    test('without a reason it only closes, as before', () async {
      final service = AsrService();
      final session = AsrSession.debugFor('t')
        ..debugSet(const AsrState(stage: AsrStage.transcribing));
      service.debugAdopt(session);
      await service.stop();
      expect(session.state.value.stage, AsrStage.transcribing);
    });
  });
}
