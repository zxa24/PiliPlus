// LibrePili: the YouTube page's download panel (stage-2 plan §4.4; AC-P,
// AC15's panel half): what it lists is the answer it got when it opened —
// the current source's MP4 tiers, greyed the other source's that this one
// lacks (§10-7 Q6 b), by tier (§4.5) — the tier selected first from the
// page's cap, the states (asking, failed, live, no MP4, queued already),
// and 「下载」 making the record of the tier selected.
import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/pages/youtube/video/download_sheet.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/yt_source_store.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/download/download_test_support.dart';
import '../../services/download/yt_download_test_support.dart';

/// dQw4w9WgXcQ's MP4 ladder, as the direct source gives it.
List<Map<String, dynamic>> _ladder({bool with1080 = true}) => [
  if (with1080) ytVideoFormat(137, bytes: _v),
  ytVideoFormat(136, width: 1280, height: 720, bytes: _v),
  ytVideoFormat(135, width: 854, height: 480, bytes: _v),
  ytAudioFormat(140, bytes: _a),
];

/// [YtHarness]'s two streams' lengths.
const _v = 300 * 1024 + 5;
const _a = 120 * 1024 + 3;

/// A 1440 tier as VP9 (WebM) only.
Map<String, dynamic> _vp9_1440() => {
  ...ytVideoFormat(271, width: 2560, height: 1440, codec: 'vp9'),
  'mimeType': 'video/webm; codecs="vp9"',
};

/// A 2.4:1 film: tiers 1080, 720, 480 (short sides 800, 534, 356).
List<Map<String, dynamic>> _wide() => [
  ytVideoFormat(137, width: 1920, height: 800),
  ytVideoFormat(136, width: 1280, height: 534),
  ytVideoFormat(135, width: 854, height: 356),
  ytAudioFormat(140),
];

YtFormat _f(Map<String, dynamic> m) => YtFormat(m);

