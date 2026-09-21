import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/member/contribute_type.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/member/search_archive/data.dart';
import 'package:PiliPlus/models_new/space/space_archive/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/pages/danmaku/controller.dart';
import 'package:PiliPlus/pages/local/favs.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/youtube/search/controller.dart';
import 'package:PiliPlus/pages/youtube/video/controller.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:PiliPlus/services/local_player.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/models/common/platform_mode.dart';
import 'package:PiliPlus/services/platform_service.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_download.dart';
import 'package:PiliPlus/services/asr/audio_extract.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/services/asr/transcriber.dart';
import 'package:media_kit/media_kit.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerAddedEvent,
        PointerDeviceKind,
        PointerDownEvent,
        PointerHoverEvent,
        PointerUpEvent;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart'
    show IconButton, PopupMenuButton, Tooltip;
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

/// Command-line self test (LibrePili), for scripted checks of a real build:
///
///   LibrePili.exe --selftest [--download BVxxx] [--qn 80] [--local]
///                 [--keep] [--out result.json]
///
/// Runs after the app has started normally, writes a JSON report and exits
/// with 0 when every check passed, 1 otherwise.
abstract final class SelfTest {
  static bool isRequested(List<String> args) => args.contains('--selftest');

  static String? _arg(List<String> args, String name) {
    final i = args.indexOf(name);
    return i != -1 && i + 1 < args.length ? args[i + 1] : null;
  }

  /// Writes the `started` marker so a caller can tell "app never started"
  /// from "test still running". `--out` comes from the args alone, so this
  /// works before storage (and everything else) is up.
  static void markStarted(List<String> args) {
    if (_arg(args, '--out') case final out?) {
      try {
        File(out).writeAsStringSync(jsonEncode({'stage': 'started'}));
      } catch (_) {}
    }
  }

  /// The app could not start (e.g. storage init failed): the run is recorded
  /// as failed and the process exits non-zero, so a scripted caller checking
  /// the exit code does not read a broken build as a pass.
  static Never abort(List<String> args, Object error) {
    if (_arg(args, '--out') case final out?) {
      try {
        File(out).writeAsStringSync(
          jsonEncode({'stage': 'error', 'pass': false, 'error': '$error'}),
        );
      } catch (_) {}
    }
    exit(1);
  }

  /// Schedules the run once the first frame is on screen.
  /// Every framework error seen during a run.
  ///
  /// The self-test used to assert on controller state alone, so a page that
  /// rendered as Flutter's red error box still reported `pass: true` — three
  /// separate crashes on the YouTube page were found by a human opening the
  /// app, not by this. A build that throws is a failure whatever the
  /// controllers say.
  static final uiErrors = <String>[];

