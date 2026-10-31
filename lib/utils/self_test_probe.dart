/// LibrePili: what the self-test reads of the two watch pages, declared
/// apart from the pages (feature-logs/watch-page-shell/design.md §5 S0a).
///
/// The pages only write here; the self-test (S0b) reads, and sets the
/// switches. The file stays byte for byte the same when the layout code
/// moves into the shared shell (S1), so a reading means the same on both
/// sides of that move: the statements that write move, the declarations
/// do not.
///
/// Off unless the self-test runs: every writer below returns at once
/// without [isSelfTestProfile], the record waits for [SelfTestProbe.recorder]
/// and the probe scope for [SelfTestProbe.fsScope]. The stack-role keys are
/// the one exception (see [SelfTestProbe.slotBlack]).
library;

import 'dart:io' show Platform;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/self_test_window.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// A watch page as it was mounted: the route GetX had current then (the one
/// its [RouteAware] subscription follows) and the page State's element.
typedef WatchPageRow = ({Route<dynamic>? route, BuildContext element});

abstract final class SelfTestProbe {
  /// The layers of the bilibili page's player-slot Stack, each wrapped in a
  /// [KeyedSubtree] with one of these, so the order is read by role and not
  /// by widget type. Present in every build, the user's too: wrapped only in
  /// the self-test, the test would measure a tree the user never runs. A
  /// [KeyedSubtree] makes no render object, so a [Positioned] under it still
  /// reaches the Stack.
  static const slotBlack = 'watchPage.slot.black',
      slotPlayer = 'watchPage.slot.player',
      slotGate = 'watchPage.slot.subtitleGate',
      slotCover = 'watchPage.slot.cover',
      slotManualPlayer = 'watchPage.slot.manualPlayer',
          // the list of skips (SponsorBlock) and of parts to go on with
          slotPartList =
          'watchPage.slot.skipOrPartList',
      slotChoices = 'watchPage.slot.interactiveChoices';

  /// Every mounted watch page by its tag (the bilibili page's `heroTag`,
  /// the YouTube page's controller tag), added in `initState` and taken out
  /// in `dispose`. A list: two rows under one tag is a reading the
  /// self-test refuses, not one it should never see.
  static final pages = <String, List<WatchPageRow>>{};

  static void addPage(String tag, BuildContext element) {
    if (!isSelfTestProfile) return;
    (pages[tag] ??= []).add((route: Get.routing.route, element: element));
  }

  static void removePage(String tag, BuildContext element) {
    if (!isSelfTestProfile) return;
    final rows = pages[tag];
    if (rows == null) return;
    rows.removeWhere((row) => identical(row.element, element));
    if (rows.isEmpty) {
      pages.remove(tag);
      branches.remove(tag);
    }
  }

  /// The variants the bilibili page's first-level choice builds.
  static const pip = 'pip',
      portrait = 'portrait',
      landscape = 'landscape',
      almostSquare = 'almostSquare';

  /// What each page last built, written where the choice is made, by page
  /// tag: a page under another is still mounted and rebuilt with the
  /// window, and one value for the whole app would be the last page's.
  static final branches = <String, WatchPageBranch>{};

  /// The first level was chosen: what a level below decided before no
  /// longer stands, until it is built again (a landscape page gone portrait
  /// would otherwise still read as three columns).
  static void firstLevel(String tag, String variant) {
    if (!isSelfTestProfile) return;
    (branches[tag] ??= WatchPageBranch())
      ..first = variant
      ..threeColumn = null
      ..split16x9 = null
      ..split9x16 = null;
  }

  /// Landscape: a vertical video in three columns or not. Three columns
  /// leave the 16:9 choice below unbuilt.
  static void threeColumn(String tag, bool built) {
    if (!isSelfTestProfile) return;
    final branch = (branches[tag] ??= WatchPageBranch())..threeColumn = built;
    if (built) branch.split16x9 = null;
  }