void main() {
  late Directory storage;
  final h = YtHarness();
  final toasts = <String>[];

  setUpAll(() async {
    storage = await initDownloadStorage(inMemory: true);
    await h.start();
    YtDownloadSheet.toastForTest = toasts.add;
  });
  tearDownAll(() async {
    YtDownloadSheet.toastForTest = null;
    await h.stop();
    await closeDownloadStorage(storage);
  });
  setUp(() {
    toasts.clear();
    h.routers.clear();
    YtSourceRouter.sharedHealth.clear();
    YtDownloadPlatform.otherWait = const Duration(seconds: 10);
    for (final s in [h.direct, h.invidious]) {
      s
        ..formats = _ladder()
        ..liveNow = false
        ..replay = false
        ..detailFailures.clear()
        ..streamFailures.clear()
        ..holdDetail = null
        ..detailCalls = 0;
    }
  });

  Future<void> pump(
    WidgetTester tester, {
    int pageCap = 1080,
    YtVideoDetail? pageDetail,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: YtDownloadSheet(
            videoId: ytId,
            pageCap: pageCap,
            pageDetail: pageDetail,
            service: h.service,
          ),
        ),
      ),
    );
    if (settle) {
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
    }
  }

  ListTile tile(WidgetTester tester, int tier) =>
      tester.widget<ListTile>(find.byKey(ValueKey('tier-$tier')));

  /// The tiers listed, highest first, each as (tier, enabled).
  List<(int, bool)> listed(WidgetTester tester) => [
    for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
      if (t.key case ValueKey<String>(:final value)
          when value.startsWith('tier-'))
        (int.parse(value.substring(5)), t.enabled),
  ];

  int? selected(WidgetTester tester) => [
    for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
      if (t.selected)
        if (t.key case ValueKey<String>(:final value))
          int.parse(value.substring(5)),
  ].firstOrNull;

  FilledButton downloadButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const ValueKey('download')));

  group('the tiers', () {
    test('MP4 video with MP4 audio only; tiers, highest first, once each', () {
      expect(ytDownloadableTiers([for (final m in _ladder()) _f(m)]), [
        1080,
        720,
        480,
      ]);
      // no mp4a: nothing
      expect(
        ytDownloadableTiers([
          for (final m in _ladder())
            if (m['itag'] != 140) _f(m),
        ]),
        isEmpty,
      );
      // WebM video is not a download's
      expect(
        ytDownloadableTiers([_f(_vp9_1440()), _f(ytAudioFormat(140))]),
        isEmpty,
      );
    });

    test('the default: the best format the page cap lets in, by tier', () {
      final wide = [for (final m in _wide()) _f(m)];
      expect(ytDefaultTier(wide, 1080), 1080);
      expect(ytDefaultTier(wide, 800), 1080);
      expect(ytDefaultTier(wide, 720), 720);
      expect(ytDefaultTier(wide, 0), 1080);
      expect(ytDefaultTier(wide, 100), 1080);
      final ladder = [for (final m in _ladder()) _f(m)];
      expect(ytDefaultTier(ladder, 720), 720);
      expect(ytDefaultTier(ladder, 0), 1080);
    });

    test('greyed: the reference less the downloadable', () {
      expect(ytGreyedTiers([720, 480], [1080, 720]), [1080]);
      expect(ytGreyedTiers([720, 480], null), isEmpty);
      expect(ytGreyedTiers([1080, 720], [1080]), isEmpty);
    });
  });

  testWidgets('asking: a spinner, 「下载」 off', (tester) async {
    final hold = Completer<void>();
    h.direct.holdDetail = () => hold.future;
    await pump(tester, settle: false);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(downloadButton(tester).onPressed, isNull);
    expect(find.byType(ListTile), findsNothing);
    hold.complete();
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(listed(tester), [(1080, true), (720, true), (480, true)]);
    expect(downloadButton(tester).onPressed, isNotNull);
  });

  testWidgets('the current source lists; the page cap 720 selects 720', (
    tester,
  ) async {
    await pump(tester, pageCap: 720);
    expect(listed(tester), [(1080, true), (720, true), (480, true)]);
    expect(selected(tester), 720);
  });

  testWidgets('page cap 0 (none): the highest tier selected', (tester) async {
    await pump(tester, pageCap: 0);
    expect(selected(tester), 1080);
  });

  testWidgets(
    "the other source has 1080, the current one not: 1080 greyed, not "
    'tappable, its words; the other asked on a router of its own',
    (tester) async {
      h.direct.formats = _ladder(with1080: false);
      await pump(tester, pageCap: 1080);
      expect(listed(tester), [(1080, false), (720, true), (480, true)]);
      expect(tile(tester, 1080).onTap, isNull);
      expect(find.text('当前来源不提供'), findsOneWidget);
      expect(selected(tester), 720);
      await tester.tap(find.byKey(const ValueKey('tier-1080')));
      await tester.pump();
      expect(selected(tester), 720);
      // the current source on the shared table, the other on its own
      expect(h.routers.first.shared, isTrue);
      expect(h.routers.last.own, isTrue);
      expect(h.routers.last.shared, isFalse);
      expect(YtSourceRouter.sharedHealth.containsKey('invidious'), isFalse);
      expect(h.invidious.detailCalls, 1);
    },
  );

  testWidgets("the other source's WebM-only 1440: not greyed", (tester) async {
    h.invidious.formats = [..._ladder(), _vp9_1440()];
    await pump(tester);
    expect(listed(tester), [(1080, true), (720, true), (480, true)]);
  });

  testWidgets('the other source failing: no greyed tier', (tester) async {
    h.direct.formats = _ladder(with1080: false);
    h.invidious.detailFailures.addAll(
      List.filled(4, const YtVerdict(YtCause.transient, 'timeout')),
    );
    await pump(tester);
    expect(listed(tester), [(720, true), (480, true)]);
  });

  testWidgets('the other source later than its wait: no greyed tier', (
    tester,
  ) async {
    YtDownloadPlatform.otherWait = const Duration(seconds: 1);
    h.direct.formats = _ladder(with1080: false);
    final never = Completer<void>();
    h.invidious.holdDetail = () => never.future;
    await pump(tester);
    expect(find.text('正在查询另一个来源'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('正在查询另一个来源'), findsNothing);
    expect(listed(tester), [(720, true), (480, true)]);
  });

  testWidgets(
    'Invidious current while direct cools down: direct not asked, no greyed '
    'tier',
    (tester) async {
      YtSourceRouter.sharedHealth['direct'] = YtSourceHealth()
        ..cooldownUntil = DateTime.now().add(const Duration(minutes: 10));
      h.invidious.formats = _ladder(with1080: false);
      await pump(tester);
      expect(h.direct.detailCalls, 0);
      expect(listed(tester), [(720, true), (480, true)]);
    },
  );

  testWidgets(
    "the page's own detail is not the list: its 1080 is not selectable when "
    'the panel\'s answer lacks it',
    (tester) async {
      h.direct.formats = _ladder(with1080: false);
      h.invidious.formats = _ladder(with1080: false);
      final page = YtVideoDetail(
        videoId: ytId,
        title: 'Never Gonna Give You Up',
        author: 'Rick Astley',
        channelId: 'UCuAXFkgsw1L7xaCfnd5JJOw',
        duration: const Duration(seconds: 213),
        thumbnails: const [],
        formats: [for (final m in _ladder()) _f(m)],
        captionTracks: const [],
        isLive: false,
        expiresIn: Duration.zero,
      );
      await pump(tester, pageDetail: page);
      expect(listed(tester), [(720, true), (480, true)]);
      expect(find.byKey(const ValueKey('tier-1080')), findsNothing);
    },
  );

  testWidgets('a wide film: 1080, 720, 480; page cap 800 selects 1080', (
    tester,
  ) async {
    h.direct.formats = _wide();
    h.invidious.formats = _wide();
    await pump(tester, pageCap: 800);
    expect(listed(tester), [(1080, true), (720, true), (480, true)]);
    expect(selected(tester), 1080);
  });

  testWidgets('a wide film, page cap 720: 720 selected', (tester) async {
    h.direct.formats = _wide();
    await pump(tester, pageCap: 720);
    expect(selected(tester), 720);
  });

  testWidgets('both sources 1920x800: one 1080 tier, nothing greyed', (
    tester,
  ) async {
    h.direct.formats = [
      ytVideoFormat(137, width: 1920, height: 800),
      ytAudioFormat(140),
    ];
    h.invidious.formats = [
      ytVideoFormat(399, width: 1920, height: 800, codec: 'av01.0.08M.08'),
      ytAudioFormat(140),
    ];
    await pump(tester);
    expect(listed(tester), [(1080, true)]);
  });

  testWidgets('live now: no tiers, its words, 「下载」 off', (tester) async {
    h.direct.liveNow = true;
    await pump(tester);
    expect(find.text('直播中或尚未开播的视频不能下载'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(downloadButton(tester).onPressed, isNull);
  });

  testWidgets("a live stream's replay (live content, not live now): listed", (
    tester,
  ) async {
    h.direct.replay = true;
    await pump(tester);
    expect(find.text('直播中或尚未开播的视频不能下载'), findsNothing);
    expect(listed(tester), [(1080, true), (720, true), (480, true)]);
  });

  testWidgets('an upcoming video (the direct refusal): the live words', (
    tester,
  ) async {
    h.direct.detailFailures.add(
      const YtVerdict(
        YtCause.contentUnavailable,
        'playability:live_stream_offline',
        'soon',
        true,
      ),
    );
    await pump(tester);
    expect(find.text('直播中或尚未开播的视频不能下载'), findsOneWidget);
    // taken as definite in the panel's own call: the shared router's
    // suspect run not lengthened (review 2e)
    expect(YtSourceRouter.sharedHealth['direct']?.suspectStreak ?? 0, 0);
  });

  testWidgets(
    'Invidious current, the other (direct) says live: the live words',
    (tester) async {
      h.direct
        ..detailFailures.addAll(
          List.filled(4, const YtVerdict(YtCause.transient, 'timeout')),
        )
        ..liveIds.add(ytId);
      try {
        await pump(tester);
        expect(find.text('直播中或尚未开播的视频不能下载'), findsOneWidget);
        expect(downloadButton(tester).onPressed, isNull);
      } finally {
        h.direct.liveIds.clear();
      }
    },
  );

  testWidgets('a single-source mode: the other source not asked', (
    tester,
  ) async {
    YtSourceStore.debugMode = YtSourceMode.directOnly;
    try {
      h.direct.formats = _ladder(with1080: false);
      await pump(tester);
      expect(h.invidious.detailCalls, 0);
      expect(listed(tester), [(720, true), (480, true)]);
    } finally {
      YtSourceStore.debugMode = YtSourceMode.auto;
    }
  });

  testWidgets('no source answers: its words and a retry that asks again', (
    tester,
  ) async {
    for (final s in [h.direct, h.invidious]) {
      s.detailFailures.addAll(
        List.filled(4, const YtVerdict(YtCause.transient, 'timeout')),
      );
    }
    await pump(tester);
    expect(find.text('暂时取不到可下载的格式'), findsOneWidget);
    expect(downloadButton(tester).onPressed, isNull);
    for (final s in [h.direct, h.invidious]) {
      s.detailFailures.clear();
    }
    await tester.tap(find.text('重试'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(listed(tester), [(1080, true), (720, true), (480, true)]);
  });

  testWidgets('no MP4: its words', (tester) async {
    for (final s in [h.direct, h.invidious]) {
      s.formats = [
        _vp9_1440(),
        {
          ...ytAudioFormat(251),
          'mimeType': 'audio/webm; codecs="opus"',
        },
      ];
    }
    await pump(tester);
    expect(find.text('没有可下载的 MP4 格式'), findsOneWidget);
    expect(downloadButton(tester).onPressed, isNull);
  });

  testWidgets(
    '「下载」: the record of the tier selected; then it says it is queued',
    (tester) async {
      await pump(tester, pageCap: 720);
      await tester.tap(find.byKey(const ValueKey('tier-480')));
      await tester.pump();
      expect(selected(tester), 480);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('download')));
        await until(() => toasts.isNotEmpty, reason: 'its toast');
      });
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      expect(toasts, ['已加入下载队列']);
      final e = h.entry();
      expect(e.maxHeight, 480);
      expect(find.text('已在下载队列中'), findsOneWidget);
      expect(find.byKey(const ValueKey('download')), findsNothing);
      await tester.runAsync(() => h.untilStatus(e));
      // a panel opened now says it is downloaded
      await tester.pumpWidget(const SizedBox());
      await pump(tester);
      // its check of the list waits for the list's read, a future of the
      // real zone (a test's only)
      await tester.runAsync(() => settle(10));
      await tester.pump();
      expect(find.text('已下载'), findsOneWidget);
      await tester.runAsync(
        () => h.service.deleteDownload(
          entry: e,
          removeList: true,
          deleteExported: true,
        ),
      );
    },
  );
}