  static void _watchForUiErrors() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      // overflow is reported through the same channel and is just as much a
      // broken screen
      final where = details.context?.toDescription() ?? '';
      // the "relevant error-causing widget" is what identifies an overflow
      final info = details.informationCollector
          ?.call()
          .map((n) => n.toString())
          .firstWhere(
            (line) => line.contains('widget'),
            orElse: () => '',
          );
      uiErrors.add(
        // keep enough of the report to name the widget and its file:line —
        // the first line alone said "a RenderFlex overflowed" and nothing else
        '${details.toString().replaceAll(RegExp(r'\s+'), ' ').trim().substring(0, math.min(320, details.toString().replaceAll(RegExp(r'\s+'), ' ').trim().length))}'
        '${where.isEmpty ? '' : ' @ $where'}'
        '${(info ?? '').isEmpty ? '' : ' :: ${info!.replaceAll(RegExp(r'\s+'), ' ').trim()}'}',
      );
      previous?.call(details);
    };
  }

  // ------------------------------------------------------------ driving UI
  //
  // A probe that only calls controller methods proves the controller works.
  // Every panel defect so far was in a widget the probe never built: the
  // menu entry that rendered as a grey box, the row that overflowed. These
  // walk the live element tree and dispatch real pointer events, so a panel
  // that throws when opened fails the run instead of never being opened.

  static Element? _findElement(bool Function(Element) test) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (test(element)) {
        found = element;
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

  /// True when some [Text] on screen reads exactly [label].
  static bool _seesText(String label) => _findElement(_isText(label)) != null;

  /// Prefix, not equality: most labels in these panels carry their value
  /// ('字体大小 100.0%'), and an exact match on the name alone finds nothing.
  static bool _seesLabel(String prefix) =>
      _findElement(
        (e) => e.widget is Text && _textOf(e.widget as Text).startsWith(prefix),
      ) !=
      null;

  static bool Function(Element) _isText(String label) =>
      (e) => e.widget is Text && _textOf(e.widget as Text) == label;

  /// The words a [Text] shows, whether it was given a string or a span tree.
  /// A Text.rich has a null `data`, so reading that alone finds nothing in
  /// any of the rich rows this app builds.
  static String _textOf(Text text) {
    if (text.data case final data?) return data;
    final buffer = StringBuffer();
    text.textSpan?.visitChildren((span) {
      if (span is TextSpan) buffer.write(span.text ?? '');
      return true;
    });
    return buffer.toString();
  }

  /// Every [Text] currently in the tree, for when an expected label is not
  /// found and the question becomes "then what IS on screen?".
  static List<String> _visibleTexts() {
    final seen = <String>[];
    void visit(Element element) {
      if (element.widget case final Text text) {
        final d = _textOf(text);
        if (d.trim().isNotEmpty && !seen.contains(d)) seen.add(d);
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return seen;
  }

  static RenderBox? _boxOf(bool Function(Element) test) {
    final box = _findElement(test)?.renderObject;
    return box is RenderBox && box.hasSize && box.attached ? box : null;
  }

  /// Moves a synthetic mouse to [position]. The desktop player shows its
  /// controls on hover, so this is the only way to check that from a probe.
  static Future<void> _hover(Offset position) async {
    const device = 7301;
    final binding = GestureBinding.instance;
    if (!_mouseAdded) {
      _mouseAdded = true;
      binding.handlePointerEvent(
        const PointerAddedEvent(kind: PointerDeviceKind.mouse, device: device),
      );
    }
    binding.handlePointerEvent(
      PointerHoverEvent(
        kind: PointerDeviceKind.mouse,
        device: device,
        position: position,
      ),
    );
    await Future.delayed(const Duration(milliseconds: 400));
  }

  static var _mouseAdded = false;

  static int _countElements(bool Function(Element) test) {
    var count = 0;
    void visit(Element element) {
      if (test(element)) count++;
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return count;
  }

  static int _pointer = 9100;

  /// Taps the centre of the first widget [test] accepts. Returns false when
  /// nothing matched or it has no box to tap.
  static Future<bool> _tap(bool Function(Element) test) async {
    final element = _findElement(test);
    final box = element?.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) return false;
    final position = box.localToGlobal(box.size.center(Offset.zero));
    final pointer = ++_pointer;
    final binding = GestureBinding.instance
      ..handlePointerEvent(
        PointerDownEvent(pointer: pointer, position: position),
      );
    await Future.delayed(const Duration(milliseconds: 80));
    binding.handlePointerEvent(
      PointerUpEvent(pointer: pointer, position: position),
    );
    // long enough for a route transition (350ms) plus a frame or two
    await Future.delayed(const Duration(milliseconds: 900));
    return true;
  }

  /// Taps the button carrying [tooltip] — how the player's bar labels every
  /// one of its buttons.
  static Future<bool> _tapTooltip(String tooltip) => _tap(
    (e) => switch (e.widget) {
      Tooltip(message: final m) => m == tooltip,
      IconButton(tooltip: final m) => m == tooltip,
      PopupMenuButton(tooltip: final m) => m == tooltip,
      _ => false,
    },
  );

  static Future<bool> _tapText(String label) => _tap(_isText(label));

  static void schedule(List<String> args) {
    markStarted(args);
    _watchForUiErrors();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 2), () => _run(args));
    });
  }

  static Future<void> _run(List<String> args) async {
    final out = _arg(args, '--out') ?? path.join(tmpDirPath, 'selftest.json');
    final report = <String, dynamic>{
      'startedAt': DateTime.now().toIso8601String(),
      'args': args,
      // isolated profile: never the user's own data (see isSelfTestProfile)
      'dataDir': appSupportDirPath,
      'downloadDir': downloadPath,
      'checks': <Map<String, dynamic>>[],
    };
    final checks = report['checks'] as List<Map<String, dynamic>>;
    var ok = true;

    Future<void> scenario(
      String name,
      Future<Map<String, dynamic>> Function() body,
    ) async {
      final sw = Stopwatch()..start();
      Map<String, dynamic> result;
      try {
        result = await body();
      } catch (e, s) {
        result = {'pass': false, 'error': '$e', 'stack': '$s'};
      }
      // the framework owns these three keys; a scenario that writes them
      // loses its own value silently (a channel's name once came back as
      // "youtubeChannel")
      assert(!result.containsKey('name'), 'scenario $name wrote "name"');
      result['name'] = name;
      result['ms'] = sw.elapsedMilliseconds;
      if (uiErrors.isNotEmpty) {
        // a scenario that drove the UI into an error state did not pass,
        // whatever else it measured
        result
          ..['pass'] = false
          ..['uiErrors'] = List<String>.from(uiErrors);
        uiErrors.clear();
      }
      ok &= result['pass'] == true;
      checks.add(result);
    }

    if (_arg(args, '--feed') case final mid?) {
      await scenario('feed', () => _feed(int.parse(mid)));
    }
    if (args.contains('--local')) {
      await scenario('localLibrary', _localLibrary);
    }
    if (_arg(args, '--open-local') case final target?) {
      final hold = int.tryParse(_arg(args, '--hold') ?? '') ?? 15;
      await scenario(
        'openLocal',
        () => _openLocal(target, hold, play: args.contains('--play')),
      );
    }
    if (args.contains('--open-offline')) {
      final hold = int.tryParse(_arg(args, '--hold') ?? '') ?? 15;
      final tab = int.tryParse(_arg(args, '--tab') ?? '');
      await scenario(
        'openOffline',
        () => _openOffline(hold, tab: tab, play: args.contains('--play')),
      );
    }
    if (_arg(args, '--download') case final bvid?) {
      final qn = int.tryParse(_arg(args, '--qn') ?? '') ?? 80;
      await scenario(
        'download',
        () => _download(bvid, qn, keep: args.contains('--keep')),
      );
    }
    if (_arg(args, '--hover-controls') case final video?) {
      await scenario('hoverControls', () => _hoverControls(video));
    }
    if (_arg(args, '--yt-download') case final video?) {
      await scenario('ytDownload', () => _ytDownload(video));
    }
    if (_arg(args, '--yt-fav') case final video?) {
      await scenario('ytFav', () => _ytFav(video));
    }
    if (_arg(args, '--yt-search-ui') case final query?) {
      await scenario('ytSearchUi', () => _ytSearchUi(query));
    }
    if (args.contains('--platform-search')) {
      await scenario('platformSearch', _platformSearch);
    }
    if (_arg(args, '--yt-channel') case final channel?) {
      await scenario('youtubeChannel', () => _youtubeChannel(channel));
    }
    if (_arg(args, '--yt-search') case final query?) {
      await scenario('youtubeSearch', () => _youtubeSearch(query));
    }
    if (_arg(args, '--open-yt') case final video?) {
      final hold = int.tryParse(_arg(args, '--hold') ?? '') ?? 20;
      await scenario('openYouTube', () => _openYouTube(video, hold));
    }
    if (_arg(args, '--yt') case final video?) {
      await scenario('youtube', () => _youtube(video));
    }
    if (_arg(args, '--probe-playback') case final url?) {
      final seconds = int.tryParse(_arg(args, '--probe-secs') ?? '') ?? 20;
      await scenario('probePlayback', () => _probePlayback(url, seconds));
    }
    if (_arg(args, '--asr-download') case final dir?) {
      await scenario('asrDownload', () => _asrDownload(dir));
    }
    if (_arg(args, '--asr') case final source?) {
      await scenario(
        'asr',
        () => _asr(
          source,
          modelDir: _arg(args, '--asr-models'),
          srtOut: _arg(args, '--asr-srt'),
          pcmOut: _arg(args, '--asr-pcm'),
        ),
      );
    }

    report
      ..['pass'] = ok
      ..['finishedAt'] = DateTime.now().toIso8601String();
    await File(out).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    exit(ok ? 0 : 1);
  }

  // ------------------------------------------------------------ scenarios

  /// LibrePili: after toggling fullscreen, does moving the mouse over the
  /// video bring the control bars back?
  ///
  /// Reported: it does not — the pointer has to leave the player and come
  /// back. The first version of this probe passed, because it reset
  /// showControls to false before each hover and so made every hover a
  /// genuine change — which is exactly the condition the defect needs to be
  /// absent. It also asserted on showControls, and that flag was never the
  /// thing that was wrong: the bar's own position is.
  static Future<Map<String, dynamic>> _hoverControls(String input) async {
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    unawaited(Get.toNamed('/ytVideo', parameters: {'id': videoId}));
    await Future.delayed(const Duration(seconds: 4));
    final controller = Get.find<YtVideoController>(tag: videoId);
    for (var i = 0; i < 20 && controller.stage.value != .ready; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    final player = controller.plPlayerController;

    RenderBox? playerBox() =>
        _boxOf((e) => e.widget.runtimeType.toString() == 'PLVideoPlayer');

    /// Is the header bar actually on the video, or slid off the top? The
    /// widget exists either way — SlideTransition only moves it — so its
    /// position is the only honest answer.
    bool headerShowing() {
      final box = playerBox();
      final header = _boxOf(
        (e) => switch (e.widget) {
          IconButton(tooltip: final t) => t == '更多设置',
          _ => false,
        },
      );
      if (box == null || header == null) return false;
      final top = box.localToGlobal(Offset.zero).dy;
      return header.localToGlobal(header.size.center(Offset.zero)).dy >= top;
    }

    final firstBox = playerBox();
    if (firstBox == null) {
      return {'pass': false, 'reason': 'player not found'};
    }
    final centre = firstBox.localToGlobal(firstBox.size.center(Offset.zero));

    // the state a user is in when they press the fullscreen button: the bar
    // is up, because they just moved the mouse to press it
    player.controls = true;
    await Future.delayed(const Duration(milliseconds: 400));
    final windowed = headerShowing();

    await player.triggerFullScreen(status: true);
    await Future.delayed(const Duration(seconds: 2));
    final fsBox = playerBox();
    final fsCentre = fsBox == null
        ? centre
        : fsBox.localToGlobal(fsBox.size.center(Offset.zero));

    // move the mouse, exactly as the user does — and change nothing else
    await _hover(fsCentre);
    await _hover(fsCentre + const Offset(9, 7));
    final hoverInFS = headerShowing();
    final flagInFS = player.showControls.value;

    // the workaround they found: leave the player and come back
    player.controls = false;
    await Future.delayed(const Duration(milliseconds: 300));
    player.controls = true;
    await Future.delayed(const Duration(milliseconds: 400));
    final afterReEnterFS = headerShowing();

    await player.triggerFullScreen(status: false);
    await Future.delayed(const Duration(seconds: 2));
    final backBox = playerBox();
    await _hover(
      backBox == null
          ? centre
          : backBox.localToGlobal(backBox.size.center(Offset.zero)),
    );
    final hoverAfterLeavingFS = headerShowing();

    Get.back();
    await Future.delayed(const Duration(seconds: 1));
    return {
      'pass': windowed && hoverInFS && hoverAfterLeavingFS,
      'windowed': windowed,
      'hoverInFS': hoverInFS,
      // true while hoverInFS is false is the whole defect: the flag says
      // "shown", the bar is off the top of the screen
      'flagInFS': flagInFS,
      'afterReEnterFS': afterReEnterFS,
      'hoverAfterLeavingFS': hoverAfterLeavingFS,
    };
  }

  /// LibrePili: download a YouTube video and check the file is one playable
  /// mp4, not two halves with an extension.
  ///
  /// The two adaptive streams are remuxed by the same pure-Dart [Mp4Remuxer]
  /// the bilibili downloads use, so "it finished" is not the question — the
  /// question is whether the container it wrote has both tracks and a
  /// duration. That is read back out of the file.
  static Future<Map<String, dynamic>> _ytDownload(String input) async {
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    unawaited(Get.toNamed('/ytVideo', parameters: {'id': videoId}));
    await Future.delayed(const Duration(seconds: 4));
    final controller = Get.find<YtVideoController>(tag: videoId);
    for (var i = 0; i < 20 && controller.stage.value != .ready; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    final pair = controller.streams;
    if (pair == null) {
      Get.back();
      return {'pass': false, 'reason': 'no streams'};
    }

    // a small cap so the probe downloads a few MB rather than a whole 4K
    // review: the container is what is being checked, not the bandwidth
    await controller.setMaxHeight(controller.availableHeights.last);
    await Future.delayed(const Duration(seconds: 2));

    final stages = <String>[];
    String? file;
    String? error;
    try {
      file = await YtDownloader.download(
        pair: controller.streams!,
        videoId: videoId,
        title: controller.detail.value?.title ?? videoId,
        onProgress: (_, stage) {
          if (stages.isEmpty || stages.last != stage) stages.add(stage);
        },
      );
    } catch (e) {
      error = '$e';
    }
    Get.back();
    await Future.delayed(const Duration(seconds: 1));

    var bytes = 0;
    var playable = false;
    Duration? duration;
    if (file != null && File(file).existsSync()) {
      bytes = File(file).lengthSync();
      // open it the way a player would, and read what it reports back
      final player = await Player.create();
      try {
        await player.open(Media(file), play: false);
        for (var i = 0; i < 20; i++) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (player.state.duration > Duration.zero) break;
        }
        duration = player.state.duration;
        playable =
            duration > Duration.zero &&
            player.state.tracks.video.length > 1 &&
            player.state.tracks.audio.length > 1;
      } catch (e) {
        error ??= 'open: $e';
      } finally {
        await player.dispose();
      }
      try {
        File(file).deleteSync();
      } catch (_) {}
    }

    return {
      'pass': error == null && playable && bytes > 0,
      'file': file,
      'bytes': bytes,
      'seconds': duration?.inSeconds,
      'expected': controller.detail.value?.duration.inSeconds,
      'playable': playable,
      'stages': stages,
      'error': error,
    };
  }

  /// LibrePili: favouriting a YouTube video, and opening it again from the
  /// folder it lands in.
  ///
  /// The folder renders every item with bilibili's VideoCardH, whose default
  /// tap pushes a bilibili page from a bvid. A YouTube item has no bvid, so
  /// the risk this checks is not "does it save" but "does the card that
  /// saved it still go somewhere real".
  static Future<Map<String, dynamic>> _ytFav(String input) async {
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    unawaited(Get.toNamed('/ytVideo', parameters: {'id': videoId}));
    await Future.delayed(const Duration(seconds: 4));
    final controller = Get.find<YtVideoController>(tag: videoId);
    for (var i = 0; i < 20 && controller.stage.value != .ready; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }

    final key = controller.favKey;
    final wasFav = LocalLibrary.isFav(key);
    await LocalLibrary.setFolders(key, controller.favData, {
      LocalLibrary.defaultFolderId,
    });
    controller.refreshFav();
    final saved = controller.isFav.value && LocalLibrary.isFav(key);

    // a bilibili-shaped item beside it: the folder has to render both, and
    // the layout fault this found is in the card, not in either platform's
    // data — putting one of each in makes that a measurement rather than an
    // argument.
    const biliKey = 'av000000001';
    final biliWasFav = LocalLibrary.isFav(biliKey);
    final biliData = LocalLibrary.buildFavData(
      aid: 1,
      bvid: 'BV1xx411c7mD',
      title: 'LibrePili selftest 的一条 B 站条目',
      durationSec: 125,
      author: 'selftest',
    );
    await LocalLibrary.setFolders(biliKey, biliData, {
      LocalLibrary.defaultFolderId,
    });

    final items = LocalLibrary.folderItems(LocalLibrary.defaultFolderId);
    final item = items.firstWhereOrNull((e) => e.key == key);
    final title = item?.title;
    final youtubeId = item?.youtubeId;

    Get.back();
    await Future.delayed(const Duration(seconds: 1));

    // the folder itself, rendered, and a tap on the card we just added
    unawaited(
      Get.to(
        () => LocalFavFolderPage(
          folder: LocalFavFolder(
            id: LocalLibrary.defaultFolderId,
            title: '默认收藏夹',
            order: 0,
            ctime: 0,
          ),
        ),
      ),
    );
    await Future.delayed(const Duration(seconds: 2));
    final cardShown = title != null && _seesText(title);
    final biliCardShown = _seesText('LibrePili selftest 的一条 B 站条目');
    var openedRoute = '';
    if (cardShown) {
      await _tapText(title);
      await Future.delayed(const Duration(milliseconds: 900));
      openedRoute = Get.currentRoute;
      if (openedRoute.startsWith('/ytVideo')) {
        Get.back();
        await Future.delayed(const Duration(milliseconds: 600));
      }
    }
    Get.back();
    await Future.delayed(const Duration(milliseconds: 600));

    // leave the library as it was found
    if (!wasFav) await LocalLibrary.setFolders(key, controller.favData, {});
    if (!biliWasFav) await LocalLibrary.setFolders(biliKey, biliData, {});

    return {
      'pass':
          saved &&
          youtubeId == videoId &&
          cardShown &&
          biliCardShown &&
          openedRoute.startsWith('/ytVideo'),
      'key': key,
      'saved': saved,
      'title': title,
      'youtubeId': youtubeId,
      'cardShown': cardShown,
      'biliCardShown': biliCardShown,
      'openedRoute': openedRoute,
      'cleanedUp': !wasFav && !LocalLibrary.isFav(key),
    };
  }

  /// LibrePili: the search pages, walked the way a user walks them.
  ///
  /// The box, the history chip it leaves behind, the results page it opens
  /// and the cards on it — all four were rebuilt to bilibili's shape, and
  /// the cards now take their height from a grid rather than their content,
  /// which is exactly the kind of change that overflows a row. Rendering
  /// them is the only way to find that out.
  static Future<Map<String, dynamic>> _ytSearchUi(String query) async {
    final platform = PlatformService.to;
    final before = platform.mode.value;
    await platform.set(PlatformMode.youtube);
    await Future.delayed(const Duration(seconds: 1));

    final pressed =
        await _tapTooltip('搜索') ||
        await _tap(
          (e) => e.widget is Icon && (e.widget as Icon).semanticLabel == '搜索',
        );
    await Future.delayed(const Duration(milliseconds: 700));
    final searchRoute = Get.currentRoute;

    String? resultRoute;
    var cards = 0;
    var historyChip = false;
    if (searchRoute == '/ytSearch') {
      Get.find<YtSearchController>(tag: 'yt').onClickKeyword(query);
      for (var i = 0; i < 15; i++) {
        await Future.delayed(const Duration(seconds: 1));
        cards = _countElements((e) => e.widget is YtVideoTile);
        if (cards > 0) break;
      }
      resultRoute = Get.currentRoute;

      Get.back();
      await Future.delayed(const Duration(milliseconds: 800));
      // the keyword should now be a chip on the page that sent us
      historyChip = _seesText(query);
      Get.back();
      await Future.delayed(const Duration(milliseconds: 600));
    }

    await platform.set(before);
    return {
      'pass':
          pressed &&
          searchRoute == '/ytSearch' &&
          // the route carries its query string: /ytSearchResult?keyword=…
          resultRoute?.startsWith('/ytSearchResult') == true &&
          cards > 0 &&
          historyChip,
      'pressed': pressed,
      'searchRoute': searchRoute,
      'resultRoute': resultRoute,
      'cards': cards,
      'historyChip': historyChip,
    };
  }

  /// LibrePili: does the search button search the platform that is showing?
  ///
  /// It did not. Three buttons open search — the home bar, the wide
  /// window's side rail and 我的 — and only the first one was ever wired to
  /// the platform, so switching to YouTube and pressing the search next to
  /// the switcher silently opened bilibili's. This asserts on the route the
  /// press actually lands on, which is the thing that was wrong.
  static Future<Map<String, dynamic>> _platformSearch() async {
    final platform = PlatformService.to;
    final before = platform.mode.value;

    Future<String?> pressSearch() async {
      // the rail's button carries the tooltip; the home bar is an InkWell
      // whose icon carries the label
      final pressed =
          await _tapTooltip('搜索') ||
          await _tap(
            (e) => e.widget is Icon && (e.widget as Icon).semanticLabel == '搜索',
          );
      if (!pressed) return null;
      await Future.delayed(const Duration(milliseconds: 600));
      return Get.currentRoute;
    }

    await platform.set(PlatformMode.youtube);
    await Future.delayed(const Duration(seconds: 1));
    final youtubeRoute = await pressSearch();
    if (youtubeRoute != null) {
      Get.back();
      await Future.delayed(const Duration(milliseconds: 600));
    }

    await platform.set(PlatformMode.bilibili);
    await Future.delayed(const Duration(seconds: 1));
    final bilibiliRoute = await pressSearch();
    if (bilibiliRoute != null) {
      Get.back();
      await Future.delayed(const Duration(milliseconds: 600));
    }

    // 全部 has no single search, so the press must ask rather than pick
    await platform.set(PlatformMode.all);
    await Future.delayed(const Duration(seconds: 1));
    await pressSearch();
    final allAsks = _seesText('B 站') && _seesText('YouTube');
    if (allAsks) {
      Get.back();
      await Future.delayed(const Duration(milliseconds: 600));
    }

    await platform.set(before);
    return {
      'pass':
          youtubeRoute == '/ytSearch' &&
          bilibiliRoute == '/search' &&
          allAsks,
      'youtubeRoute': youtubeRoute,
      'bilibiliRoute': bilibiliRoute,
      'allAsks': allAsks,
    };
  }

  /// LibrePili: can we list a channel's uploads? Subscriptions depend on it,
  /// and stage 1 never parsed a channel page — so this asks before any UI is
  /// built on the assumption.
  static Future<Map<String, dynamic>> _youtubeChannel(String channelId) async {
    final source = YtDirectSource.create();
    final router = YtSourceRouter(source);
    final result = await router.run(
      (s) => (s as YtDirectSource).channelPage(channelId),
    );
    if (!result.ok || result.value == null) {
      return {'pass': false, 'verdict': result.verdict.toString()};
    }
    final page = result.value!;
    final info = page.info;
    return {
      // the header is what the video response cannot give us
      'pass': page.videos.items.isNotEmpty && info != null,
      'channelId': channelId,
      'items': page.videos.items.length,
      'hasContinuation': page.videos.continuation != null,
      // 'name' is the framework's key for the scenario; do not collide
      'channelName': info?.name,
      'avatar': info?.avatar?.url != null,
      'subscribers': info?.subscriberText,
      'videoCount': info?.videoCountText,
      'first': page.videos.items.isEmpty
          ? null
          : '${page.videos.items.first.title} / ${page.videos.items.first.author}',
    };
  }

  /// LibrePili: switch to the YouTube platform, search, open a result.
  ///
  /// The loop a user actually walks: without this, "search works" and "a
  /// video plays" were two separate claims with nothing joining them.
  static Future<Map<String, dynamic>> _youtubeSearch(String query) async {
    final platform = PlatformService.to;
    final before = platform.mode.value;
    await platform.set(PlatformMode.youtube);
    await Future.delayed(const Duration(seconds: 2));

    final source = YtDirectSource.create();
    final router = YtSourceRouter(source);
    final result = await router.run(
      (s) => (s as YtDirectSource).search(query),
    );
    final items = result.value?.items ?? const <YtSearchItem>[];

    String? openedTitle;
    var played = false;
    var relatedCount = 0;
    var commentCount = 0;
    var channelUploads = 0;
    var subscribeToggled = false;
    var threadsWithReplies = 0;
    String? publishedDate;
    String? exactViews;
    String? subscribers;
    var replyCount = 0;
    var repliesShown = false;
    var visibleComments = 0;
    var anyReplyButton = false;
    var commentsTabOpened = false;
    var commentsAutoLoaded = false;
    var previewEntries = 0;
    var previewNonEmpty = 0;
    String? firstReply;
    // did the panels the user complained about actually open?
    var settingsSheet = false;
    var subtitlePanel = false;
    var captionMenu = false;
    var speedMenu = false;
    var afterSubtitleTap = const <String>[];
    String? firstComment;
    String? openedStage;
    int? openedBuffer;
    bool? openedLive;
    if (items.isNotEmpty) {
      final first = items.first;
      unawaited(
        Get.toNamed('/ytVideo', parameters: {'id': first.videoId}),
      );
      await Future.delayed(const Duration(seconds: 6));
      final controller = Get.find<YtVideoController>(tag: first.videoId);
      for (var i = 0; i < 15 && controller.stage.value != .ready; i++) {
        await Future.delayed(const Duration(seconds: 1));
      }
      openedTitle = controller.detail.value?.title;
      openedStage = controller.stage.value.name;
      openedLive = controller.detail.value?.isLive;

      // the rest of the page: related shelf, comments, and a subscription
      await Future.delayed(const Duration(seconds: 3));
      relatedCount = controller.related.length;
      // comments now start with the video, so they must already be here
      // without anything having opened the tab
      commentsAutoLoaded = controller.comments.isNotEmpty;
      // the publish date and the exact view count arrive with the related
      // shelf now, in place of the channel request that used to fetch the
      // avatar on its own
      publishedDate = controller.extra.value?.dateText;
      exactViews = controller.extra.value?.viewCountText;
      subscribers = controller.extra.value?.subscriberText;
      for (var i = 0; i < 10 && controller.comments.isEmpty; i++) {
        await Future.delayed(const Duration(seconds: 1));
      }
      commentCount = controller.comments.length;
      firstComment = controller.comments.isEmpty
          ? null
          : controller.comments.first.author;

      // replies: a thread the page says has some, opened the way the button
      // opens it. The count in the UI can be 0 (YouTube abbreviates it), so
      // the thread is picked by having a token, not by the number.
      // open the tab first: loading comments and showing them are different
      // things, and the first version of this asserted on a list that was
      // never on screen (visibleComments read 0 while replyCount read 9)
      commentsTabOpened = await _tapText('评论');
      await Future.delayed(const Duration(milliseconds: 800));

      final thread = controller.comments.firstWhereOrNull((c) => c.hasReplies);
      threadsWithReplies = controller.comments
          .where((c) => c.hasReplies)
          .length;
      if (thread != null) {
        // nothing is toggled: the preview is fetched by the row being built,
        // so this only waits for it to arrive and render
        for (var i = 0; i < 12; i++) {
          await Future.delayed(const Duration(seconds: 1));
          replyCount = controller.replies[thread.commentId]?.length ?? 0;
          if (replyCount > 0) break;
        }
        await Future.delayed(const Duration(milliseconds: 800));
        // If nothing of the comment list is on screen the tab was never
        // shown, which is a different failure from "the thread is below the
        // fold" and from "the preview rendered empty".
        visibleComments = controller.comments
            .where((c) => _seesText(c.author))
            .length;
        anyReplyButton =
            _findElement(
              (e) =>
                  e.widget is Text &&
                  _textOf(e.widget as Text).contains('条回复'),
            ) !=
            null;
        // entries vs non-empty entries: "no request was made" and "the
        // request came back with nothing" look the same in replyCount alone
        previewEntries = controller.replies.length;
        previewNonEmpty = controller.replies.values
            .where((v) => v.isNotEmpty)
            .length;
        final first = controller.replies[thread.commentId]?.firstOrNull;
        firstReply = first == null
            ? null
            : '${first.author}: ${first.content.length > 30 ? '${first.content.substring(0, 30)}…' : first.content}';
        // the preview block itself: a reply's author on screen, not just the
        // count row, which would render even if the block came up empty
        // the author of a reply appears inside the preview's rich text, so
        // this only finds it if the block itself rendered with content
        repliesShown =
            first != null &&
            _findElement(
                  (e) =>
                      e.widget is Text &&
                      _textOf(e.widget as Text).startsWith(first.author),
                ) !=
                null;
      }

      final wasSubscribed = controller.subscribed.value;
      await controller.toggleSubscribe();
      subscribeToggled = controller.subscribed.value != wasSubscribed;
      final channelId = controller.detail.value?.channelId;
      if (subscribeToggled && channelId != null) {
        // and the feed that the subscription feeds into
        final uploads = await router.run(
          (s) => (s as YtDirectSource).channelVideos(channelId),
        );
        channelUploads = uploads.value?.items.length ?? 0;
        await controller.toggleSubscribe();
      }
      final player = controller.plPlayerController;
      await player.play();
      // a first result that is long or slow to start is not a failure of the
      // page: give it a few rounds before calling it one
      for (var round = 0; round < 4 && !played; round++) {
        final before = player.videoPlayerController?.state.position;
        await Future.delayed(const Duration(seconds: 4));
        final after = player.videoPlayerController?.state.position;
        played = before != null && after != null && after > before;
        openedBuffer = player.videoPlayerController?.state.buffer.inMilliseconds;
      }
      // the panels, opened the way a user opens them. Rendering the page is
      // not the same as rendering what the buttons on it lead to.
      player.showControls.value = true;
      await Future.delayed(const Duration(milliseconds: 700));
      if (await _tapTooltip('更多设置')) {
        settingsSheet = _seesText('字幕设置');
        if (settingsSheet && await _tapText('字幕设置')) {
          // that entry closes the sheet and opens the subtitle panel, so a
          // label only that panel carries is what proves it is the one up —
          // and one near its top: the list is lazy, so a row further down
          // ('底部边距') is simply never built and reads as a failure.
          subtitlePanel = _seesLabel('字体大小') && !_seesText('超分辨率');
          if (!subtitlePanel) afterSubtitleTap = _visibleTexts().take(24).toList();
        }
        // closes whichever of the two is open
        Get.back();
        await Future.delayed(const Duration(milliseconds: 700));
      }
      player.showControls.value = true;
      await Future.delayed(const Duration(milliseconds: 700));
      if (await _tapTooltip('字幕')) {
        captionMenu = _seesText('关闭字幕');
        if (captionMenu) {
          Get.back();
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      player.showControls.value = true;
      await Future.delayed(const Duration(milliseconds: 700));
      if (await _tapTooltip('倍速')) {
        speedMenu = _seesText('2.0X');
        if (speedMenu) {
          Get.back();
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }

      Get.back();
      await Future.delayed(const Duration(seconds: 2));
    }

    await platform.set(before);
    return {
      'pass':
          items.isNotEmpty &&
          played &&
          relatedCount > 0 &&
          publishedDate != null &&
          subscribers != null &&
          commentCount > 0 &&
          subscribeToggled &&
          channelUploads > 0 &&
          replyCount > 0 &&
          repliesShown &&
          anyReplyButton &&
          commentsAutoLoaded &&
          settingsSheet &&
          subtitlePanel &&
          captionMenu &&
          speedMenu,
      'mode': platform.mode.value.name,
      'query': query,
      'results': items.length,
      'firstTitle': items.isEmpty ? null : items.first.title,
      'hasContinuation': result.value?.continuation != null,
      'openedTitle': openedTitle,
      'played': played,
      'stage': openedStage,
      'buffer': openedBuffer,
      'isLive': openedLive,
      'related': relatedCount,
      'publishedDate': publishedDate,
      'exactViews': exactViews,
      'subscribers': subscribers,
      'comments': commentCount,
      'firstComment': firstComment,
      'threadsWithReplies': threadsWithReplies,
      'replyCount': replyCount,
      'repliesShown': repliesShown,
      'visibleComments': visibleComments,
      'anyReplyButton': anyReplyButton,
      'commentsTabOpened': commentsTabOpened,
      'commentsAutoLoaded': commentsAutoLoaded,
      'previewEntries': previewEntries,
      'previewNonEmpty': previewNonEmpty,
      'firstReply': firstReply,
      'subscribeToggled': subscribeToggled,
      'settingsSheet': settingsSheet,
      'subtitlePanel': subtitlePanel,
      'captionMenu': captionMenu,
      'speedMenu': speedMenu,
      'afterSubtitleTap': afterSubtitleTap,
      'channelUploads': channelUploads,
      'verdict': result.verdict.toString(),
    };
  }

  /// LibrePili: opens the YouTube watch page for real and reports whether the
  /// player actually advanced — resolving a URL is not the same as playing it.
  static Future<Map<String, dynamic>> _openYouTube(
    String input,
    int holdSeconds,
  ) async {
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    // NOT awaited: Get.toNamed completes when the page is popped
    unawaited(Get.toNamed('/ytVideo', parameters: {'id': videoId}));
    await Future.delayed(const Duration(seconds: 4));

    final controller = Get.find<YtVideoController>(tag: videoId);
    for (var i = 0; i < holdSeconds && controller.stage.value != .ready; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    final player = controller.plPlayerController;
    // autoplay is a user setting; the probe presses play itself so a paused
    // preference cannot be mistaken for a stream that will not run
    await player.play();
    await Future.delayed(const Duration(seconds: 2));
    final first = player.videoPlayerController?.state.position;
    await Future.delayed(Duration(seconds: holdSeconds));
    final second = player.videoPlayerController?.state.position;

    // captions are the half that the Invidious route could never deliver
    var captionOk = false;
    if (controller.captions.isNotEmpty) {
      await controller.setCaption(0);
      captionOk = controller.captionIndex.value == 0;
    }

    final advanced =
        first != null && second != null && second > first + const Duration(seconds: 1);

    // leaving the page must stop playback: audio that keeps running after the
    // user has navigated away is the worst kind of "it works"
    Get.back();
    await Future.delayed(const Duration(seconds: 3));
    final afterBack = player.videoPlayerController?.state.position;
    await Future.delayed(const Duration(seconds: 3));
    final afterBack2 = player.videoPlayerController?.state.position;
    final stopped =
        player.videoPlayerController == null ||
        (afterBack != null && afterBack2 != null && afterBack2 == afterBack);

    return {
      'pass': controller.stage.value == YtPageStage.ready && advanced && stopped,
      'stage': controller.stage.value.name,
      'message': controller.message.value,
      'title': controller.detail.value?.title,
      'positionBefore': first?.inMilliseconds,
      'positionAfter': second?.inMilliseconds,
      'advanced': advanced,
      'buffer': player.videoPlayerController?.state.buffer.inMilliseconds,
      'captionTracks': controller.captions.length,
      'captionShown': captionOk,
      'via': controller.streams?.sourceId,
      'stoppedOnLeave': stopped,
      'positionAfterBack': afterBack?.inMilliseconds,
      'positionAfterBack2': afterBack2?.inMilliseconds,
    };
  }

  /// LibrePili: drives the YouTube data layer against the live service.
  ///
  /// The client identities in `yt_identity.dart` are documented as rotting:
  /// the offline fixture tests cannot notice when YouTube changes its mind,
  /// so this asks the real thing before the layer is wired to the player.
  static Future<Map<String, dynamic>> _youtube(String input) async {
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    final source = YtDirectSource.create();
    final router = YtSourceRouter(source);
    final result = <String, dynamic>{'videoId': videoId};
    try {
      final detail = await router.run((s) => s.detail(videoId));
      result['detailOk'] = detail.ok;
      result['detailVerdict'] = detail.verdict.toString();
      if (detail.value case final d?) {
        result
          ..['title'] = d.title
          ..['author'] = d.author
          ..['durationSec'] = d.duration.inSeconds
          ..['formats'] = d.formats.length
          ..['captionTracks'] = [
            for (final c in d.captionTracks) c.languageCode,
          ]
          ..['isLive'] = d.isLive;
      }

      final streams = await router.run((s) => s.streams(videoId));
      result['streamsOk'] = streams.ok;
      result['streamsVerdict'] = streams.verdict.toString();
      if (streams.value case final pair?) {
        result
          ..['via'] = pair.sourceId
          ..['expiresInMin'] = pair.expiresIn.inMinutes
          ..['videoHost'] = Uri.tryParse(pair.videoUrl)?.host
          ..['audioHost'] = Uri.tryParse(pair.audioUrl)?.host
          ..['videoItag'] = pair.video?.itag
          ..['audioItag'] = pair.audio?.itag
          ..['edlLength'] = pair.edl.length;
        // the streams are only useful if they actually serve bytes
        result['videoServes'] = await _headOk(pair.videoUrl);
        result['audioServes'] = await _headOk(pair.audioUrl);
        // the player carries bilibili's Referer/UA globally; googlevideo has
        // to tolerate them or the YouTube path needs per-source headers
        result['videoServesWithBiliHeaders'] = await _headOk(
          pair.videoUrl,
          referer: HttpString.baseUrl,
          userAgent: BrowserUa.pc,
        );
      }

      final captions = await router.run((s) => s.captionTracks(videoId));
      result['captionsOk'] = captions.ok;
      if (captions.value case final tracks? when tracks.isNotEmpty) {
        final content = await router.run(
          (s) => s.captionContent(tracks.first),
        );
        result
          ..['captionLang'] = tracks.first.languageCode
          ..['captionOk'] = content.ok
          ..['captionBytes'] = content.value?.length ?? 0;
      }
      result['pass'] =
          detail.ok &&
          streams.ok &&
          result['videoServes'] == true &&
          result['audioServes'] == true;
    } catch (e, stack) {
      result
        ..['pass'] = false
        ..['error'] = '$e'
        ..['stack'] = '$stack';
    }
    return result;
  }

  /// A range request for the first bytes: a signed URL that parses but does
  /// not serve is the failure worth catching here.
  static Future<bool> _headOk(
    String url, {
    String? referer,
    String? userAgent,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    if (userAgent != null) client.userAgent = userAgent;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1024');
      if (referer != null) {
        request.headers.set(HttpHeaders.refererHeader, referer);
      }
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 206 || response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// LibrePili: what the player can actually tell us about how the stream is
  /// arriving, sampled once a second against a real source.
  ///
  /// Automatic quality switching needs a health signal; this reports which
  /// mpv properties exist in media_kit's build and how they move, so the
  /// policy is written against measurements instead of assumptions.
  static Future<Map<String, dynamic>> _probePlayback(
    String url,
    int seconds,
  ) async {
    const names = [
      'cache-speed',
      'demuxer-cache-time',
      'demuxer-cache-duration',
      'paused-for-cache',
      'video-bitrate',
      'audio-bitrate',
    ];
    final player = await Player.create(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error),
    );
    final native = player;
    final samples = <Map<String, dynamic>>[];
    try {
      native
        ..setProperty('cache', 'yes')
        ..setProperty('cache-secs', '16');
      player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);
      await player.open(Media(url));
      for (var i = 0; i < seconds; i++) {
        await Future.delayed(const Duration(seconds: 1));
        samples.add({
          'at': i + 1,
          'position': player.state.position.inMilliseconds,
          'buffer': player.state.buffer.inMilliseconds,
          'buffering': player.state.buffering,
          for (final name in names) name: native.getProperty(name),
        });
      }
    } finally {
      await player.dispose();
    }

    final available = <String>[];
    final missing = <String>[];
    for (final name in names) {
      final any = samples.any(
        (s) => (s[name] as String?)?.isNotEmpty ?? false,
      );
      (any ? available : missing).add(name);
    }
    return {
      'pass': samples.isNotEmpty && available.isNotEmpty,
      'available': available,
      'missing': missing,
      'samples': samples,
    };
  }

  /// LibrePili: fetches the recogniser's models for real, against the real
  /// URLs, into a throwaway directory — the one part of the pipeline whose
  /// failure modes (a dead mirror, a renamed release asset, a tarball whose
  /// member paths moved) only show up against the live internet.
  static Future<Map<String, dynamic>> _asrDownload(String dir) async {
    final store = AsrModelStore(root: Directory(dir));
    final started = DateTime.now();
    var lastLabel = '';
    final steps = <String>[];
    await store.ensureAll(
      onProgress: (p) {
        if (p.label != lastLabel) {
          lastLabel = p.label;
          steps.add(p.label);
        }
      },
    );
    final ms = DateTime.now().difference(started).inMilliseconds;
    return {
      'pass': store.isReady,
      'ms': ms,
      'bytes': store.installedBytes(),
      'steps': steps,
      'files': [
        for (final model in AsrModelCatalog.required)
          for (final file in model.files)
            {
              'name': file.name,
              'size': store.fileOf(model, file).existsSync()
                  ? store.fileOf(model, file).lengthSync()
                  : 0,
              'expected': file.size,
            },
      ],
    };
  }

  /// LibrePili: end-to-end on-device transcription over a real file or URL —
  /// libmpv audio extraction, Silero VAD, SenseVoice — with the timings the
  /// benchmarks are compared against.
  static Future<Map<String, dynamic>> _asr(
    String source, {
    String? modelDir,
    String? srtOut,
    String? pcmOut,
  }) async {
    final store = AsrModelStore(
      root: modelDir == null ? null : Directory(modelDir),
    );
    if (!store.isReady) {
      return {
        'pass': false,
        'error': 'models missing under ${store.root.path}',
        'missing': [for (final m in store.missing) m.id],
      };
    }

    final pcm = pcmOut ?? path.join(tmpDirPath, 'asr', 'selftest.pcm');
    final extractStarted = DateTime.now();
    final audio = await AsrAudioExtractor.extract(
      source: source,
      output: pcm,
      referer: HttpString.baseUrl,
      userAgent: BrowserUa.pc,
    );
    final extractMs = DateTime.now().difference(extractStarted).inMilliseconds;

    final transcribeStarted = DateTime.now();
    final cues = <AsrCue>[];
    String? language;
    String? error;
    final transcriber = await AsrTranscriber.start((
      pcmPath: audio.path,
      modelPath: store
          .fileOf(
            AsrModelCatalog.senseVoice,
            AsrModelCatalog.senseVoice.files[0],
          )
          .path,
      tokensPath: store
          .fileOf(
            AsrModelCatalog.senseVoice,
            AsrModelCatalog.senseVoice.files[1],
          )
          .path,
      vadPath: store
          .fileOf(AsrModelCatalog.vad, AsrModelCatalog.vad.files.first)
          .path,
      threads: Pref.asrThreads,
      language: '',
    ));
    await for (final event in transcriber.events) {
      switch (event) {
        case AsrCuesEvent(cues: final batch):
          cues.addAll(batch);
        case AsrLanguageEvent(language: final lang):
          language ??= lang;
        case AsrErrorEvent(message: final message):
          error = message;
        case AsrProgressUpdate():
          break;
      }
    }
    final transcribeMs = DateTime.now()
        .difference(transcribeStarted)
        .inMilliseconds;
    if (srtOut != null && cues.isNotEmpty) {
      await File(srtOut).writeAsString(cues.toSrt());
    }
    if (pcmOut == null) {
      try {
        await File(pcm).delete();
      } catch (_) {}
    }

    return {
      'pass': error == null && cues.isNotEmpty,
      'error': ?error,
      'source': source,
      'audioSeconds': audio.durationSeconds,
      'extractMs': extractMs,
      'transcribeMs': transcribeMs,
      'rtf': audio.durationSeconds == 0
          ? null
          : (extractMs + transcribeMs) / 1000 / audio.durationSeconds,
      'language': language,
      'cueCount': cues.length,
      'cues': [
        for (final cue in cues.take(40))
          {
            'from': cue.from,
            'to': cue.to,
            'content': cue.content,
          },
      ],
    };
  }

  /// Opens a video file / folder with the local player, optionally starts
  /// playback, and reports position, duration and loaded danmaku.
  static Future<Map<String, dynamic>> _openLocal(
    String target,
    int hold, {
    required bool play,
  }) async {
    const heroTag = 'selftest_local';
    PlDanmakuController.lastLoadedCount = -1;
    unawaited(LocalPlayer.open(target, heroTag: heroTag));
    await Future.delayed(const Duration(seconds: 6));
    // read only: getInstance() would raise the player count
    final player = PlPlayerController.instance;
    if (play) {
      // same steps as tapping play on the page (handlePlay)
      final ctr = Get.find<VideoDetailController>(tag: heroTag)
        ..autoPlay = true;
      await ctr.playerInit(autoplay: true);
    }
    await Future.delayed(Duration(seconds: hold));
    final pos = player?.positionInMilliseconds ?? 0;
    return {
      'pass': !play || pos > 0,
      'positionMs': pos,
      // no player (nothing playing): 0, the scripted checks read these as
      // numbers
      'durationMs': player?.durationInMilliseconds ?? 0,
      'danmakuLoaded': PlDanmakuController.lastLoadedCount,
    };
  }

  /// Opens the newest completed download (merged file present) in the
  /// offline player and keeps it on screen for [hold] seconds, so a caller
  /// can screenshot it. Reports which folder extras it should pick up.
  static Future<Map<String, dynamic>> _openOffline(
    int hold, {
    int? tab,
    bool play = false,
  }) async {
    const heroTag = 'selftest_offline';
    final service = Get.find<DownloadService>();
    await service.waitForInitialization;
    final entry = service.downloadList.firstWhereOrNull(
      (e) => e.mergedPath != null && File(e.mergedPath!).existsSync(),
    );
    if (entry == null) {
      return {
        'pass': false,
        'error': 'no completed download with a video file',
      };
    }
    final merged = entry.mergedPath!;
    final folder = Directory(path.dirname(merged));
    final base = path.basenameWithoutExtension(merged);
    final extras = [
      for (final f in folder.listSync().whereType<File>())
        if (path.basename(f.path).startsWith('$base.') &&
            !f.path.endsWith('.mp4'))
          path.basename(f.path).substring(base.length),
    ];
    unawaited(
      PageUtils.toVideoPage(
        aid: entry.avid,
        cid: entry.cid,
        cover: entry.cover,
        title: entry.showTitle,
        isVertical: entry.pageData?.isVertical ?? false,
        extraArguments: {
          'sourceType': SourceType.file,
          'entry': entry,
          'dirPath': entry.entryDirPath,
          'heroTag': heroTag,
        },
      ),
    );
    PlDanmakuController.lastLoadedCount = -1;
    if (play) {
      await Future.delayed(const Duration(seconds: 5));
      final ctr = Get.find<VideoDetailController>(tag: heroTag)
        ..autoPlay = true;
      await ctr.playerInit(autoplay: true);
    }
    String? tabs;
    if (tab != null) {
      await Future.delayed(const Duration(seconds: 5));
      final ctr = Get.find<VideoDetailController>(tag: heroTag);
      tabs = 'tabs=${ctr.tabCtr.length}, showReply=${ctr.showReply}';
      if (tab < ctr.tabCtr.length) ctr.tabCtr.animateTo(tab);
    }
    await Future.delayed(Duration(seconds: hold));
    // read only: getInstance() would raise the player count
    final player = PlPlayerController.instance;
    final detail = Get.find<VideoDetailController>(tag: heroTag);
    return {
      'pass': true,
      'title': entry.showTitle,
      'subtitles': [for (final s in detail.subtitles) s.lan],
      'subtitleIndex': detail.vttSubtitlesIndex.value,
      'extras': extras,
      'tabs': ?tabs,
      if (play) ...{
        'positionMs': player?.positionInMilliseconds ?? 0,
        'durationMs': player?.durationInMilliseconds ?? 0,
        'danmakuLoaded': PlDanmakuController.lastLoadedCount,
      },
    };
  }

  /// Diagnoses the local feed: the web API it uses (searchArchive, WBI) vs
  /// the app API (spaceArchive, app-signed), both anonymous.
  static Future<Map<String, dynamic>> _feed(int mid) async {
    final web = await MemberHttp.searchArchive(mid: mid, pn: 1, ps: 10);
    final app = await MemberHttp.spaceArchive(
      type: ContributeType.video,
      mid: mid,
    );
    final webOk = web is Success<SearchArchiveData>;
    final appOk = app is Success<SpaceArchiveData>;
    return {
      'pass': webOk,
      'mid': mid,
      'web_searchArchive': webOk
          ? 'ok, ${web.response.list?.vlist?.length ?? 0} items'
          : '$web',
      'app_spaceArchive': appOk
          ? 'ok, ${app.response.item?.length ?? 0} items'
          : '$app',
      if (appOk && (app.response.item?.isNotEmpty ?? false))
        'app_first_item': {
          'title': app.response.item!.first.title,
          'bvid': app.response.item!.first.bvid,
          'param': app.response.item!.first.param,
          'ctime': app.response.item!.first.ctime,
          'duration': app.response.item!.first.duration,
        },
    };
  }

  static Future<Map<String, dynamic>> _localLibrary() async {
    const mid = 999999999999; // not a real UP, never collides with user data
    const key = 'av999999999999';
    final steps = <String, bool>{};
    void expect(String step, bool cond) => steps[step] = cond;

    final data = LocalLibrary.buildFavData(
      aid: 999999999999,
      bvid: 'BV_selftest',
      title: 'selftest item',
      durationSec: 3725,
      pubdate: 1700000000,
      mid: mid,
      author: 'selftest',
    );
    try {
      expect('notFollowedInitially', !LocalLibrary.isFollowed(mid));
      expect('followReturnsTrue', await LocalLibrary.toggleFollow(mid));
      expect('isFollowed', LocalLibrary.isFollowed(mid));
      await LocalLibrary.updateFollowInfo(mid, name: 'renamed');
      expect(
        'followInfoUpdated',
        LocalLibrary.followList().any(
          (f) => f.mid == mid && f.name == 'renamed',
        ),
      );
      expect('unfollowReturnsFalse', !await LocalLibrary.toggleFollow(mid));
      expect('notFollowedAfter', !LocalLibrary.isFollowed(mid));

      final folder = await LocalLibrary.createFolder('selftest folder');
      expect(
        'folderCreated',
        LocalLibrary.folders().any((f) => f.id == folder.id),
      );
      await LocalLibrary.renameFolder(folder.id, 'selftest renamed');
      expect(
        'folderRenamed',
        LocalLibrary.folders().any(
          (f) => f.id == folder.id && f.title == 'selftest renamed',
        ),
      );
      final ids = [for (final f in LocalLibrary.folders()) f.id];
      await LocalLibrary.reorderFolders([
        folder.id,
        ...ids.where((e) => e != folder.id),
      ]);
      expect('folderReordered', LocalLibrary.folders().first.id == folder.id);
      await LocalLibrary.reorderFolders(ids); // restore user order

      await LocalLibrary.setFolders(key, data, {folder.id});
      expect('favAdded', LocalLibrary.isFav(key));
      expect('favInFolder', LocalLibrary.folderCount(folder.id) == 1);
      final item = LocalLibrary.folderItems(folder.id).single.toVideoItem();
      expect('favItemTitle', item.title == 'selftest item');
      expect('favItemDuration', item.duration == 3725);
      expect('favItemPubdate', item.pubdate == 1700000000);

      await LocalLibrary.deleteFolder(folder.id);
      expect(
        'folderDeleted',
        !LocalLibrary.folders().any((f) => f.id == folder.id),
      );
      expect('favRemovedWithFolder', !LocalLibrary.isFav(key));
      expect(
        'defaultFolderKept',
        LocalLibrary.folders().any((f) => f.id == LocalLibrary.defaultFolderId),
      );
    } finally {
      // never leave test data behind
      await LocalLibrary.unfollow(mid);
      await LocalLibrary.setFolders(key, data, {});
      for (final f in LocalLibrary.folders()) {
        if (f.title.startsWith('selftest')) {
          await LocalLibrary.deleteFolder(f.id);
        }
      }
    }
    return {'pass': steps.values.every((e) => e), 'steps': steps};
  }

  static Future<Map<String, dynamic>> _download(
    String bvid,
    int qn, {
    required bool keep,
  }) async {
    final service = Get.find<DownloadService>();
    await service.waitForInitialization;

    // `hot`: first video of the current popular list, so the test does not
    // depend on one video staying online
    if (bvid == 'hot') {
      final hot = await VideoHttp.hotVideoList(pn: 1, ps: 10);
      final picked = hot is Success<List<HotVideoItemModel>>
          ? hot.response.firstWhereOrNull((e) => e.bvid != null)?.bvid
          : null;
      if (picked == null) {
        return {'pass': false, 'error': 'hot list failed: $hot'};
      }
      bvid = picked;
    }
    final res = await VideoHttp.videoIntro(bvid: bvid);
    if (res is! Success<VideoDetailData>) {
      return {'pass': false, 'error': 'videoIntro failed: $res'};
    }
    final detail = res.response;
    final page = detail.pages!.first;
    final cid = page.cid!;

    // start from a clean state
    for (final e in [...service.downloadList, ...service.waitDownloadQueue]) {
      if (e.cid == cid) {
        await service.deleteDownload(
          entry: e,
          removeList: true,
          removeQueue: true,
          deleteExported: true,
        );
      }
    }

    final quality = VideoQuality.fromCode(qn);
    service.downloadVideo(page, detail, null, quality);

    final statuses = <String>[];
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    BiliDownloadEntryInfo? done;
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 500));
      final cur = service.curDownload.value;
      if (cur != null && cur.cid == cid) {
        final s = cur.status.name;
        if (statuses.isEmpty || statuses.last != s) statuses.add(s);
        if (s.startsWith('fail')) {
          return {
            'pass': false,
            'error': 'download status $s: ${service.lastError}',
            'statuses': statuses,
          };
        }
      }
      done = service.downloadList.firstWhereOrNull((e) => e.cid == cid);
      if (done != null) break;
    }
    if (done == null) {
      return {'pass': false, 'error': 'timeout', 'statuses': statuses};
    }

    // extras run after completion: let them finish so the folder report
    // includes them (deleting below would cancel them anyway)
    await service
        .extrasDone(cid)
        ?.timeout(const Duration(minutes: 5), onTimeout: () {});
    final merged = done.mergedPath;
    final mergedFile = merged == null ? null : File(merged);
    final streamDir = path.join(done.entryDirPath, done.streamTypeTag);
    final leftovers = [
      PathUtils.videoNameType2,
      PathUtils.audioNameType2,
      PathUtils.videoNameType1,
    ].where((n) => File(path.join(streamDir, n)).existsSync()).toList();
    final entryJson = File(path.join(done.entryDirPath, 'entry.json'));
    final savedMergedPath = entryJson.existsSync()
        ? (jsonDecode(await entryJson.readAsString()) as Map)['merged_path']
        : null;

    final result = <String, dynamic>{
      'bvid': bvid,
      'cid': cid,
      'quality': done.qualityPithyDescription,
      'statuses': statuses,
      'mergedPath': merged,
      'mergedExists': mergedFile?.existsSync() ?? false,
      'mergedBytes': mergedFile?.existsSync() == true
          ? mergedFile!.lengthSync()
          : 0,
      'downloadedBytes': done.totalBytes,
      'streamLeftovers': leftovers,
      'entryJsonMergedPath': savedMergedPath,
      'entryDir': done.entryDirPath,
      // per-video folder contents (video + danmaku / subtitles / comments)
      if (merged != null)
        'folderFiles': {
          for (final f in Directory(path.dirname(merged)).listSync())
            if (f is File) path.basename(f.path): f.lengthSync(),
        },
    };
    result['pass'] =
        merged != null &&
        result['mergedExists'] == true &&
        (result['mergedBytes'] as int) > 0 &&
        leftovers.isEmpty &&
        savedMergedPath == merged;

    if (!keep) {
      await service.deleteDownload(
        entry: done,
        removeList: true,
        deleteExported: true,
      );
      result['cleanedUp'] = !(mergedFile?.existsSync() ?? false);
    }
    return result;
  }
}
