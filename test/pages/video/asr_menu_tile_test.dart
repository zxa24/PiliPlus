import 'package:PiliPlus/pages/video/widgets/asr_entry.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// On a phone this entry rendered as a grey error box and took the rest of
/// the subtitle menu with it: an `Obx` whose builder reads nothing observable
/// throws in GetX, and with no transcription running there was nothing to
/// read. Pumping it with an empty session is the whole point of these tests.
Future<void> _pump(WidgetTester tester, Rxn<AsrSession> session) =>
    tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: AsrMenuTile(
            session: session,
            onStart: () {},
            onStop: () {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('builds with no session at all', (tester) async {
    await _pump(tester, Rxn<AsrSession>());
    expect(tester.takeException(), isNull);
    expect(find.text('自动转录字幕'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('offers to stop, with progress, while one is running',
      (tester) async {
    final session = Rxn<AsrSession>();
    await _pump(tester, session);

    final running = AsrSession.debugFor('1')
      ..debugSet(
        const AsrState(stage: AsrStage.transcribing, progress: 0.5),
      );
    session.value = running;
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('停止转录'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('says what a finished run produced', (tester) async {
    // a finished run looked identical to one that never started, which cost
    // three rounds of device debugging and tells the user nothing either
    final finished = AsrSession.debugFor('1')
      ..debugSet(const AsrState(stage: AsrStage.done, progress: 1));
    finished.cues.addAll(const [
      AsrCue(from: 0, to: 1, content: 'a'),
      AsrCue(from: 1, to: 2, content: 'b'),
    ]);
    await _pump(tester, Rxn<AsrSession>()..value = finished);

    expect(tester.takeException(), isNull);
    expect(find.text('自动转录字幕'), findsOneWidget);
    expect(find.text('已生成 2 条字幕，点击可重新转录'), findsOneWidget);
  });

  testWidgets('a finished run that heard nothing says so', (tester) async {
    final finished = AsrSession.debugFor('1')
      ..debugSet(const AsrState(stage: AsrStage.done, progress: 1));
    await _pump(tester, Rxn<AsrSession>()..value = finished);

    expect(find.text('没有识别到语音'), findsOneWidget);
  });

  testWidgets('taps reach the right callback', (tester) async {
    var started = 0;
    var stopped = 0;
    final session = Rxn<AsrSession>();
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: AsrMenuTile(
            session: session,
            onStart: () => started++,
            onStop: () => stopped++,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ListTile));
    expect(started, 1);
    expect(stopped, 0);

    session.value = AsrSession.debugFor('1')
      ..debugSet(const AsrState(stage: AsrStage.extracting));
    await tester.pump();
    await tester.tap(find.byType(ListTile));
    expect(stopped, 1);
    expect(started, 1);
  });

  testWidgets('a failure stays on screen with its reason', (tester) async {
    final session = Rxn<AsrSession>()
      ..value = (AsrSession.debugFor('1')
        ..debugSet(
          const AsrState(stage: AsrStage.failed, message: '没有解出音频'),
        ));
    await _pump(tester, session);

    expect(tester.takeException(), isNull);
    expect(find.text('转录失败，点击重试'), findsOneWidget);
    expect(find.text('没有解出音频'), findsOneWidget);
  });
}