  /// Landscape, not three columns: a 16:9 player too tall for the window,
  /// split instead.
  static void split16x9(String tag, bool split) {
    if (!isSelfTestProfile) return;
    (branches[tag] ??= WatchPageBranch()).split16x9 = split;
  }

  /// Almost square: a vertical video split 9:16 or not.
  static void split9x16(String tag, bool split) {
    if (!isSelfTestProfile) return;
    (branches[tag] ??= WatchPageBranch()).split9x16 = split;
  }

  /// The fullscreen record (design §2 R3 「F0」), null when nothing is
  /// recorded; set by the self-test.
  static FsProbeRecorder? recorder;

  /// The probe scope on the bilibili page ([SelfTestFsScope]), inserted
  /// only while this is on; set by the self-test before the page opens.
  static bool fsScope = false;
}

/// One page's choices; null is a level not built since the level above was
/// chosen.
final class WatchPageBranch {
  String? first;
  bool? threeColumn;
  bool? split16x9;
  bool? split9x16;

  Map<String, Object?> toJson() => {
    'first': first,
    'threeColumn': threeColumn,
    'split16x9': split16x9,
    'split9x16': split9x16,
  };
}

/// F0's per-frame record: every frame, every metrics change, every
/// fullscreen ask and set, with its time in ms from [start]; the existing
/// log lines are no anchor (`[layout] fullscreen … set` waits on a bounds
/// read, `[window] resized` is debounced 500 ms). Only records; nothing
/// reads it to decide.
final class FsProbeRecorder with WidgetsBindingObserver {
  final _clock = Stopwatch();
  DateTime? startedAt;
  var _on = false;

  /// Frames counted from [start]; a build is filed under the frame it was
  /// made in, the one the next frame callback closes.
  var _frame = 0;

  /// `[ms, frame, physical width, height, isFullScreen, fsProcessing]`, as
  /// the frame callback (after layout) sees them; 1 / 0 for the flags.
  final frames = <List<Object?>>[];

  /// `[ms, frame, where, tag, width, height, isFullScreen, fsProcessing]`:
  /// a scope that rebuilt and what it saw (`build` the bilibili page's
  /// build, `scope` its probe scope, `yt` the YouTube page's
  /// LayoutBuilder); the size is logical.
  final builds = <List<Object?>>[];

  /// Rebuilds per `where:tag`.
  final rebuilds = <String, int>{};

  /// `[ms, physical width, height, logical width, height]` at each
  /// `didChangeMetrics`: several WM_SIZE can come as one.
  final metrics = <List<Object?>>[];

  /// `[ms, 'asked' | 'set', status, inApp]`: fullscreen asked for, and
  /// [PlPlayerController.isFullScreen] set (the probe's `flagSet`).
  final flags = <List<Object?>>[];

  /// `[ms asked, 'before' | 'after', status, foreground]`: whether the
  /// window was the foreground one around each fullscreen change (Windows;
  /// null when it could not be read).
  final foreground = <List<Object?>>[];

  /// `[engine frame number, build µs, raster µs, total µs]`.
  final timings = <List<Object?>>[];

  static var _frameHooked = false;

  double get _ms => (_clock.elapsedMicroseconds / 100).round() / 10;

  void start() {
    if (_on) return;
    _on = true;
    startedAt ??= DateTime.now();
    _clock.start();
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // a persistent callback cannot be taken off again: one, for good, that
    // does nothing unless a recorder is on
    if (!_frameHooked) {
      _frameHooked = true;
      SchedulerBinding.instance.addPersistentFrameCallback((_) {
        final recorder = SelfTestProbe.recorder;
        if (recorder != null && recorder._on) recorder._onFrame();
      });
    }
  }

