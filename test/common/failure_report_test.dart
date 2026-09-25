import 'package:PiliPlus/common/widgets/dialog/failure_report.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> app(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [FlutterSmartDialog.observer],
      builder: FlutterSmartDialog.init(),
      home: const Scaffold(),
    ),
  );

  testWidgets('a failure shows what failed and what happened before it', (
    tester,
  ) async {
    await app(tester);
    EventLog.add('player', 'cdn failover -> upos-sz-mirrorcosov');
    FailureReport.show('视频无法播放', '所有线路都试过了');
    await tester.pumpAndSettle();
    expect(find.text('视频无法播放'), findsOneWidget);
    expect(find.text('所有线路都试过了'), findsOneWidget);
    expect(
      find.textContaining('cdn failover -> upos-sz-mirrorcosov'),
      findsOneWidget,
    );
    for (final action in ['复制', '保存', '关闭']) {
      expect(find.text(action), findsOneWidget);
    }
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('视频无法播放'), findsNothing);
  });

  testWidgets('the same failure again is one dialog, not two', (
    tester,
  ) async {
    await app(tester);
    FailureReport.show('转录失败', 'a');
    FailureReport.show('转录失败', 'b');
    await tester.pumpAndSettle();
    expect(find.text('转录失败'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  test('the events keep the latest 300', () {
    for (var i = 0; i < 350; i++) {
      EventLog.add('t', 'line $i');
    }
    final recent = EventLog.recent;
    expect(recent, hasLength(300));
    expect(recent.last, endsWith('line 349'));
  });
}
