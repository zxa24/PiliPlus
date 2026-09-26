import 'package:PiliPlus/pages/video/widgets/fill_export_dialog.dart';
import 'package:PiliPlus/services/asr/fill_export.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../translate/translation_test.dart'
    show FakeEngine, cue, pumpUntil, storeOf;

import 'package:PiliPlus/services/translate/translation_session.dart';

/// A session behind a [FillTarget], moved by hand.
class FakeTarget implements FillTarget {
  @override
  double progress = 0;
  @override
  bool isComplete = false;
  @override
  String? failure;

  var holds = 0;
  var releases = 0;
  bool get held => holds > releases;

  @override
  void hold() => holds++;

  @override
  void release() => releases++;
}

void main() {
  group('FillExport', () {
    late FakeTarget target;
    late List<bool> saves;

    FillExport flow() => FillExport(
      target,
      poll: const Duration(milliseconds: 10),
      save: ({required background}) async => saves.add(background),
    );

    setUp(() {
      target = FakeTarget();
      saves = [];
    });

    test('whole already, or nothing to fill: saved at once', () {
      target.isComplete = true;
      expect(FillExport.needed(target), isFalse);
      expect(FillExport.needed(null), isFalse);
      target
        ..isComplete = false
        ..failure = 'gone';
      expect(FillExport.needed(target), isFalse);
    });

    test('with gaps: holds the session until whole, then saves', () async {
      final export = flow()..start();
      expect(target.held, isTrue);
      target.progress = 0.4;
      await Future.delayed(const Duration(milliseconds: 30));
      expect(export.progress.value, closeTo(0.4, 1e-9));
      expect(saves, isEmpty);
      target
        ..progress = 1
        ..isComplete = true;
      await export.done;
      await Future.delayed(Duration.zero);
      expect(export.phase.value, FillPhase.saved);
      expect(saves, [false]);
      // back on the lead rule
      expect(target.held, isFalse);
    });

    test(
      'in the background: the save happens when whole, and says so',
      () async {
        final export = flow()
          ..start()
          ..toBackground();
        expect(export.phase.value, FillPhase.background);
        await Future.delayed(const Duration(milliseconds: 30));
        expect(saves, isEmpty);
        expect(target.held, isTrue);
        target.isComplete = true;
        await export.done;
        await Future.delayed(Duration.zero);
        expect(saves, [true]);
        expect(target.held, isFalse);
      },
    );

    test('cancel: nothing saved, the lead rule back', () async {
      final export = flow()
        ..start()
        ..cancel();
      expect(export.phase.value, FillPhase.cancelled);
      expect(target.held, isFalse);
      target.isComplete = true;
      await Future.delayed(const Duration(milliseconds: 30));
      expect(saves, isEmpty);
    });

    test('the session failing: nothing saved, the reason kept', () async {
      final export = flow()
        ..start()
        ..toBackground();
      target.failure = '转录已停止';
      await export.done;
      expect(export.phase.value, FillPhase.failed);
      expect(export.failure, '转录已停止');
      expect(saves, isEmpty);
      expect(target.held, isFalse);
    });

    test('progress never goes back', () async {
      final export = flow()..start();
      target.progress = 0.6;
      await Future.delayed(const Duration(milliseconds: 30));
      target.progress = 0.5;
      await Future.delayed(const Duration(milliseconds: 30));
      expect(export.progress.value, closeTo(0.6, 1e-9));
      export.cancel();
    });
  });

  group('the dialog', () {
    Future<void> app(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
      ),
    );

    testWidgets('whole: no dialog, saved at once', (tester) async {
      await app(tester);
      final target = FakeTarget()..isComplete = true;
      final saves = <bool>[];
      final flow = FillExportDialog.saveWhenWhole(
        target: target,
        save: ({required background}) async => saves.add(background),
      );
      await tester.pumpAndSettle();
      expect(flow, isNull);
      expect(saves, [false]);
      expect(find.textContaining('正在补全字幕'), findsNothing);
    });

    testWidgets('gaps: progress, 放到后台继续, then the save', (tester) async {
      await app(tester);
      final target = FakeTarget()..progress = 0.42;
      final saves = <bool>[];
      late FillExport? flow;
      await tester.runAsync(() async {
        flow = FillExportDialog.saveWhenWhole(
          target: target,
          save: ({required background}) async => saves.add(background),
        );
      });
      await tester.pumpAndSettle();
      expect(find.text('正在补全字幕 42%'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(target.held, isTrue);

      await tester.tap(find.text('放到后台继续'));
      await tester.pumpAndSettle();
      expect(find.textContaining('正在补全字幕'), findsNothing);
      expect(flow!.phase.value, FillPhase.background);
      expect(saves, isEmpty);

      target.isComplete = true;
      await tester.runAsync(() => flow!.done);
      await tester.pumpAndSettle();
      expect(saves, [true]);
      expect(target.held, isFalse);
      // the toasts
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('取消: closed, nothing saved, released', (tester) async {
      await app(tester);
      final target = FakeTarget()..progress = 0.1;
      final saves = <bool>[];
      late FillExport? flow;
      await tester.runAsync(() async {
        flow = FillExportDialog.saveWhenWhole(
          target: target,
          save: ({required background}) async => saves.add(background),
        );
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('正在补全字幕'), findsNothing);
      expect(flow!.phase.value, FillPhase.cancelled);
      expect(target.held, isFalse);
      target.isComplete = true;
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 700)),
      );
      expect(saves, isEmpty);
    });
  });

  group('a translation filled for a save', () {
    test(
      'translates past the lead and behind the viewer, then is whole',
      () async {
        final store = storeOf(
          [for (var i = 0; i < 5; i++) (start: i * 100.0, duration: 3.0)],
          [
            for (var i = 0; i < 5; i++)
              cue(i * 100.0, i * 100.0 + 3, 'unit $i'),
          ],
        );
        final engine = FakeEngine();
        final session = TranslationSession(
          transcript: transcriptView(store, complete: () => true),
          position: () => 250,
          engine: (_) async => engine,
          target: 'zh',
        )..start();
        await pumpUntil(
          () =>
              session.results.isNotEmpty &&
              session.state.value.stage == TranslationStage.waiting,
        );
        // within the lead only: 300
        expect(session.results.keys, [300000]);
        final target = TranslationFillTarget(session);
        expect(target.isComplete, isFalse);
        expect(target.progress, closeTo(0.2, 1e-9));
        target.hold();
        await pumpUntil(() => target.isComplete);
        expect(session.results.keys.toSet(), {
          0,
          100000,
          200000,
          300000,
          400000,
        });
        expect(target.progress, 1);
        target.release();
        await session.dispose();
      },
    );
  });
}