  void stop() {
    if (!_on) return;
    _on = false;
    _clock.stop();
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  static int _flag(bool value) => value ? 1 : 0;

  void _onFrame() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    final player = PlPlayerController.instance;
    frames.add([
      _ms,
      _frame,
      view?.physicalSize.width,
      view?.physicalSize.height,
      _flag(player?.isFullScreen.value ?? false),
      _flag(player?.fsProcessing ?? false),
    ]);
    _frame++;
  }

  void _onTimings(List<FrameTiming> list) {
    if (!_on) return;
    for (final timing in list) {
      timings.add([
        timing.frameNumber,
        timing.buildDuration.inMicroseconds,
        timing.rasterDuration.inMicroseconds,
        timing.totalSpan.inMicroseconds,
      ]);
    }
  }

  @override
  void didChangeMetrics() {
    if (!_on) return;
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return;
    final size = view.physicalSize;
    final ratio = view.devicePixelRatio * Pref.uiScale;
    metrics.add([
      _ms,
      size.width,
      size.height,
      size.width / ratio,
      size.height / ratio,
    ]);
  }

  /// A scope rebuilt: [where] is `build`, `scope` or `yt`; the flags are
  /// the ones the scope read, the player's now when it read none.
  void built(
    String where,
    String tag,
    Size size, {
    bool? isFullScreen,
    bool? fsProcessing,
  }) {
    if (!_on) return;
    final player = PlPlayerController.instance;
    final key = '$where:$tag';
    rebuilds[key] = (rebuilds[key] ?? 0) + 1;
    builds.add([
      _ms,
      _frame,
      where,
      tag,
      size.width,
      size.height,
      _flag(isFullScreen ?? player?.isFullScreen.value ?? false),
      _flag(fsProcessing ?? player?.fsProcessing ?? false),
    ]);
  }

  /// [PlPlayerController.triggerFullScreen] went ahead (not refused as a
  /// repeat or while switching).
  void fullScreenAsked(bool status, bool inApp) {
    if (!_on) return;
    flags.add([_ms, 'asked', _flag(status), _flag(inApp)]);
    _readForeground('before', status);
  }

  /// [PlPlayerController.isFullScreen] has just been set to [status].
  void fullScreenSet(bool status) {
    if (!_on) return;
    flags.add([_ms, 'set', _flag(status), null]);
    _readForeground('after', status);
  }

  /// Asked now, answered later: the platform thread takes it before the
  /// fullscreen change asked for after it.
  void _readForeground(String when, bool status) {
    if (!Platform.isWindows) return;
    final row = <Object?>[_ms, when, _flag(status), null];
    foreground.add(row);
    SelfTestWindow.isForeground().then(
      (value) => row[3] = value,
      onError: (_) {},
    );
  }

  Map<String, Object?> toJson() => {
    'startedAt': startedAt?.toIso8601String(),
    'frames': frames,
    'builds': builds,
    'rebuilds': rebuilds,
    'metrics': metrics,
    'flags': flags,
    'foreground': foreground,
    'timings': timings,
  };
}

/// F0's probe scope on the bilibili page, the shape the fullscreen hold
/// will have (an [Obx] reading `isFullScreen` around a [LayoutBuilder], as
/// the YouTube page has it): it records what it saw each time it rebuilt
/// and hands back the same [child], changing nothing in the layout.
/// Inserted only while [SelfTestProbe.fsScope] is on.
class SelfTestFsScope extends StatelessWidget {
  const SelfTestFsScope({
    super.key,
    required this.tag,
    required this.player,
    required this.child,
  });

  final String tag;
  final PlPlayerController player;
  final Widget child;

  @override
  Widget build(BuildContext context) => Obx(() {
    final isFullScreen = player.isFullScreen.value;
    return LayoutBuilder(
      builder: (context, box) {
        SelfTestProbe.recorder?.built(
          'scope',
          tag,
          box.biggest,
          isFullScreen: isFullScreen,
          fsProcessing: player.fsProcessing,
        );
        return child;
      },
    );
  });
}
