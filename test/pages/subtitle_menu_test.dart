import 'dart:io';

import 'package:PiliPlus/models/common/subtitle_source_preference.dart';
import 'package:PiliPlus/pages/video/widgets/on_device_menu.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_choice.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_menu.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

/// A page as the menu sees it.
class _Page implements SubtitleMenuHost {
  _Page({
    this.platformTracks = const [],
    this.platformTrackNames = const [],
    this.menuPicked = 'zh',
    this.menuActive,
    this.statuses = const {},
  });

  @override
  final List<PlatformTrack> platformTracks;
  @override
  final List<String> platformTrackNames;
  @override
  final String? menuPicked;
  @override
  final SubtitleSourcePreference? menuActive;
  final Map<String, SubtitleStatus> statuses;

  /// The menu's statuses follow the page while it is open (they are read
  /// in an Obx): a page's state is reactive.
  final tick = 0.obs;

  final calls = <String>[];

  @override
  bool get canTranscribe => true;
  @override
  int? get shownPlatformTrack => null;
  @override
  List<String> get spoken => const ['ja'];
  @override
  bool get hasTranscription => true;

  @override
  SubtitleStatus? menuStatus(String code) {
    tick.value;
    return statuses[code];
  }

  @override
  int? captionToTranslateInto(String? into) => null;
  @override
  bool hasTranslationInto(String into) => true;

  @override
  OpenPlan planFor(String code, {SubtitleSourcePreference? via}) =>
      decideOnOpen(
        choice: SubtitleChoice.fromCode(code),
        tracks: platformTracks,
        source: via ?? SubtitleSourcePreference.platform,
        canTranscribe: true,
        asrReady: true,
        translateReady: true,
      );

  @override
  Future<void> chooseOff() async => calls.add('off');

  @override
  Future<void> chooseLanguage(
    String code,
    OpenPlan plan, {
    Future<bool> Function()? mayTranscribe,
  }) async => calls.add(
    '$code ${plan.action.name}${plan.track == null ? '' : ' ${plan.track}'}',
  );

  @override
  Future<void> choosePlatformTrack(int index) async =>
      calls.add('track $index');
}

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('librepili-menu-test-');
    Hive.init(dir.path);
    GStorage.setting = await Hive.openBox('setting');
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester, _Page page) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => PopupMenuButton<int>(
                initialValue: OnDeviceMenu.initialValue(page),
                constraints: OnDeviceMenu.constraints,
                color: Colors.black,
                itemBuilder: (context) => OnDeviceMenu.items(context, page),
                child: const Text('字幕'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('字幕'));
    // not settled: a status under way spins for as long as it is
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Finder rowOf(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byType(PopupMenuItem<int>),
  );

  Finder iconIn(String label, IconData icon) =>
      find.descendant(of: rowOf(label), matching: find.byIcon(icon));

  testWidgets('by language, with the sources each one has', (tester) async {
    final page = _Page(
      platformTracks: const [(language: 'en', kind: PlatformTrackKind.author)],
      platformTrackNames: const ['English'],
      statuses: const {'zh': SubtitleStatus('生成中', busy: true)},
    );
    await open(tester, page);

    expect(find.text('选择会用于所有视频'), findsOneWidget);
    expect(find.text('关闭字幕'), findsOneWidget);
    expect(find.text('原文 · 日语'), findsOneWidget);
    expect(find.text('中文'), findsOneWidget);
    expect(find.text('其他语言…'), findsOneWidget);
    expect(find.text('更多字幕轨…'), findsOneWidget);

    // 中文: made on the device only, and under way
    expect(iconIn('中文', Icons.memory_outlined), findsOneWidget);
    expect(iconIn('中文', Icons.cloud_outlined), findsNothing);
    expect(
      find.descendant(of: rowOf('中文'), matching: find.text('生成中')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: rowOf('中文'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    // the lone English track stands for the speech too
    expect(iconIn('原文 · 日语', Icons.cloud_outlined), findsOneWidget);
    // 中文 is what the page shows: checked
    expect(
      find.descendant(of: rowOf('中文'), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rowOf('关闭字幕'), matching: find.byIcon(Icons.check)),
      findsNothing,
    );
  });

  testWidgets('the name uses the default source; an icon, its own', (
    tester,
  ) async {
    final page = _Page(
      platformTracks: const [
        (language: 'zh-CN', kind: PlatformTrackKind.author),
      ],
      platformTrackNames: const ['中文（中国）'],
      menuPicked: null,
    );
    await open(tester, page);
    await tester.tap(find.text('中文'));
    await tester.pumpAndSettle();
    // 平台优先 here, and the video has Chinese
    expect(page.calls, ['zh platform 0']);

    await tester.tap(find.text('字幕'));
    await tester.pumpAndSettle();
    await tester.tap(iconIn('中文', Icons.memory_outlined));
    await tester.pumpAndSettle();
    expect(page.calls.last, 'zh onDevice');
    // the icon closes the menu, as a tap on the row does
    expect(find.text('选择会用于所有视频'), findsNothing);

    await tester.tap(find.text('字幕'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭字幕'));
    await tester.pumpAndSettle();
    expect(page.calls.last, 'off');
  });

  testWidgets('off, checked; the platform icon lit when it is on screen', (
    tester,
  ) async {
    await open(tester, _Page(menuPicked: null));
    expect(
      find.descendant(of: rowOf('关闭字幕'), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    // nothing of its own: no list of its tracks to pick from
    expect(find.text('更多字幕轨…'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await open(
      tester,
      _Page(
        platformTracks: const [(language: 'en', kind: PlatformTrackKind.author)],
        platformTrackNames: const ['English'],
        menuPicked: 'en',
        menuActive: SubtitleSourcePreference.platform,
      ),
    );
    expect(iconIn('英语', Icons.cloud), findsOneWidget);
    // the device could make it too: its icon is there, not lit
    expect(iconIn('英语', Icons.memory_outlined), findsOneWidget);
  });
}
