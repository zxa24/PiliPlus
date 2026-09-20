import 'package:PiliPlus/pages/video/widgets/asr_entry.dart';
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

  testWidgets('goes back to offering a run once it is done', (tester) async {
    final session = Rxn<AsrSession>()
      ..value = (AsrSession.debugFor('1')
        ..debugSet(const AsrState(stage: AsrStage.done, progress: 1)));
    await _pump(tester, session);

    expect(tester.takeException(), isNull);
    expect(find.text('自动转录字幕'), findsOneWidget);
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
