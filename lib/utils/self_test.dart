import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui show ImageByteFormat;

import 'package:PiliPlus/common/widgets/dialog/failure_report.dart';
import 'package:PiliPlus/common/widgets/dialog/qr_share.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/mine/view.dart';
import 'package:PiliPlus/pages/rcmd/controller.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart'
    show SubtitleType;
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/pages/scan/view.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show Content, Emote, ReplyInfo;
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/services/translate/comment_translator.dart';
import 'package:PiliPlus/common/widgets/comments/comment_translation.dart';
import 'package:PiliPlus/models/common/comment_translation_display.dart';
import 'package:PiliPlus/services/translate/text_language.dart';
import 'package:PiliPlus/utils/wbi_sign.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/subtitle_source_preference.dart';
import 'package:PiliPlus/models/common/member/contribute_type.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/pages/member_contribute/controller.dart';
import 'package:PiliPlus/pages/member_contribute/view.dart';
import 'package:PiliPlus/pages/member_video/view.dart';
import 'package:PiliPlus/models/common/subtitle_source.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/member/search_archive/data.dart';
import 'package:PiliPlus/models_new/space/space_archive/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart'
    as bili_sub;
import 'package:PiliPlus/pages/danmaku/controller.dart';
import 'package:PiliPlus/pages/danmaku/view.dart' show PlDanmaku;
import 'package:canvas_danmaku/canvas_danmaku.dart' show DanmakuScreen;
import 'package:PiliPlus/common/widgets/video_card/video_card_h.dart';
import 'package:PiliPlus/pages/local/favs.dart';
import 'package:PiliPlus/pages/local/feed.dart';
import 'package:PiliPlus/pages/local/view.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/youtube/search/controller.dart';
import 'package:PiliPlus/pages/youtube/video/controller.dart';
import 'package:PiliPlus/pages/youtube/channel/controller.dart';
import 'package:PiliPlus/pages/youtube/channel/widgets/post_card.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/services/debug_overlay.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/pages/history/local.dart';
import 'package:PiliPlus/services/local_history.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:PiliPlus/services/background_transfer.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/ctl/ctl_app.dart';
import 'package:PiliPlus/services/local_player.dart';
import 'package:PiliPlus/pages/video/widgets/on_device_menu.dart';
import 'package:PiliPlus/pages/video/widgets/asr_entry.dart';
import 'package:PiliPlus/pages/setting/pages/local_models.dart';
import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/models/common/platform_mode.dart';
import 'package:PiliPlus/models/common/setting_type.dart';
import 'package:PiliPlus/services/platform_service.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_download.dart';
import 'package:PiliPlus/services/asr/audio_extract.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/asr_schedule.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/services/model_bench/bench_advice.dart';
import 'package:PiliPlus/services/model_bench/model_bench.dart';
import 'package:PiliPlus/services/asr/transcriber.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:media_kit/media_kit.dart';
import 'package:PiliPlus/utils/font_utils.dart';
import 'package:PiliPlus/utils/soft_decode.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_choice.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:PiliPlus/utils/codec_support.dart';
import 'package:PiliPlus/services/translate/translation_languages.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/settings_import.dart';
import 'package:PiliPlus/utils/self_test_window.dart';
import 'package:PiliPlus/utils/subtitle_utils.dart';
import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerAddedEvent,
        PointerDeviceKind,
        PointerDownEvent,
        PointerHoverEvent,
        PointerScrollEvent,
        PointerUpEvent;
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter/services.dart'
    show
        KeyDownEvent,
        KeyMessage,
        KeyRepeatEvent,
        KeyUpEvent,
        LogicalKeyboardKey,
        PhysicalKeyboardKey,
        ServicesBinding;
import 'package:flutter/rendering.dart' show OffsetLayer;
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart'
    show SmartDialog;
import 'package:material_ui/material_ui.dart'
    show
        AlertDialog,
        AppBar,
        IconButton,
        PopupMenuButton,
        Scaffold,
        Tooltip,
        showDialog;
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:PiliPlus/common/widgets/scale_app.dart';
import 'package:window_manager/window_manager.dart';
import 'package:PiliPlus/utils/app_exit.dart';
import 'package:PiliPlus/services/translate/llama_engine.dart';
import 'package:PiliPlus/services/translate/translation_layout.dart';
import 'package:PiliPlus/services/translate/translation_models.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/caption_source.dart';
import 'package:PiliPlus/services/translate/translation_track.dart';
import 'package:PiliPlus/services/translate/translation_engine.dart';

/// Command-line self test (LibrePili), for scripted checks of a real build:
///
///   LibrePili.exe --selftest [--download BVxxx] [--qn 80] [--local]
///                 [--keep] [--out result.json]
///   LibrePili.exe --selftest --ci-smoke --profile ci --out result.json
///
/// Runs after the app has started normally, writes a JSON report and exits
/// with 0 when every check passed, 1 otherwise. With no check flags nothing
/// is checked and the report passes: that only says the app started.
/// Stands between the player and a CDN and cuts the file short at [cutAt]
/// bytes, the way a broken copy on one host did (BV16Ltu6wELb on akamai,
/// 2026-09-24): the body stops there, and a request that starts at or past
/// it gets its connection dropped with no response.
final class _CuttingProxy {
  _CuttingProxy(
    this.cutAt, {
    this.bytesPerSecond,
    this.oneHost = true,
    this.throttleFor,
  });

  /// How long [bytesPerSecond] holds from the start; after that the host is
  /// as fast as it is. Null: for good.
  final Duration? throttleFor;
  final _since = Stopwatch()..start();

  /// Only the first host's streams pass through (see [wrap]).
  final bool oneHost;

  final int cutAt;

  /// Hands the bytes over no faster than this: a host that delivers, only
  /// slower than the stream plays.
  final int? bytesPerSecond;
  late final HttpServer _server;
  final requests = <String>[];

  /// Bytes handed to the player, all requests together.
  var bytesSent = 0;

  /// The host the broken copy is on: the first one wrapped. A stream opened
  /// again from another host is whole, as it was in the case this copies.
  String? _host;

  String wrap(String url) {
    final host = Uri.tryParse(url)?.host;
    _host ??= host;
    if (oneHost && host != _host) return url;
    return 'http://127.0.0.1:${_server.port}/cut?u=${Uri.encodeComponent(url)}';
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _serve(HttpRequest request) async {
    final upstream = request.uri.queryParameters['u'];
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final from =
        int.tryParse(
          RegExp(r'bytes=(\d+)-').firstMatch(range ?? '')?.group(1) ?? '',
        ) ??
        0;
    requests.add('${request.method} range=$range');
    if (upstream == null || from >= cutAt) {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    final client = HttpClient()..userAgent = BrowserUa.pc;
    try {
      final out = await client.openUrl(request.method, Uri.parse(upstream));
      out.headers.set(HttpHeaders.refererHeader, HttpString.baseUrl);
      if (range != null) out.headers.set(HttpHeaders.rangeHeader, range);
      final answer = await out.close();
      final response = request.response
        ..statusCode = answer.statusCode
        ..contentLength = answer.contentLength;
      for (final name in const [
        'content-range',
        'content-type',
        'accept-ranges',
      ]) {
        if (answer.headers.value(name) case final value?) {
          response.headers.set(name, value);
        }
      }
      final socket = await response.detachSocket(writeHeaders: true);
      var left = cutAt - from;
      final clock = Stopwatch()..start();
      var sent = 0;
      await for (final chunk in answer) {
        if (bytesPerSecond case final rate?
            when throttleFor == null || _since.elapsed < throttleFor!) {
          final due = Duration(microseconds: sent * 1000000 ~/ rate);
          if (due > clock.elapsed) await Future.delayed(due - clock.elapsed);
          sent += chunk.length;
        }
        if (chunk.length >= left) {
          socket.add(chunk.sublist(0, left));
          bytesSent += left;
          break;
        }
        socket.add(chunk);
        bytesSent += chunk.length;
        left -= chunk.length;
        // only as fast as the player reads: without waiting, everything the
        // CDN sent was counted (and buffered) even after the player had
        // hung up — every probe run showed the whole file downloaded
        try {
          await socket.flush();
        } catch (_) {
          break;
        }
      }
      await socket.flush();
      socket.destroy();
    } catch (_) {
      try {
        (await request.response.detachSocket(writeHeaders: false)).destroy();
      } catch (_) {}
    } finally {
      client.close(force: true);
    }
  }
}

abstract final class SelfTest {
  static bool isRequested(List<String> args) => args.contains('--selftest');

  /// The profile folder for this run (see [selfTestProfileDir]). Only
  /// letters, digits, `-` and `_` are kept from `--profile`, so the name can
  /// never climb out of the app's data folder.
  static String profileDir(List<String> args) {
    final name = (_arg(args, '--profile') ?? '').replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '',
    );
    return name.isEmpty ? 'selftest' : 'selftest-$name';
  }

  /// `--ci-smoke`: the checks that need nothing from outside the build — no
  /// network, no models, no camera — run together, so CI can start the real
  /// app on a fresh runner and fail the job when it breaks. Each one also
  /// has its own flag; this only switches them all on at once, so the set
  /// CI runs is named in one place.
  static const ciSmokeFlags = {
    '--local',
    '--dialog-probe',
    '--settings-reachable',
    '--platform-search',
    '--metrics',
  };

  /// Inverse text normalisation for probe runs; see [AsrJob.itn].
  static bool _itn = true;

  /// How often the key probe samples mpv, in ms (`--probe-sample-ms`).
  static int probeSampleMs = 20;

  /// What a running scenario is waiting on, written every few seconds to
  /// `<out>.progress` beside the report: a run on a phone that stopped
  /// moving otherwise says nothing until its deadline, half an hour on.
  static Map<String, Object?> Function()? _progress;

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
    appExit(1);
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
        '${(info ?? '').isEmpty ? '' : ' :: ${info!.replaceAll(RegExp(r'\s+'), ' ').trim()}'}'
        // the frames that say whose code it was: an assertion inside the
        // framework names no widget, and its first line names no file
        '${_appFrames(details.stack)}',
      );
      previous?.call(details);
    };
  }

  /// Up to four stack frames from outside the Flutter framework.
  static String _appFrames(StackTrace? stack) {
    if (stack == null) return '';
    final frames = stack
        .toString()
        .split('\n')
        .where((l) => l.contains('package:') && !l.contains('package:flutter/'))
        .take(4)
        .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
        .toList();
    return frames.isEmpty ? '' : ' ## ${frames.join(' | ')}';
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

  /// Renders the current page at [width] logical pixels for [hold], and
  /// returns any framework errors that appeared while it was that narrow.
  ///
  /// Desktop probes run in a wide window, so a layout that only breaks at
  /// phone width never got built. The errors are taken out of [uiErrors] and
  /// returned rather than left there, so the caller can say *where* they
  /// happened instead of just that the run failed.
  /// The width the app was actually laid out at during the last [_atWidth].
  static double? narrowLogicalWidth;

  static Future<List<String>> _atWidth(double width, Duration hold) async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return const [];
    }
    final before = await windowManager.getSize();
    final seen = uiErrors.length;
    try {
      await SelfTestWindow.setSize(Size(width, before.height));
      await Future.delayed(hold);
      // what the app actually laid out at, so a resize that silently did
      // nothing cannot read as "no overflow at phone width"
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      narrowLogicalWidth = view.physicalSize.width / view.devicePixelRatio;
      return uiErrors.sublist(seen).toList();
    } finally {
      uiErrors.removeRange(seen, uiErrors.length);
      await SelfTestWindow.setSize(before);
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

  static int _countElements(bool Function(Element) test) {
    var count = 0;
    void visit(Element element) {
      if (test(element)) count++;
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return count;
  }

  /// Turns the mouse wheel over [position], [times] notches of [dy].
  ///
  /// The comment list asks for its next page when the row at the end is
  /// built, so the only way to test pagination is to reach the end the way
  /// a reader does.
  static Future<void> _scroll(
    Offset position,
    double dy, {
    int times = 6,
  }) async {
    const device = 7302;
    final binding = GestureBinding.instance;
    for (var i = 0; i < times; i++) {
      binding.handlePointerEvent(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          device: device,
          position: position,
          scrollDelta: Offset(0, dy),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 250));
    }
    await Future.delayed(const Duration(milliseconds: 600));
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
    _itn = _arg(args, '--asr-itn') != '0';
    debugFocusProbe = args.contains('--focus-probe');
    debugCommentsProbe = args.contains('--comments-probe');
    debugCommentsFirst = args.contains('--comments-first');
    // a model file given directly (a phone test build has none installed:
    // its data is its own), for the translation probes
    PlPlayerController.debugLongPressRelease = _arg(
      args,
      '--longpress-release',
    );
    probeSampleMs = int.tryParse(_arg(args, '--probe-sample-ms') ?? '') ?? 20;
    // mpv options on top of the app's, repeatable: `--mpv-opt audio-buffer=0.05`
    PlPlayerController.debugMpvOptions = {
      for (var i = 0; i < args.length - 1; i++)
        if (args[i] == '--mpv-opt' && args[i + 1].contains('='))
          args[i + 1].split('=').first: args[i + 1]
              .split('=')
              .skip(1)
              .join('='),
    };
    // weights repacked for the CPU (or not), whatever the platform's default
    if (_arg(args, '--translate-repack') case final repack?) {
      LlamaTranslationEngine.debugRepack = repack == '1';
    }
    if (_arg(args, '--translate-model') case final model?) {
      TranslationService.to.useModelFile(model);
    }
    if (_arg(args, '--native') case final native?) {
      TextLanguage.debugNative = native.split('+');
    }
    debugDumpUrls = args.contains('--dump-urls');
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
      void writeProgress() {
        try {
          File('$out.progress').writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'scenario': name,
              'ms': sw.elapsedMilliseconds,
              'at': DateTime.now().toIso8601String(),
              'status': _progress?.call(),
              'player': switch (PlPlayerController.instance) {
                final player? => {
                  'position': player.position.value,
                  'buffered': player.buffered.value,
                  'buffering': player.isBuffering.value,
                  'status': player.playerStatus.value.name,
                },
                null => null,
              },
              'asr':
                  Get.isRegistered<AsrService>() &&
                      !Get.isPrepared<AsrService>()
                  ? AsrService.to.debugCurrent?.debugStatus
                  : null,
              'translation':
                  Get.isRegistered<TranslationService>() &&
                      !Get.isPrepared<TranslationService>()
                  ? TranslationService.to.debugCurrent?.debugStatus
                  : null,
              'eventLog': EventLog.recent.reversed.take(40).toList(),
            }),
          );
        } catch (_) {}
      }

      final progress = Timer.periodic(
        const Duration(seconds: 5),
        (_) => writeProgress(),
      );
      Map<String, dynamic> result;
      try {
        result = await body();
      } catch (e, s) {
        result = {'pass': false, 'error': '$e', 'stack': '$s'};
      } finally {
        progress.cancel();
        _progress = null;
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

    final smoke = args.contains('--ci-smoke');
    bool on(String flag) =>
        args.contains(flag) || (smoke && ciSmokeFlags.contains(flag));
    if (smoke) {
      report['smoke'] = ciSmokeFlags.toList();
      await scenario('startup', _startup);
    }

    if (args.contains('--home-probe')) {
      // the home page's first load, as the user meets it at startup: how
      // long until it shows something, and what (the slow and failed
      // requests on the way are in the report's eventLog)
      await scenario('homeProbe', () async {
        final clock = Stopwatch()..start();
        while (!Get.isRegistered<RcmdController>() &&
            clock.elapsed < const Duration(seconds: 30)) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        if (!Get.isRegistered<RcmdController>()) {
          return {'pass': false, 'reason': 'home page never built'};
        }
        final controller = Get.find<RcmdController>();
        while (controller.loadingState.value is Loading &&
            clock.elapsed < const Duration(seconds: 120)) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        final state = controller.loadingState.value;
        final items = switch (state) {
          Success(:final response) => response?.length,
          _ => null,
        };
        return {
          'pass': (items ?? 0) > 0,
          'appRcmd': controller.appRcmd,
          'ms': clock.elapsedMilliseconds,
          'state': state.runtimeType.toString(),
          'items': items,
          'error': state is Error ? state.errMsg : null,
        };
      });
    }
    if (_arg(args, '--local-feed-probe') case final mid?) {
      await scenario('localFeed', () => _localFeedProbe(int.parse(mid)));
    }
    if (_arg(args, '--feed') case final mid?) {
      await scenario('feed', () => _feed(int.parse(mid)));
    }
    if (on('--local')) {
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
    if (_arg(args, '--dump-captions') case final video?) {
      final dir = _arg(args, '--dir') ?? path.join(tmpDirPath, 'captions');
      await scenario('dumpCaptions', () => _dumpCaptions(video, dir));
    }
    if (_arg(args, '--bili-subtitles') case final bvid?) {
      await scenario('biliSubtitles', () => _biliSubtitles(bvid));
    }
    if (_arg(args, '--asr-latency') case final video?) {
      await scenario('asrLatency', () => _asrLatency(video));
    }
    if (_arg(args, '--translate-latency') case final video?) {
      final seconds = int.tryParse(_arg(args, '--watch') ?? '') ?? 90;
      await scenario(
        'translateLatency',
        () => _translateLatency(video, _arg(args, '--model'), seconds),
      );
    }
    if (_arg(args, '--translate-file') case final file?) {
      await scenario(
        'translateFile',
        () => _translateFile(
          file,
          _arg(args, '--translate-out'),
          from: _arg(args, '--translate-from'),
        ),
      );
    }
    if (_arg(args, '--keepgoing-probe') case final video?) {
      await scenario(
        'keepGoingProbe',
        () => _keepGoingProbe(
          video,
          seconds: int.tryParse(_arg(args, '--hold') ?? '') ?? 90,
        ),
      );
    }
    if (_arg(args, '--remembered-probe') case final file?) {
      _shots = _arg(args, '--shots');
      await scenario(
        'rememberedProbe',
        () => _rememberedProbe(
          file,
          offHold: int.tryParse(_arg(args, '--hold-off') ?? '') ?? 20,
          hold: int.tryParse(_arg(args, '--hold') ?? '') ?? 60,
        ),
      );
    }
    if (_arg(args, '--switch-probe') case final file?) {
      await scenario(
        'switchProbe',
        () => _switchProbe(
          file,
          offAt: int.tryParse(_arg(args, '--off-at') ?? '') ?? 20,
          hold: int.tryParse(_arg(args, '--hold') ?? '') ?? 150,
        ),
      );
    }
    if (_arg(args, '--ctl-probe') case final file?) {
      await scenario(
        'ctlProbe',
        () => _ctlProbe(
          file,
          hold: int.tryParse(_arg(args, '--hold') ?? '') ?? 90,
          holdOff: int.tryParse(_arg(args, '--hold-off') ?? '') ?? 15,
        ),
      );
    }
    if (_arg(args, '--translate-page') case final video?) {
      _shots = _arg(args, '--shots');
      final hold = int.tryParse(_arg(args, '--hold') ?? '') ?? 45;
      final bv = IdUtils.bvRegex.firstMatch(video)?.group(0);
      // a file opens in the same page, in its local mode
      final local = File(video).existsSync();
      await scenario(
        'translatePage',
        () => bv != null || local
            ? _translatePageBili(
                local ? video : 'https://www.bilibili.com/video/$bv',
                hold,
                auto: args.contains('--auto'),
                into: _arg(args, '--into'),
              )
            : _translatePage(
                video,
                hold,
                auto: args.contains('--auto'),
                into: _arg(args, '--into'),
              ),
      );
    }
    if (_arg(args, '--translate-probe') case final gguf?) {
      await scenario('translateProbe', () => _translateProbe(gguf));
    }
    if (args.contains('--bench-models')) {
      await scenario(
        'benchModels',
        () => _benchModels(
          asrModels: _arg(args, '--asr-models'),
          translationFile: _arg(args, '--translate-model'),
        ),
      );
    }
    if (_arg(args, '--caption-compare') case final video?) {
      await scenario('captionCompare', () => _captionCompare(video));
    }
    // `--debug-overlay [--shots DIR]`: 调试模式 on in this profile for the
    // scenarios that follow (`--open-bili URL`), its lines sampled and the
    // app shot while they run; judged after them all
    _OverlayWatch? overlayWatch;
    if (args.contains('--debug-overlay')) {
      await GStorage.setting.put(SettingBoxKey.debugMode, true);
      DebugOverlay.setEnabled(true);
      _shots ??= _arg(args, '--shots');
      overlayWatch = _OverlayWatch()..start();
    }
    if (_arg(args, '--open-bili') case final url?) {
      final hold = int.tryParse(_arg(args, '--hold') ?? '') ?? 20;
      // which file is played decides whether a broken copy on a CDN is hit:
      // the one that froze at 9 s was the AVC one (`--codecs AVC`)
      final codecs = _arg(args, '--codecs');
      // a broken copy on the first CDN, on demand
      _CuttingProxy? cut;
      final cutAt = int.tryParse(_arg(args, '--cut-video-at') ?? '');
      final kbps = int.tryParse(_arg(args, '--throttle-video-kbps') ?? '');
      if (cutAt != null || kbps != null) {
        final at = cutAt ?? 1 << 50;
        final throttleFor = int.tryParse(_arg(args, '--throttle-for') ?? '');
        cut = _CuttingProxy(
          at,
          bytesPerSecond: kbps == null ? null : kbps * 1000 ~/ 8,
          throttleFor: throttleFor == null
              ? null
              : Duration(seconds: throttleFor),
        );
        await cut.start();
        VideoUtils.debugWrapVideoUrl = cut.wrap;
      }
      // the stream a replacement brings in, slower than it plays: what the
      // player cannot see once the video is an external track
      _CuttingProxy? slowReplacement;
      final replacedKbps = int.tryParse(
        _arg(args, '--throttle-replaced-kbps') ?? '',
      );
      if (replacedKbps != null) {
        slowReplacement = _CuttingProxy(
          1 << 50,
          bytesPerSecond: replacedKbps * 1000 ~/ 8,
          oneHost: false,
        );
        await slowReplacement.start();
        PlPlayerController.debugWrapReplacedVideo = slowReplacement.wrap;
      }
      PlPlayerController.debugNoVideoWatch = args.contains('--no-video-watch');
      PlPlayerController.debugNoHandover = args.contains('--no-handover');
      // started the way a viewer's page starts it, so what the page does
      // for playback (resuming after a CDN switch) is what is tested
      final autoplay = args.contains('--autoplay');
      // `default`: no preference saved, as for someone who never set one
      final codecsDefault = codecs == 'default';
      final overrides = <String, Object>{
        if (!codecsDefault) SettingBoxKey.preferCodecs: ?codecs?.split(','),
        // explicit either way: the default is on since 2026-09-29
        SettingBoxKey.autoPlayEnable: autoplay,
        // moving comments over a frozen picture would look like playback
        // to anything comparing frames
        if (args.contains('--no-danmaku'))
          SettingBoxKey.enableShowDanmaku: false,
      };
      final before = {
        for (final key in overrides.keys) key: GStorage.setting.get(key),
        if (codecsDefault)
          SettingBoxKey.preferCodecs: GStorage.setting.get(
            SettingBoxKey.preferCodecs,
          ),
      };
      await GStorage.setting.putAll(overrides);
      if (codecsDefault) {
        await GStorage.setting.delete(SettingBoxKey.preferCodecs);
      }
      try {
        await scenario(
          'openBili',
          () => _openBili(
            url,
            hold,
            autoplay: autoplay,
            recovery: !args.contains('--no-recovery'),
            sampleMs: int.tryParse(_arg(args, '--sample-ms') ?? '') ?? 2000,
            sampleSeconds: int.tryParse(_arg(args, '--sample-for') ?? '') ?? 50,
            seekTo: int.tryParse(_arg(args, '--seek-to') ?? ''),
            seekAfterMs: int.tryParse(_arg(args, '--seek-after') ?? '') ?? 0,
            dumpUrls: args.contains('--dump-urls'),
            noHostSwitch: args.contains('--no-host-switch'),
          ),
        );
      } finally {
        VideoUtils.debugWrapVideoUrl = null;
        PlPlayerController.debugWrapReplacedVideo = null;
        PlPlayerController.debugNoVideoWatch = false;
        PlPlayerController.debugNoHandover = false;
        if (slowReplacement != null) {
          stderr.writeln(
            'slow replacement: ${slowReplacement.requests.join(' | ')}',
          );
          await slowReplacement.close();
        }
        if (cut != null) {
          stderr.writeln('cutting proxy: ${cut.requests.join(' | ')}');
          await cut.close();
        }
        for (final MapEntry(:key, :value) in before.entries) {
          value == null
              ? await GStorage.setting.delete(key)
              : await GStorage.setting.put(key, value);
        }
      }
    }
    if (_arg(args, '--danmaku-probe') case final bv?) {
      // the reverse checks: each assertion has to fail without its fix
      PlDanmaku.debugFollowBuffering = !args.contains('--no-buffer-follow');
      PlDanmaku.debugRefill = !args.contains('--no-refill');
      // shown, whatever an earlier run (`--open-bili --no-danmaku`) left in
      // this profile; put back after
      final shown = GStorage.setting.get(SettingBoxKey.enableShowDanmaku);
      await GStorage.setting.put(SettingBoxKey.enableShowDanmaku, true);
      // the tracks as the renderer fills them without overlap (massive
      // mode piles danmaku onto them regardless)
      final massive = DanmakuOptions.danmakuMassiveMode;
      if (args.contains('--no-massive')) {
        DanmakuOptions.danmakuMassiveMode = false;
      }
      try {
        await scenario(
          'danmakuProbe',
          () => _danmakuProbe(
            bv,
            seekTo: int.tryParse(_arg(args, '--seek-to') ?? '') ?? 120,
          ),
        );
      } finally {
        PlDanmaku.debugFollowBuffering = true;
        PlDanmaku.debugRefill = true;
        DanmakuOptions.danmakuMassiveMode = massive;
        shown == null
            ? await GStorage.setting.delete(SettingBoxKey.enableShowDanmaku)
            : await GStorage.setting.put(
                SettingBoxKey.enableShowDanmaku,
                shown,
              );
      }
    }
    if (_arg(args, '--hover-controls') case final video?) {
      await scenario('hoverControls', () => _hoverControls(video));
    }
    if (_arg(args, '--yt-replies') case final video?) {
      await scenario('ytReplies', () => _ytReplies(video));
    }
    if (_arg(args, '--yt-download') case final video?) {
      // --keep leaves the finished mp4 on disk, so another scenario (the
      // transcriber) can be pointed at it instead of inventing a source
      await scenario(
        'ytDownload',
        () => _ytDownload(video, keep: args.contains('--keep')),
      );
    }
    if (_arg(args, '--yt-fav') case final video?) {
      await scenario('ytFav', () => _ytFav(video));
    }
    if (_arg(args, '--yt-search-ui') case final query?) {
      await scenario('ytSearchUi', () => _ytSearchUi(query));
    }
    if (args.contains('--import-settings')) {
      await scenario('importSettings', _importSettings);
    }
    if (_arg(args, '--models-page') case final dir?) {
      _shots = dir;
      await scenario('modelsPage', _modelsPage);
    }
    if (_arg(args, '--bench-models-ui') case final dir?) {
      _shots = dir;
      await scenario('benchModelsUi', _benchModelsUi);
    }
    if (on('--settings-reachable')) {
      await scenario('settingsReachable', _settingsReachable);
    }
    if (on('--metrics')) {
      await scenario('metrics', _uiMetrics);
    }
    if (on('--platform-search')) {
      await scenario('platformSearch', _platformSearch);
    }
    if (_arg(args, '--yt-steps') case final video?) {
      await scenario(
        'ytSteps',
        () => _ytSteps(
          video,
          (_arg(args, '--steps') ?? 'off,asr,zh').split(','),
          int.tryParse(_arg(args, '--step-hold') ?? '') ?? 20,
        ),
      );
    }
    if (_arg(args, '--yt-channel') case final channel?) {
      await scenario('youtubeChannel', () => _youtubeChannel(channel));
    }
    if (_arg(args, '--yt-playlist') case final playlist?) {
      await scenario('youtubePlaylist', () => _youtubePlaylist(playlist));
    }
    if (_arg(args, '--yt-post-probe') case final channel?) {
      await scenario('youtubePostProbe', () => _youtubePostProbe(channel));
    }
    // LibrePili (yt-channel-tabs): side-by-side screenshots of the bilibili
    // space / lists and the YouTube channel, for the shared-component check
    if (_arg(args, '--ui-shots') case final dir?) {
      _shots = dir;
      await scenario(
        'uiShots',
        () => _uiShots(
          mid: _arg(args, '--shots-mid') ?? '946974',
          bvid: _arg(args, '--shots-bv') ?? 'BV1GJ411x7h7',
          channel: _arg(args, '--shots-yt') ?? 'UCsXVk37bltHxD1rDPwtNM8Q',
          query: _arg(args, '--shots-query') ?? '黑洞',
        ),
      );
    }
    if (_arg(args, '--yt-search') case final query?) {
      await scenario('youtubeSearch', () => _youtubeSearch(query));
    }
    if (_arg(args, '--history-probe') case final bili?) {
      // a fresh profile does not start the player on its own: without it
      // the bilibili page never opens a source to record
      final autoplayBefore = GStorage.setting.get(SettingBoxKey.autoPlayEnable);
      await GStorage.setting.put(SettingBoxKey.autoPlayEnable, true);
      try {
        await scenario(
          'localHistory',
          () => _historyProbe(
            bili,
            yt: _arg(args, '--history-yt') ?? 'dQw4w9WgXcQ',
            paused: _arg(args, '--history-paused') ?? 'BV1xx411c7mD',
            seekTo: int.tryParse(_arg(args, '--seek-to') ?? '') ?? 60,
          ),
        );
      } finally {
        autoplayBefore == null
            ? await GStorage.setting.delete(SettingBoxKey.autoPlayEnable)
            : await GStorage.setting.put(
                SettingBoxKey.autoPlayEnable,
                autoplayBefore,
              );
      }
    }
    if (_arg(args, '--open-yt') case final video?) {
      final hold = int.tryParse(_arg(args, '--hold') ?? '') ?? 20;
      await scenario('openYouTube', () => _openYouTube(video, hold));
    }
    // a pause past the play URLs' expiry (user 2026-10-01: paused 9.5 h, it
    // would not play again): `--renew-pause BILI_URL|yt:ID`, the URLs made
    // to expire `--expire-after` s after they are opened
    if (_arg(args, '--ux-tour') case final target?) {
      _shots = _arg(args, '--shots') ?? _shots;
      // YouTube refusing the first URLs (403), as it once did
      YtVideoController.debugRefuseFirstOpen = args.contains('--yt-refuse-first');
      // a host slower than the stream plays (the video stream only)
      _CuttingProxy? slow;
      final kbps = int.tryParse(_arg(args, '--throttle-video-kbps') ?? '');
      if (kbps != null) {
        slow = _CuttingProxy(1 << 50, bytesPerSecond: kbps * 1000 ~/ 8);
        await slow.start();
        VideoUtils.debugWrapVideoUrl = slow.wrap;
      }
      try {
        await scenario(
          'uxTour',
          () => _uxTour(target, int.tryParse(_arg(args, '--seed') ?? '') ?? 1),
        );
      } finally {
        VideoUtils.debugWrapVideoUrl = null;
        await slow?.close();
      }
    }
    if (args.contains('--mine-entries')) {
      _shots = _arg(args, '--shots') ?? _shots;
      await scenario('mineEntries', _mineEntries);
    }
    if (_arg(args, '--broken-reopen') case final target?) {
      await scenario('brokenReopen', () => _brokenReopen(target));
    }
    if (_arg(args, '--subs-reopen') case final target?) {
      await scenario('subsReopen', () => _subsReopen(target));
    }
    if (_arg(args, '--renew-pause') case final target?) {
      await scenario(
        'renewPause',
        () => _renewPause(
          target,
          int.tryParse(_arg(args, '--expire-after') ?? '') ?? 75,
        ),
      );
    }
    if (_arg(args, '--yt') case final video?) {
      await scenario('youtube', () => _youtube(video));
    }
    if (_arg(args, '--quality-codecs') case final video?) {
      await scenario('qualityCodecs', () => _qualityCodecs(video));
    }
    if (_arg(args, '--probe-playback') case final url?) {
      final seconds = int.tryParse(_arg(args, '--probe-secs') ?? '') ?? 20;
      await scenario('probePlayback', () => _probePlayback(url, seconds));
    }
    if (_arg(args, '--asr-download') case final dir?) {
      await scenario(
        'asrDownload',
        () => _asrDownload(dir, english: args.contains('--with-english')),
      );
    }
    if (args.contains('--comment-translate-probe')) {
      await scenario('commentTranslateProbe', _commentTranslateProbe);
    }
    // the per-comment button and the bilingual layout, as screenshots
    // (user 2026-10-01): `--comment-bilingual BILI_URL`,
    // `--yt-comment-bilingual ID`, with `--shots DIR`
    if (_arg(args, '--comment-bilingual') case final url?) {
      _shots = _arg(args, '--shots') ?? _shots;
      await scenario('commentBilingualBili', () => _commentBilingualBili(url));
    }
    if (_arg(args, '--yt-comment-bilingual') case final video?) {
      _shots = _arg(args, '--shots') ?? _shots;
      await scenario('commentBilingualYt', () => _commentBilingualYt(video));
    }
    if (_arg(args, '--net-probe') case final url?) {
      // the app's own sockets (Dart), to a host the player could not reach:
      // tells a blocked destination from a blocked player
      await scenario('netProbe', () async {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 30);
        final clock = Stopwatch()..start();
        try {
          final request = await client.getUrl(Uri.parse(url));
          final connectedMs = clock.elapsedMilliseconds;
          request.headers
            ..set(HttpHeaders.userAgentHeader, BrowserUa.pc)
            ..set(HttpHeaders.refererHeader, 'https://www.bilibili.com')
            ..set(HttpHeaders.rangeHeader, 'bytes=0-1023');
          final response = await request.close();
          await response.drain<void>();
          return {
            'pass': true,
            'connectedMs': connectedMs,
            'status': response.statusCode,
            'totalMs': clock.elapsedMilliseconds,
          };
        } catch (e) {
          return {
            'pass': false,
            'error': '$e',
            'ms': clock.elapsedMilliseconds,
          };
        } finally {
          client.close(force: true);
        }
      });
    }
    if (on('--dialog-probe')) {
      // the app's own dialogs, shown in the real app: a widget test with a
      // plain MaterialApp let one built on the wrong material library pass
      await scenario('dialogProbe', () async {
        final context = Get.context!;
        showQrShare(
          context,
          url: 'https://www.bilibili.com/video/BV18yt46NEC5',
        );
        await Future.delayed(const Duration(seconds: 2));
        Get.back<void>();
        await Future.delayed(const Duration(milliseconds: 500));
        FailureReport.show('测试弹窗', '自测显示失败弹窗');
        await Future.delayed(const Duration(seconds: 2));
        await SmartDialog.dismiss(tag: 'failure:测试弹窗');
        await Future.delayed(const Duration(milliseconds: 500));
        return {'pass': true};
      });
    }
    if (args.contains('--scan-probe')) {
      await scenario('scanProbe', () async {
        ScanPage.debugProblem = null;
        ScanPage.debugFrames = 0;
        ScanPage.debugRead = null;
        // --scan-wait: time to hold a code up to the camera
        final wait = int.tryParse(_arg(args, '--scan-wait') ?? '') ?? 8;
        final read = scanQrCode();
        final clock = Stopwatch()..start();
        while (ScanPage.debugRead == null &&
            clock.elapsed < Duration(seconds: wait)) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
        final result = {
          'pass': true,
          'problem': ScanPage.debugProblem,
          'frames': ScanPage.debugFrames,
          'read': ScanPage.debugRead,
          'readAfterMs': ScanPage.debugRead == null
              ? null
              : clock.elapsedMilliseconds,
        };
        // a code read closes the page by itself
        if (ScanPage.debugRead == null) Get.back<void>();
        await read;
        await Future.delayed(const Duration(seconds: 1));
        return result;
      });
    }
    if (_arg(args, '--asr-start-probe') case final given?) {
      // @path: the URL read from a file. On a phone the arguments come
      // through `am --esa`, which splits at every comma, and a stream URL
      // has commas (`uparams=e,mid,…`); the start list takes + for the same
      // reason
      final source = given.startsWith('@')
          ? File(given.substring(1)).readAsStringSync().trim()
          : given;
      await scenario(
        'asrStartProbe',
        () => _asrStartProbe(
          source,
          at: [
            for (final a in (_arg(args, '--at') ?? '0,120,300').split(
              RegExp('[,+]'),
            ))
              double.parse(a),
          ],
          window: double.tryParse(_arg(args, '--window') ?? '') ?? 40,
          dir: _arg(args, '--dir') ?? path.join(tmpDirPath, 'asr_probe'),
        ),
      );
    }
    if (_arg(args, '--asr-export-probe') case final file?) {
      await scenario(
        'asrExportProbe',
        () => _asrExportProbe(
          file,
          dir: _arg(args, '--export-dir') ?? path.join(tmpDirPath, 'export'),
        ),
      );
    }
    if (_arg(args, '--asr-leak') case final source?) {
      await scenario(
        'asrLeak',
        () => _asrLeak(
          source,
          cycles: int.tryParse(_arg(args, '--cycles') ?? '') ?? 20,
          settleMs: int.tryParse(_arg(args, '--settle-ms') ?? '') ?? 3000,
        ),
      );
    }
    if (_arg(args, '--asr-session') case final given?) {
      // @path: the URL read from a file (see --asr-start-probe)
      final source = given.startsWith('@')
          ? File(given.substring(1)).readAsStringSync().trim()
          : given;
      await scenario(
        'asrSession',
        () => _asrSession(
          source,
          srtOut: _arg(args, '--asr-srt'),
          power: _power(_arg(args, '--asr-power')),
          playheadSpeed: double.tryParse(
            _arg(args, '--asr-playhead-speed') ?? '',
          ),
          offAt: double.tryParse(_arg(args, '--asr-off-at') ?? ''),
          onAt: double.tryParse(_arg(args, '--asr-on-at') ?? ''),
          stopAt: double.tryParse(_arg(args, '--asr-stop-at') ?? ''),
          english: switch (_arg(args, '--asr-english')) {
            '1' => true,
            '0' => false,
            _ => null,
          },
        ),
      );
    }
    if (_arg(args, '--asr-seam-probe') case final given?) {
      final source = given.startsWith('@')
          ? File(given.substring(1)).readAsStringSync().trim()
          : given;
      await scenario(
        'asrSeamProbe',
        () => _asrSeamProbe(
          source,
          at: [
            for (final a in (_arg(args, '--at') ?? '240+120').split(
              RegExp('[,+]'),
            ))
              double.parse(a),
          ],
          lead: double.tryParse(_arg(args, '--lead') ?? '') ?? 45,
          out: _arg(args, '--seam-out'),
        ),
      );
    }
    if (_arg(args, '--asr-seek-probe') case final given?) {
      // @path: the URL read from a file (see --asr-start-probe)
      final source = given.startsWith('@')
          ? File(given.substring(1)).readAsStringSync().trim()
          : given;
      await scenario(
        'asrSeekProbe',
        () => _asrSeekProbe(
          source,
          seeks: [
            for (final a in (_arg(args, '--seek') ?? '1800').split(
              RegExp('[,+]'),
            ))
              double.parse(a),
          ],
          window: double.tryParse(_arg(args, '--window') ?? '') ?? 30,
          dwell: int.tryParse(_arg(args, '--dwell') ?? '') ?? 0,
        ),
      );
    }
    if (_arg(args, '--asr') case final source?) {
      await scenario(
        'asr',
        () => _asr(
          source,
          modelDir: _arg(args, '--asr-models'),
          forceLanguage: _arg(args, '--asr-language'),
          srtOut: _arg(args, '--asr-srt'),
          pcmOut: _arg(args, '--asr-pcm'),
        ),
      );
    }

    if (overlayWatch != null) {
      await scenario('debugOverlay', overlayWatch.finish);
    }

    report
      ..['pass'] = ok
      // what the app noted on the way (slow and failed requests, the
      // player's errors): the report says why, not only that
      ..['eventLog'] = EventLog.recent
      ..['finishedAt'] = DateTime.now().toIso8601String();
    await File(out).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    appExit(ok ? 0 : 1);
  }

  // ------------------------------------------------------------ scenarios

  /// LibrePili: did the app come up as far as a person would see it?
  ///
  /// The first thing the CI smoke asks. A run that reached this point has
  /// a process, storage and a first frame; what is left to check is that
  /// the frame is the app — a navigator with a route, a view with a size,
  /// and some text in the tree — and not a blank window, which on a
  /// runner with no desktop is the likeliest way to fail. Framework errors
  /// thrown while the home page built are charged to this check by
  /// [scenario], since nothing earlier collects them.
  static Future<Map<String, dynamic>> _startup() async {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final texts = _visibleTexts();
    return {
      'pass':
          Get.context != null &&
          Get.currentRoute.isNotEmpty &&
          !view.physicalSize.isEmpty &&
          texts.isNotEmpty,
      'route': Get.currentRoute,
      'physicalSize': '${view.physicalSize.width}x${view.physicalSize.height}',
      'devicePixelRatio': view.devicePixelRatio,
      'textsOnScreen': texts.length,
      'someTexts': texts.take(12).toList(),
      // a CI runner's service session has no interactive desktop; recorded
      // so a failure there can be told from one on a real machine
      if (Platform.isWindows)
        'sessionName': Platform.environment['SESSIONNAME'],
    };
  }

  /// LibrePili: after toggling fullscreen, does moving the mouse over the
  /// video bring the control bars back?
  ///
  /// Reported: it does not — the pointer has to leave the player and come
  /// back. The first version of this probe passed, because it reset
  /// showControls to false before each hover and so made every hover a
  /// genuine change — which is exactly the condition the defect needs to be
  /// absent. It also asserted on showControls, and that flag was never the
  /// thing that was wrong: the bar's own position is.
  /// Plays [target] (a bilibili link, or `yt:ID`) a few seconds, pauses
  /// past the URLs' expiry, plays again. Pass: new URLs were asked for, and
  /// playback went on from where it was paused.
  static Future<Map<String, dynamic>> _renewPause(
    String target,
    int expireAfter,
  ) async {
    PlPlayerController.debugExpiresIn = Duration(seconds: expireAfter);
    final start = DateTime.now();
    try {
      final PlPlayerController player;
      if (target.startsWith('yt:')) {
        final videoId = target.substring(3);
        unawaited(Get.toNamed('/ytVideo', parameters: {'id': videoId}));
        await Future.delayed(const Duration(seconds: 4));
        final page = Get.find<YtVideoController>(tag: videoId);
        for (var i = 0; i < 30 && page.stage.value != .ready; i++) {
          await Future.delayed(const Duration(seconds: 1));
        }
        player = page.plPlayerController;
      } else {
        await PiliScheme.routePushFromUrl(target);
        await Future.delayed(const Duration(seconds: 5));
        final page = Get.find<VideoDetailController>(
          tag: Get.parameters['heroTag'] ?? Get.arguments?['heroTag'],
        );
        for (var i = 0; i < 30 && !page.videoState.value; i++) {
          await Future.delayed(const Duration(seconds: 1));
        }
        player = page.plPlayerController;
      }
      final opened = DateTime.now();
      await player.play();
      for (var i = 0; i < 30 && player.position.value < 5; i++) {
        await Future.delayed(const Duration(seconds: 1));
      }
      await player.pause();
      await Future.delayed(const Duration(seconds: 1));
      final pausedAt = player.position.value;
      // past the expiry, counted from the open
      final left =
          Duration(seconds: expireAfter + 5) -
          DateTime.now().difference(opened);
      if (left > Duration.zero) await Future.delayed(left);
      final resumed = DateTime.now();
      await player.play();
      final timeline = <int>[];
      for (var i = 0; i < 20; i++) {
        await Future.delayed(const Duration(seconds: 1));
        timeline.add(player.position.value);
      }
      final events = [
        for (final (_, line) in EventLog.entries(since: start)) line,
      ];
      // the line comes in the same millisecond as the play: a little before
      final renewed = EventLog.entries(
        since: resumed.subtract(const Duration(seconds: 1)),
      ).any((e) => e.$2.contains('play URLs expired'));
      // the first second after the reopen may still read where it opened
      final resumedFrom = timeline.firstWhere(
        (p) => p > 0,
        orElse: () => -1,
      );
      final went = timeline.last - resumedFrom;
      return {
        'pass': renewed && (resumedFrom - pausedAt).abs() <= 3 && went >= 10,
        'renewed': renewed,
        'resumedAt': resumed.toIso8601String(),
        'pausedAt': pausedAt,
        'resumedFrom': resumedFrom,
        'advancedSeconds': went,
        'timeline': timeline,
        'events': events,
      };
    } finally {
      PlPlayerController.debugExpiresIn = null;
    }
  }

  /// `--subs-reopen BILI_URL`: a subtitle picked, then every way the player
  /// reopens the video under it — is the subtitle still on mpv after each?
  /// (user 2026-10-01: no subtitles after the stream was reopened)
  static Future<Map<String, dynamic>> _subsReopen(String target) async {
    final start = DateTime.now();
    await PiliScheme.routePushFromUrl(target);
    await Future.delayed(const Duration(seconds: 5));
    final page = Get.find<VideoDetailController>(
      tag: Get.parameters['heroTag'] ?? Get.arguments?['heroTag'],
    );
    for (var i = 0; i < 30 && !page.videoState.value; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    for (var i = 0; i < 15 && page.subtitles.isEmpty; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    final player = page.plPlayerController;
    String read(String name) {
      try {
        return player.videoPlayerController?.getProperty(name) ?? '';
      } catch (_) {
        return '';
      }
    }

    Map<String, Object?> now(String step) => {
      'step': step,
      'at': player.position.value,
      'sid': read('sid'),
      'subTracks': read('track-list/count'),
      'subText': read('sub-text'),
      'pageIndex': page.vttSubtitlesIndex.value,
    };

    final steps = <Map<String, Object?>>[];
    if (page.subtitles.isEmpty) {
      return {'pass': false, 'reason': 'no subtitles on this video'};
    }
    await page.setSubtitle(1);
    await player.play();
    await Future.delayed(const Duration(seconds: 8));
    steps.add(now('picked'));
    final ways = <String, Future<void> Function()>{
      'refreshPlayer': () async => player.refreshPlayer(),
      'onReopen': () async => player.onReopen?.call(),
      'onCdnFailover': () async => player.onCdnFailover?.call(),
      'onSourceExpired': () async => player.onSourceExpired?.call(
        Duration(seconds: player.position.value),
      ),
    };
    for (final way in ways.entries) {
      await way.value();
      await Future.delayed(const Duration(seconds: 10));
      if (!player.playerStatus.isPlaying) await player.play();
      // what follows a reopen (a hand over to a faster host) settles too
      await Future.delayed(const Duration(seconds: 10));
      steps.add(now(way.key));
    }
    final lost = [
      for (final s in steps)
        if (s['sid'] == 'no' || s['sid'] == '') s['step'],
    ];
    return {
      'pass': lost.isEmpty,
      'lostAfter': lost,
      'steps': steps,
      'events': [
        for (final (_, line) in EventLog.entries(since: start)) line,
      ],
    };
  }

  /// `--broken-reopen BILI_URL`: 20 s in, the page reopens on URLs every
  /// host refuses (403, as past their expiry), with no other host to try.
  /// Does the player then call it watched to the end — the heartbeat that
  /// makes bilibili open it at the start? (user 2026-10-01: reopened after
  /// a failure, it started over)
  static Future<Map<String, dynamic>> _brokenReopen(String target) async {
    final start = DateTime.now();
    await PiliScheme.routePushFromUrl(target);
    await Future.delayed(const Duration(seconds: 5));
    final page = Get.find<VideoDetailController>(
      tag: Get.parameters['heroTag'] ?? Get.arguments?['heroTag'],
    );
    for (var i = 0; i < 30 && !page.videoState.value; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    final player = page.plPlayerController;
    await player.play();
    for (var i = 0; i < 40 && player.position.value < 20; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    final before = player.position.value;
    String broken(String url) =>
        url.replaceAllMapped(RegExp(r'upsig=[0-9a-f]+'), (_) => 'upsig=0');
    page
      ..videoUrl = broken(page.videoUrl!)
      ..audioUrl = page.audioUrl == null ? null : broken(page.audioUrl!);
    PlPlayerController.debugDisableRecovery = true;
    final timeline = <Map<String, Object?>>[];
    try {
      player.onReopen?.call();
      for (var i = 0; i < 40; i++) {
        await Future.delayed(const Duration(seconds: 1));
        timeline.add({
          's': i + 1,
          'position': player.position.value,
          'status': player.playerStatus.value.name,
          'completed': player.videoPlayerController?.state.completed,
        });
      }
    } finally {
      PlPlayerController.debugDisableRecovery = false;
    }
    final events = [
      for (final (_, line) in EventLog.entries(since: start)) line,
    ];
    final completedBeat = events.any((e) => e.contains('heartbeat: completed'));
    return {
      // a failure is not the end of the video
      'pass': !completedBeat,
      'completedHeartbeat': completedBeat,
      'positionBefore': before,
      'timeline': timeline,
      'events': events,
    };
  }

  /// `--mine-entries`: the buttons on 我的 as the viewer sees them (a new
  /// profile is logged out), and that 观看记录 opens the history kept on
  /// this device (user 2026-10-01: logged out, it had no way in).
  static Future<Map<String, dynamic>> _mineEntries() async {
    unawaited(Get.to(() => const MinePage(showBackBtn: true)));
    await Future.delayed(const Duration(seconds: 3));
    final shown = [
      for (final title in const ['离线缓存', '观看记录', '我的订阅', '稍后再看'])
        if (_findElement(_isText(title)) != null) title,
    ];
    final mine = await _shot('mine');
    final tapped = await _tapText('观看记录');
    await Future.delayed(const Duration(seconds: 3));
    final route = Get.currentRoute;
    final history = await _shot('history');
    Get.back();
    await Future.delayed(const Duration(milliseconds: 500));
    Get.back();
    return {
      'pass': tapped && route == '/history' && !shown.contains('稍后再看'),
      'loggedIn': Accounts.main.isLogin,
      'shown': shown,
      'tapped': tapped,
      'route': route,
      'shots': [mine, history],
    };
  }

  /// `--ux-tour BILI_URL|yt:ID [--seed N]`: watched the way a viewer
  /// watches, with Chinese picked as the subtitle language (the user's
  /// setting): played a while, 10 s on, played a while, 10 s back, played a
  /// while, a jump past what is buffered, played a while — the seeks apart,
  /// not one after another (user 2026-10-01). Every second: where playback
  /// is, buffering, quality and host, the subtitle on mpv and its text, the
  /// transcript and translation; for every seek, how long until playback
  /// moves on and until a subtitle line shows. The event log comes with it.
  static Future<Map<String, dynamic>> _uxTour(String target, int seed) async {
    final rng = math.Random(seed);
    final start = DateTime.now();
    int ms() => DateTime.now().difference(start).inMilliseconds;
    final choiceBefore = GStorage.setting.get(SettingBoxKey.subtitleChoice);
    await GStorage.setting.put(SettingBoxKey.subtitleChoice, 'zh');
    try {
      final PlPlayerController player;
      if (target.startsWith('yt:')) {
        final id = target.substring(3);
        unawaited(Get.toNamed('/ytVideo', parameters: {'id': id}));
        await Future.delayed(const Duration(seconds: 4));
        final page = Get.find<YtVideoController>(tag: id);
        for (var i = 0; i < 40 && page.stage.value != .ready; i++) {
          await Future.delayed(const Duration(seconds: 1));
        }
        player = page.plPlayerController;
      } else {
        await PiliScheme.routePushFromUrl(target);
        await Future.delayed(const Duration(seconds: 3));
        final page = Get.find<VideoDetailController>(
          tag: Get.parameters['heroTag'] ?? Get.arguments?['heroTag'],
        );
        for (var i = 0; i < 40 && !page.videoState.value; i++) {
          await Future.delayed(const Duration(seconds: 1));
        }
        player = page.plPlayerController;
      }
      String mpv(String name) {
        try {
          return player.videoPlayerController?.getProperty(name) ?? '';
        } catch (_) {
          return '';
        }
      }

      // the first time the picture moves: what the viewer waits for
      int? playingMs;
      final startPos = player.position.value;
      // how the open went: every change of status, buffering and position
      final openStates = <String>[];
      String? lastState;
      var nudged = false;
      for (var i = 0; i < 600 && playingMs == null; i++) {
        final state =
            '${player.playerStatus.value.name} buf=${player.isBuffering.value} pos=${mpv('time-pos')}';
        if (state.split(' pos=').first != lastState?.split(' pos=').first) {
          openStates.add('${ms()} ms $state');
        }
        lastState = state;
        if (player.playerStatus.isPlaying &&
            !player.isBuffering.value &&
            (double.tryParse(mpv('time-pos')) ?? 0) > startPos + 0.5) {
          playingMs = ms();
        }
        if (i == 100 && !player.playerStatus.isPlaying) {
          nudged = true;
          await player.play();
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
      // what the viewer is looking at when nothing plays
      final failedShot = playingMs == null ? await _shot('open-failed') : null;
      final timeline = <Map<String, Object?>>[];
      String? lastPage;
      void sample() {
        final status = Ctl.status();
        final pages = status['pages'] as List? ?? const [];
        final page = pages.isEmpty ? null : pages.first as Map;
        final text = mpv('sub-text').trim();
        final row = <String, Object?>{
          't': ms() ~/ 1000,
          'pos': player.position.value,
          'buffering': player.isBuffering.value,
          'bufferedTo': player.buffered.value,
          'status': player.playerStatus.value.name,
          'sid': mpv('sid'),
          'sub': text.isEmpty
              ? null
              : text.length > 24
              ? text.substring(0, 24)
              : text,
        };
        // what changes rarely, only when it does
        if (page != null) {
          final onDevice = page['onDevice'];
          final keep = <String, Object?>{
            for (final k in const [
              'quality',
              'codec',
              'videoHost',
              'audioHost',
              'subtitles',
              'transcription',
              'translation',
            ])
              k: page[k],
            'onDevice': onDevice is Map
                ? {
                    for (final e in onDevice.entries)
                      if (e.key != 'menu') e.key: e.value,
                  }
                : null,
          };
          final encoded = jsonEncode(keep);
          if (encoded != lastPage) {
            row['page'] = keep;
            lastPage = encoded;
          }
        }
        timeline.add(row);
      }

      Future<void> watch(int seconds) async {
        for (var i = 0; i < seconds; i++) {
          await Future.delayed(const Duration(seconds: 1));
          sample();
        }
      }

      final seeks = <Map<String, Object?>>[];
      Future<void> seek(String kind, int to) async {
        final from = player.position.value;
        final bufferedTo = player.buffered.value;
        final at = ms();
        // as the arrow keys and the progress bar seek (without waiting for
        // a buffer update first)
        await player.seekTo(Duration(seconds: to), isSeek: false);
        int? movedMs;
        int? subMs;
        String? firstSub;
        for (var i = 0; i < 300 && (movedMs == null || subMs == null); i++) {
          await Future.delayed(const Duration(milliseconds: 100));
          final pos = double.tryParse(mpv('time-pos')) ?? -1;
          if (movedMs == null &&
              !player.isBuffering.value &&
              player.playerStatus.isPlaying &&
              pos > to + 0.3) {
            movedMs = ms() - at;
          }
          final text = mpv('sub-text').trim();
          if (subMs == null && text.isNotEmpty && (pos - to).abs() < 30) {
            subMs = ms() - at;
            firstSub = text.length > 24 ? text.substring(0, 24) : text;
          }
          if (i % 10 == 9) sample();
        }
        seeks.add({
          'kind': kind,
          'from': from,
          'to': to,
          'bufferedToBefore': bufferedTo,
          'beyondBuffer': to > bufferedTo,
          'msToMoving': movedMs,
          'msToSubtitle': subMs,
          'firstSub': firstSub,
          'landedAt': player.position.value,
        });
      }

      int between(int a, int b) => a + rng.nextInt(b - a + 1);
      await watch(between(50, 80));
      await seek('forward10', player.position.value + 10);
      await watch(between(45, 70));
      await seek('back10', math.max(0, player.position.value - 10));
      await watch(between(45, 70));
      // past what is buffered, well inside the video
      final duration = player.duration.value;
      final buffered = player.buffered.value;
      final room = duration - 90 - buffered;
      final far = room > 60
          ? buffered + 60 + rng.nextInt(room - 60)
          : math.max(buffered + 30, duration ~/ 2);
      await seek('unbuffered', far);
      await watch(60);
      final events = [
        for (final (_, line) in EventLog.entries(since: start)) line,
      ];
      return {
        'pass':
            playingMs != null && seeks.every((s) => s['msToMoving'] != null),
        'target': target,
        'seed': seed,
        'duration': duration,
        'msToPlaying': playingMs,
        'failedShot': failedShot,
        'openStates': openStates,
        'playPressedByProbe': nudged,
        'seeks': seeks,
        'timeline': timeline,
        'events': events,
      };
    } finally {
      if (choiceBefore == null) {
        await GStorage.setting.delete(SettingBoxKey.subtitleChoice);
      } else {
        await GStorage.setting.put(SettingBoxKey.subtitleChoice, choiceBefore);
      }
      Get.back();
      await Future.delayed(const Duration(seconds: 2));
    }
  }

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

  /// LibrePili: where does a reply page keep its "show more" token?
  ///
  /// The thread panel reported no next page for a thread whose own label
  /// says it has 962 replies, so either the token is somewhere the comments
  /// parser does not look, or there is genuinely only one page. This reads
  /// the raw response rather than guessing between the two.
  static Future<Map<String, dynamic>> _ytReplies(String input) async {
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    final source = YtDirectSource.create();
    final router = YtSourceRouter(source);

    final related = await router.run(
      (s) => (s as YtDirectSource).related(videoId),
    );
    final commentsToken = related.value?.commentsToken;
    if (commentsToken == null) {
      return {'pass': false, 'reason': 'no comments token'};
    }
    final page = await router.run(
      (s) => (s as YtDirectSource).comments(commentsToken),
    );
    final thread = page.value?.items.firstWhereOrNull((c) => c.hasReplies);
    if (thread == null) {
      return {'pass': false, 'reason': 'no thread with replies'};
    }

    // the raw JSON of the reply continuation, read directly
    final raw = await source.client.nextContinuation(thread.replyToken!);
    final json = raw.json;
    final parsed = parseComments(json);

    final triggers = <String, int>{};
    for (final r in collectObjects(json, 'continuationItemRenderer')) {
      final trigger = (r['trigger'] ?? '(none)').toString();
      triggers[trigger] = (triggers[trigger] ?? 0) + 1;
    }
    final buttonTokens = <String>[];
    for (final b in collectObjects(json, 'buttonRenderer')) {
      final tokens = collectContinuationTokens(b);
      if (tokens.isNotEmpty) {
        buttonTokens.add(readText(b['text']).trim());
      }
    }

    return {
      'pass': true,
      'threadLabel': thread.replyCountText,
      'repliesParsed': parsed.items.length,
      'parsedContinuation': parsed.continuation != null,
      'allTokens': collectContinuationTokens(json).length,
      'continuationItemTriggers': triggers,
      'buttonsWithTokens': buttonTokens,
      'hasCommentThreadRenderer': collectObjects(
        json,
        'commentThreadRenderer',
      ).isNotEmpty,
    };
  }

  /// LibrePili: download a YouTube video and check the file is one playable
  /// mp4, not two halves with an extension.
  ///
  /// The two adaptive streams are remuxed by the same pure-Dart [Mp4Remuxer]
  /// the bilibili downloads use, so "it finished" is not the question — the
  /// question is whether the container it wrote has both tracks and a
  /// duration. That is read back out of the file.
  static Future<Map<String, dynamic>> _ytDownload(
    String input, {
    bool keep = false,
  }) async {
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
      if (!keep) {
        try {
          File(file).deleteSync();
        } catch (_) {}
      }
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

  /// LibrePili: does importing PiliPlus's preferences find them and land
  /// them in our box?
  ///
  /// Safe to run: --selftest has its own profile, so the writes go to the
  /// self test's settings box and not the user's. That isolation is also
  /// why the *source* path is searched for rather than computed — the
  /// profile is one directory deeper here than in a normal run, and a fixed
  /// number of parents would be right for one and wrong for the other.
  static Future<Map<String, dynamic>> _importSettings() async {
    final box = SettingsImport.findBox();
    if (box == null) {
      return {
        'pass': false,
        'reason': 'no PiliPlus box on this machine',
        'searchedFrom': appSupportDirPath,
      };
    }
    // the value that started all this: 字号, which PiliPlus had at 1.2 and
    // this app had never written at all
    final before = Pref.defaultTextScale;
    final result = await SettingsImport.run();
    final after = Pref.defaultTextScale;
    return {
      'pass': result.imported > 0,
      'source': box.path,
      'imported': result.imported,
      'skipped': result.skipped,
      'textScaleBefore': before,
      'textScaleAfter': after,
      'textScaleChanged': before != after,
    };
  }

  /// LibrePili: can every settings group actually be opened?
  ///
  /// The settings list is a hardcoded array; the group *types* are an enum
  /// with exhaustive switches over them. Adding a type and wiring the
  /// switches satisfies the analyser completely and still leaves the group
  /// with no way in — which is exactly what happened to the YouTube one.
  /// Nothing but opening each entry can tell.
  static Future<Map<String, dynamic>> _settingsReachable() async {
    unawaited(Get.toNamed('/setting'));
    await Future.delayed(const Duration(seconds: 2));

    final missing = <String>[];
    final unopened = <String>[];
    for (final type in SettingType.values) {
      if (!_seesText(type.title)) {
        missing.add(type.title);
        continue;
      }
      if (!await _tapText(type.title)) {
        unopened.add(type.title);
        continue;
      }
      await Future.delayed(const Duration(milliseconds: 500));
      // the group's own page shows its title; on a wide window it replaces
      // the right-hand pane instead of pushing, so both are accepted
      final opened =
          Get.currentRoute.contains('setting') || _seesText(type.title);
      if (!opened) unopened.add(type.title);
      if (Get.currentRoute != '/setting') {
        Get.back();
        await Future.delayed(const Duration(milliseconds: 400));
      }
    }

    Get.back();
    await Future.delayed(const Duration(milliseconds: 500));
    return {
      'pass': missing.isEmpty && unopened.isEmpty,
      'groups': SettingType.values.length,
      // a type the enum has but the list does not offer: unreachable
      'missingFromList': missing,
      'couldNotOpen': unopened,
    };
  }

  /// LibrePili: every caption track a YouTube video ships, written to disk
  /// as WebVTT, one file per track.
  ///
  /// For the translation benchmark: an author's track in another language
  /// is a human reference translation, and the automatic track is a clean
  /// source to set against our own recognised text.
  /// Loads a translation model in the app process itself and translates a
  /// few fixed lines, recording memory at each step.
  ///
  /// The benchmarks ran the model in a separate llama-server; this is the
  /// same model through the path the app uses (llamadart, patched), which is
  /// the only way to see what the app will actually hold — including whether
  /// weight repacking is really off on a phone: with it on, anonymous memory
  /// after loading grows by about 1.8 GB.
  static Future<Map<String, dynamic>> _translateProbe(String gguf) async {
    Map<String, Object?> memory() {
      if (Platform.isAndroid || Platform.isLinux) {
        final status = File('/proc/self/status').readAsLinesSync();
        int? kb(String key) => int.tryParse(
          status
              .firstWhere((l) => l.startsWith('$key:'), orElse: () => '')
              .replaceAll(RegExp(r'[^0-9]'), ''),
        );
        return {
          'rssMb': (kb('VmRSS') ?? 0) ~/ 1024,
          'anonMb': (kb('RssAnon') ?? 0) ~/ 1024,
          'fileMb': (kb('RssFile') ?? 0) ~/ 1024,
        };
      }
      return {'rssMb': ProcessInfo.currentRss ~/ (1024 * 1024)};
    }

    const lines = [
      'My name is Kate. I am a designer.',
      "But it's not really usable without this extra layer of instruction.",
      '私はこの提案に賛成しません。',
      '実は今日は朝早く起きることに成功して、セントラルパークに行くんです。',
      // as long as a unit of recognised speech usually is on a phone
      // (about 20 s, 11 units in V8's 5 minutes; noisy-speech §18)
      "I want to be upfront about this, because I don't want you to get the "
          'wrong idea of what the experience actually felt like. It looked '
          "packed in real time, but the pace really wasn't that fast, and "
          'between the rounds there was a lot of waiting around while they '
          'fixed the robots and swapped out the batteries.',
    ];
    final before = memory();
    final loadWatch = Stopwatch()..start();
    final engine = await LlamaTranslationEngine.load(gguf);
    final loadMs = loadWatch.elapsedMilliseconds;
    final loaded = memory();
    final outputs = <Map<String, Object?>>[];
    try {
      for (final line in lines) {
        final watch = Stopwatch()..start();
        final reply = await engine.complete(
          translationPrompt(line, target: 'zh'),
        );
        outputs.add({
          'source': line,
          'reply': reply,
          'cleaned': cleanTranslation(reply, source: line),
          'ms': watch.elapsedMilliseconds,
          if (engine.lastStats case final stats?)
            'stats': {
              'promptTokens': stats.promptTokens,
              'replyTokens': stats.replyTokens,
              'firstMs': stats.firstMs,
              'totalMs': stats.totalMs,
            },
        });
      }
    } finally {
      await engine.dispose();
    }
    final translated = memory();
    return {
      'pass': outputs.every((o) => o['cleaned'] != null),
      'model': gguf,
      'useExtraBuffers': LlamaTranslationEngine.repacks,
      'loadMs': loadMs,
      'memoryBefore': before,
      'memoryLoaded': loaded,
      'memoryAfterDispose': translated,
      'outputs': outputs,
    };
  }

  /// The models page's performance test (本地模型 → 性能测试), run the same
  /// way with no UI: the installed models — or those under [asrModels] and
  /// the GGUF [translationFile], for a phone test build with none of its own
  /// — timed alone and together, the advice the page would show, and the
  /// progress it reported. The result is not stored as the page's.
  static Future<Map<String, dynamic>> _benchModels({
    String? asrModels,
    String? translationFile,
  }) async {
    ModelBenchProgress? last;
    final labels = <String>[];
    final bench = ModelBench(
      asrStore: asrModels == null
          ? null
          : AsrModelStore(root: Directory(asrModels)),
      translationFile: translationFile,
      // unattended: a screen that turns off must not end it
      stopInBackground: false,
      onProgress: (p) {
        last = p;
        if (labels.isEmpty || labels.last != p.label) labels.add(p.label);
      },
    );
    _progress = () => {'fraction': last?.fraction, 'label': last?.label};
    final result = await bench.run();
    return {
      // measured something and finished: an install with no models passes
      // as a test of that path, with the advice saying so
      'pass': result.complete,
      'result': result.toJson(),
      'advice': [
        for (final a in benchAdvice(
          result,
          preferred: TranslationModelCatalog.platformDefault.id,
        ))
          {'level': a.level.name, 'text': a.text},
      ],
      'details': [
        for (final (label, value) in benchDetails(result)) '$label：$value',
      ],
      'steps': labels,
    };
  }

  static Future<Map<String, dynamic>> _dumpCaptions(
    String input,
    String dir,
  ) async {
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    final router = YtSourceRouter(YtDirectSource.create());
    final detail = (await router.run((s) => s.detail(videoId))).value;
    if (detail == null) return {'pass': false, 'reason': 'no detail'};
    await Directory(dir).create(recursive: true);
    // the video's own words about itself: what a translator would be told
    // as background when the question is whether knowing the topic helps
    await File(path.join(dir, '$videoId.meta.json')).writeAsString(
      jsonEncode({'title': detail.title, 'description': detail.description}),
    );
    final written = <Map<String, Object?>>[];
    for (final track in detail.captionTracks) {
      final body = (await router.run((s) => s.captionContent(track))).value;
      final name =
          '$videoId.${track.languageCode}${track.isAutomatic ? '.auto' : ''}.vtt';
      if (body != null) {
        await File(path.join(dir, name)).writeAsString(body);
      }
      written.add({
        'file': name,
        'language': track.languageCode,
        'automatic': track.isAutomatic,
        'cues': body == null ? 0 : _parseVtt(body).length,
      });
    }
    return {
      'pass': written.any((w) => (w['cues'] as int) > 0),
      'videoId': videoId,
      'dir': dir,
      'tracks': written,
    };
  }

  /// LibrePili: what bilibili's player API actually returns for a video's
  /// subtitle list, anonymously.
  ///
  /// Written because "the list is empty" was reported as "you need to log
  /// in", which is a mechanism claim the empty list alone does not support:
  /// a risk-controlled request, an unsigned one and a genuinely captionless
  /// video all look identical from the parsed model. This dumps the raw
  /// response so the three can be told apart.
  static Future<Map<String, dynamic>> _biliSubtitles(String input) async {
    final bvid = IdUtils.bvRegex.firstMatch(input)?.group(0) ?? input;
    final intro = await VideoHttp.videoIntro(bvid: bvid);
    final detail = intro.dataOrNull;
    final cid = detail?.cid;
    if (cid == null) {
      return {
        'pass': false,
        'reason': 'no cid',
        'introState': intro.runtimeType.toString(),
        'introError': intro is Error ? intro.errMsg : null,
      };
    }

    // Which request shape actually returns the list. The app's own call
    // came back `code: 0` with `subtitles: []`, which rules out risk control
    // and a bad signature but not a wrong endpoint or a missing parameter —
    // so try the shapes the web player is known to use and report all of
    // them rather than concluding from one.
    final aid = detail?.aid;
    final attempts = <String, Map<String, Object>>{
      'wbi/v2 bvid+cid': {'bvid': bvid, 'cid': cid},
      if (aid != null) 'wbi/v2 aid+cid': {'aid': aid, 'cid': cid},
      'wbi/v2 +web_location': {
        'bvid': bvid,
        'cid': cid,
        'web_location': 1315873,
        'isGaiaAvoided': true,
      },
      if (aid != null)
        'wbi/v2 aid+bvid+cid +web_location': {
          'aid': aid,
          'bvid': bvid,
          'cid': cid,
          'web_location': 1315873,
        },
    };
    final tried = <Map<String, Object?>>[];
    Response<dynamic>? best;
    for (final attempt in attempts.entries) {
      final signed = await WbiSign.makSign(attempt.value);
      final r = await Request().get(Api.playInfo, queryParameters: signed);
      final body = r.data;
      final Object? env = body is Map ? body['data'] : null;
      final Object? sub = env is Map ? env['subtitle'] : null;
      final Object? list = sub is Map ? sub['subtitles'] : null;
      final count = list is List ? list.length : -1;
      tried.add({
        'shape': attempt.key,
        'code': body is Map ? body['code'] : null,
        'trackCount': count,
      });
      if (count > 0 && best == null) best = r;
    }
    // the plain (unsigned) endpoint, which older clients use
    final plain = await Request().get(
      '/x/player/v2',
      queryParameters: {'bvid': bvid, 'cid': cid, 'aid': ?aid},
    );
    {
      final body = plain.data;
      final Object? env = body is Map ? body['data'] : null;
      final Object? sub = env is Map ? env['subtitle'] : null;
      final Object? list = sub is Map ? sub['subtitles'] : null;
      tried.add({
        'shape': 'player/v2 (unsigned)',
        'code': body is Map ? body['code'] : null,
        'trackCount': list is List ? list.length : -1,
      });
      if (list is List && list.isNotEmpty && best == null) best = plain;
    }

    // Hypothesis: the anonymous request is missing `bili_ticket`.
    //
    // The app makes up its own buvid3 and activates it, but never asks for
    // the ticket the web front-end obtains on load. If that is what gates
    // the list, fetching one and retrying should change the count — and if
    // it does not, the ticket is not the reason and the empty list means
    // this video really has no tracks for an anonymous caller.
    String? ticketError;
    int? countWithTicket;
    try {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final sign = Hmac(
        sha256,
        utf8.encode('XgwSnGZ1p'),
      ).convert(utf8.encode('ts$ts')).toString();
      final ticketRes = await Request().post(
        'https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket',
        queryParameters: {
          'key_id': 'ec02',
          'hexsign': sign,
          'context[ts]': '$ts',
          'csrf': '',
        },
      );
      final body = ticketRes.data;
      final Object? env = body is Map ? body['data'] : null;
      final ticket = env is Map ? env['ticket'] as String? : null;
      if (ticket == null || ticket.isEmpty) {
        ticketError =
            'no ticket in response: ${body is Map ? body['code'] : body}';
      } else {
        final signed = await WbiSign.makSign({'bvid': bvid, 'cid': cid});
        final retry = await Request().get(
          Api.playInfo,
          queryParameters: signed,
          options: Options(headers: {'Cookie': 'bili_ticket=$ticket'}),
        );
        final rb = retry.data;
        final Object? renv = rb is Map ? rb['data'] : null;
        final Object? rsub = renv is Map ? renv['subtitle'] : null;
        final Object? rlist = rsub is Map ? rsub['subtitles'] : null;
        countWithTicket = rlist is List ? rlist.length : -1;
        tried.add({
          'shape': 'wbi/v2 + bili_ticket',
          'code': rb is Map ? rb['code'] : null,
          'trackCount': countWithTicket,
        });
        if (rlist is List && rlist.isNotEmpty && best == null) best = retry;
      }
    } catch (e) {
      ticketError = '$e';
    }

    // The path the app's video page actually uses when the REST list comes
    // back empty and nobody is logged in: the gRPC DmView interface. The
    // probe never called it, which is the whole reason "anonymous cannot get
    // the list" looked true — the app gets it, just not from this endpoint.
    List<Map<String, Object?>>? grpcTracks;
    String? grpcError;
    if (aid != null) {
      final view = await DmGrpc.dmView(aid, cid);
      switch (view) {
        case Success(:final response):
          grpcTracks = response.hasSubtitle()
              ? [
                  for (final t in response.subtitle.subtitles)
                    {
                      'lan': t.lan,
                      'lan_doc': t.lanDoc,
                      'isAi': t.type == SubtitleType.AI,
                      'hasUrl': t.subtitleUrl.isNotEmpty,
                    },
                ]
              : const [];
        case Error(:final errMsg):
          grpcError = errMsg;
        case Loading():
          grpcError = 'still loading';
      }
    }

    final res = best ?? plain;
    final data = res.data;
    // spelled out rather than chained: `a ? b?['c'] : d` parses the `?[` as
    // the start of another conditional and fails to compile
    final Object? envelope = data is Map ? data['data'] : null;
    final Object? subtitle = envelope is Map ? envelope['subtitle'] : null;
    final Object? tracks = subtitle is Map ? subtitle['subtitles'] : null;

    return {
      'pass':
          (tracks is List && tracks.isNotEmpty) ||
          (grpcTracks?.isNotEmpty ?? false),
      'bvid': bvid,
      'cid': cid,
      'loggedIn': Accounts.main.isLogin,
      // the envelope says which of the three cases this is
      'code': data is Map ? data['code'] : null,
      'message': data is Map ? data['message'] : null,
      'bodyIsHtml': data is String && data.trimLeft().startsWith('<'),
      'attempts': tried,
      'ticketError': ticketError,
      'trackCountWithTicket': countWithTicket,
      'grpcDmViewTracks': grpcTracks,
      'grpcDmViewCount': grpcTracks?.length,
      'grpcError': grpcError,
      'subtitleKeys': subtitle is Map ? subtitle.keys.toList() : null,
      'trackCount': tracks is List ? tracks.length : null,
      'tracks': tracks is List
          ? [
              for (final t in tracks.cast<Map>())
                {
                  'lan': t['lan'],
                  'lan_doc': t['lan_doc'],
                  'type': t['type'],
                  'hasUrl': (t['subtitle_url'] as String?)?.isNotEmpty == true,
                },
            ]
          : null,
    };
  }

  /// LibrePili: how long a real transcription takes to put its first
  /// subtitle on screen, and whether it still reaches the end of the audio.
  ///
  /// Runs the service the app runs, not a copy of it: the thing being
  /// measured is the overlap between extraction and recognition, and a probe
  /// that re-implemented that overlap would only prove its own copy works.
  ///
  /// Two numbers matter and they pull against each other. The first cue used
  /// to wait for the whole audio to be pulled — minutes on a throttled CDN.
  /// Reading a file while it is still being written fixes that, and the way
  /// it goes wrong is silent: the reader stops at the first empty read and
  /// the rest of the video is never transcribed, with no error anywhere. So
  /// the tail is checked as well as the latency.
  static Future<Map<String, dynamic>> _asrLatency(String input) async {
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    final router = YtSourceRouter(YtDirectSource.create());
    final detail = (await router.run((s) => s.detail(videoId))).value;
    final streams = await router.run((s) => s.streams(videoId));
    final audioUrl = streams.value?.audioUrl;
    if (audioUrl == null || audioUrl.isEmpty) {
      return {'pass': false, 'reason': 'no audio stream'};
    }
    final durationSeconds = (detail?.duration.inSeconds ?? 0).toDouble();

    final service = AsrService.to;
    if (!service.modelsReady) {
      return {'pass': false, 'reason': 'models missing'};
    }

    final started = DateTime.now();
    int? firstCueMs;
    final session = await service.start(
      key: 'probe:$videoId',
      source: audioUrl,
    );
    final sub = session.cues.listen((_) {
      firstCueMs ??= DateTime.now().difference(started).inMilliseconds;
    });

    // the run is over when the service says so; cap it so a stall reports a
    // stall rather than hanging the probe
    final deadline = started.add(const Duration(minutes: 30));
    while (session.state.value.isBusy && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    final doneMs = DateTime.now().difference(started).inMilliseconds;
    await sub.cancel();

    final cues = session.cues.toList();
    final lastCueEnd = cues.isEmpty ? 0.0 : cues.last.to;
    await service.stop();

    // the failure this exists to catch: transcription that ends early.
    // Anything more than a closing stretch of silence unaccounted for means
    // the reader stopped while the decoder was still writing.
    final tailGap = durationSeconds - lastCueEnd;
    return {
      'pass':
          cues.isNotEmpty &&
          firstCueMs != null &&
          (durationSeconds == 0 || tailGap < durationSeconds * 0.1),
      'videoId': videoId,
      'durationSeconds': durationSeconds,
      'msToFirstCue': firstCueMs,
      'msToDone': doneMs,
      // what the old design would have cost: nothing could appear before the
      // whole stream had been pulled
      'stage': session.state.value.stage.name,
      'cueCount': cues.length,
      'lastCueEndSeconds': lastCueEnd,
      'tailGapSeconds': tailGap,
      'cueStats': _cueStats(cues, durationSeconds),
    };
  }

  /// LibrePili: transcription and translation together, the way the player
  /// page runs them, up to the subtitles it would publish.
  ///
  /// The page itself is not opened: this drives the same service and the
  /// same [TranslationTrack] the page does, with a simulated playhead that
  /// starts when the translation is first ready (the page holds playback
  /// until then) and moves in real time for [watchSeconds]. What it checks is
  /// what a viewer would see: how long until the first translated line, and
  /// whether any line they reach during playback is still waiting.
  ///
  /// [gguf] imports the model if it is not installed yet (checked against
  /// the pinned hash like any import).
  static Future<Map<String, dynamic>> _translateLatency(
    String input,
    String? gguf,
    int watchSeconds,
  ) async {
    final translations = TranslationService.to;
    if (!translations.modelReady && gguf != null) {
      await translations.store.importFile(
        File(gguf),
        models: TranslationModelCatalog.all,
      );
    }
    if (!translations.modelReady) {
      return {'pass': false, 'reason': 'translation model missing'};
    }
    final asr = AsrService.to;
    if (!asr.modelsReady)
      return {'pass': false, 'reason': 'asr models missing'};
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    final router = YtSourceRouter(YtDirectSource.create());
    final streams = await router.run((s) => s.streams(videoId));
    final audioUrl = streams.value?.audioUrl;
    if (audioUrl == null || audioUrl.isEmpty) {
      return {'pass': false, 'reason': 'no audio stream'};
    }

    final started = DateTime.now();
    int ms() => DateTime.now().difference(started).inMilliseconds;
    DateTime? playFrom;
    double position() => playFrom == null
        ? 0
        : DateTime.now().difference(playFrom!).inMilliseconds / 1000;
    int? readyMs;
    int? firstPublishMs;
    String? failure;
    String? lastVtt;
    final publishes = <Map<String, Object?>>[];
    // what the viewer reaches while watching: a waiting line at the playhead
    // is the failure this exists to catch
    var waitingSeen = 0;
    var samples = 0;

    final track = TranslationTrack(
      position: position,
      onPublish: (vtt, {required first}) {
        firstPublishMs ??= ms();
        lastVtt = vtt;
        publishes.add({
          'ms': ms(),
          'position': position(),
          'waiting': translationPendingMark.allMatches(vtt).length,
        });
      },
      onReady: () {
        readyMs ??= ms();
        playFrom ??= DateTime.now();
      },
      onFailed: (message) => failure = message,
    );
    final session = await asr.start(key: 'probe:$videoId', source: audioUrl);
    Worker? languageWorker;
    languageWorker = ever(session.state, (state) {
      if (state.language != null && track.session.value == null) {
        if (translations.needed(state.language)) track.start(session);
        languageWorker?.dispose();
      }
    });

    // until ready, capped the way the page caps its gate
    while (readyMs == null && failure == null && ms() < 30000) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    playFrom ??= DateTime.now();
    final end = DateTime.now().add(Duration(seconds: watchSeconds));
    while (DateTime.now().isBefore(end) && failure == null) {
      await Future.delayed(const Duration(seconds: 1));
      final vtt = lastVtt;
      if (vtt == null) continue;
      final now = position();
      samples++;
      if (_vttLineAt(vtt, now)?.contains(translationPendingMark) ?? false) {
        waitingSeen++;
      }
    }
    final current = track.session.value;
    final result = {
      'pass':
          failure == null &&
          readyMs != null &&
          firstPublishMs != null &&
          waitingSeen == 0,
      'videoId': videoId,
      'language': session.state.value.language,
      'msToReady': readyMs,
      'msToFirstPublish': firstPublishMs,
      'failure': failure,
      'watchedSeconds': position(),
      'secondsShowingWaitingLine': waitingSeen,
      'sampledSeconds': samples,
      'publishCount': publishes.length,
      'publishes': publishes,
      'units': current?.units.length,
      'translatedUnits': current?.results.values
          .where((r) => r.text != null)
          .length,
      'failedUnits': current?.results.values
          .where((r) => r.text == null)
          .length,
      'sample': current == null
          ? null
          : [
              for (final cue in current.cues().take(12))
                {'from': cue.from, 'to': cue.to, 'content': cue.content},
            ],
    };
    await track.stop();
    await asr.stop();
    return result;
  }

  /// LibrePili: the whole transcript and the whole translation of a local
  /// media [file], through the same service and [TranslationTrack] the page
  /// uses, written to [out] (JSON): the transcript as shown, the translated
  /// track as last handed to the player, and each translation unit with its
  /// source text and result.
  ///
  /// [_translateLatency] watches the first minute and a half as a viewer;
  /// this asks for everything (as a save does) so a whole stretch can be
  /// compared with a reference — burned-in subtitles, for one.
  ///
  /// A `.srt`/`.vtt` [file] is translated as a video's own captions, in the
  /// language [from] (`--translate-from`): the same model with nothing to
  /// recognise, which tells translation errors from recognition ones.
  static Future<Map<String, dynamic>> _translateFile(
    String file,
    String? out, {
    String? from,
  }) async {
    final translations = TranslationService.to;
    if (!translations.modelReady || !AsrService.to.modelsReady) {
      return {'pass': false, 'reason': 'models missing'};
    }
    final clock = Stopwatch()..start();
    String? failure;
    String? lastVtt;
    // the playhead stays at the start: every line past the lead comes from
    // the full coverage asked for below
    final track = TranslationTrack(
      position: () => 0,
      onPublish: (vtt, {required first}) => lastVtt = vtt,
      onReady: () {},
      onFailed: (message) => failure = message,
    );
    // a caption file (.srt/.vtt) takes the captions path instead: the same
    // model given a transcript nobody had to recognise
    if (RegExp(r'\.(srt|vtt)$', caseSensitive: false).hasMatch(file)) {
      final cues = parseCaptionCues(await File(file).readAsString());
      await track.startCaptions(cues, from: from);
      final session = track.session.value;
      if (session == null) return {'pass': false, 'reason': 'no session'};
      // everything, not only the lead ahead of a playhead that never moves
      session.requestFullCoverage();
      final deadline = DateTime.now().add(const Duration(minutes: 60));
      while (!session.translatedAll &&
          failure == null &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      await Future.delayed(const Duration(seconds: 2));
      final report = <String, dynamic>{
        'pass': failure == null && session.translatedAll,
        'file': file,
        'captions': cues.length,
        'model': translations.model.id,
        'ms': clock.elapsedMilliseconds,
        'failure': failure,
        // answers not in the language asked for: asked again, and failed
        'languageRetries': session.languageRetries,
        'languageFailures': session.languageFailures,
        'units': [
          for (final u in session.units)
            {
              'from': u.from,
              'to': u.to,
              'text': u.text,
              'result': session.results[u.key]?.text,
            },
        ],
        'translated': [
          for (final c in session.cues(markPending: false))
            {'from': c.from, 'to': c.to, 'content': c.content},
        ],
      };
      await track.stop();
      if (out != null) {
        await File(out).writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
        );
      }
      return {
        for (final e in report.entries)
          if (e.value is! List) e.key: e.value,
        'units': (report['units'] as List).length,
      };
    }
    final asr = await AsrService.to.start(
      key: 'selftest-translate-file',
      source: file,
      cache: SubtitleCacheKey.local(file),
    );
    final deadline = DateTime.now().add(const Duration(minutes: 60));
    while (asr.state.value.language == null &&
        asr.state.value.isBusy &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    await track.start(asr);
    final session = track.session.value;
    if (session == null) {
      await AsrService.to.stop(only: asr);
      return {'pass': false, 'reason': 'no translation session'};
    }
    session.requestFullCoverage();
    while (!session.translatedAll &&
        failure == null &&
        DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    session.endFullCoverage();
    // the final publish comes with the last result; give it its turn
    await Future.delayed(const Duration(seconds: 2));
    final report = <String, dynamic>{
      'pass': failure == null && session.translatedAll,
      'file': file,
      'language': asr.state.value.language,
      'model': translations.model.id,
      // what the subtitle cache gave (design 2026-09-26, 9B): the seconds
      // of transcript and the translations kept from before, and the
      // recogniser runs and model loads it took after
      'cachedSeconds': asr.cachedSeconds,
      'recogniserRuns': asr.runCount,
      'modelLoads': session.modelLoads,
      'unitsModel': session.units
          .where(
            (u) =>
                TranslationService.routeFor(u.language, translations.target) ==
                UnitRoute.model,
          )
          .length,
      'ms': clock.elapsedMilliseconds,
      'failure': failure,
      'languageRetries': session.languageRetries,
      'languageFailures': session.languageFailures,
      'transcript': [
        for (final c in asr.cues.toList().displayed)
          {'from': c.from, 'to': c.to, 'content': c.content},
      ],
      'segments': [
        for (final s in asr.segments)
          {'start': s.start, 'duration': s.duration},
      ],
      'units': [
        for (final u in session.units)
          {
            'from': u.from,
            'to': u.to,
            'text': u.text,
            'result': session.results[u.key]?.text,
          },
      ],
      'translated': [
        for (final c in session.cues(markPending: false))
          {'from': c.from, 'to': c.to, 'content': c.content},
      ],
      'vtt': lastVtt,
    };
    await track.stop();
    await AsrService.to.stop(only: asr);
    // what the cache got, on disk before the process ends
    await AsrService.to.cache.flush();
    if (out != null) {
      await File(out).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
    }
    return {
      for (final e in report.entries)
        if (e.value is! List && e.key != 'vtt') e.key: e.value,
      'units': (report['units'] as List).length,
    };
  }

  /// LibrePili: translation through the YouTube player page itself — the
  /// menu's path, picking 中文（端侧） ([YtVideoController.showTranslation])
  /// — and what the player ends up showing.
  ///
  /// [_translateLatency] drives the service and track without a page; this
  /// checks the wiring it skips: the page starting transcription for a
  /// translation, starting the translation once the language is known, and
  /// handing the player the translated track in place of the transcript.
  static Future<Map<String, dynamic>> _translatePage(
    String input,
    int holdSeconds, {
    required bool auto,
    String? into,
  }) async {
    // the language picked from the menu: the app's, or one under 其他语言
    final language = into ?? AsrService.appLanguage;
    if (!TranslationService.to.modelReady || !AsrService.to.modelsReady) {
      return {'pass': false, 'reason': 'models missing'};
    }
    await _setSwitch(auto ? language : SubtitleChoice.off);
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    final started = DateTime.now();
    unawaited(Get.toNamed('/ytVideo', parameters: {'id': videoId}));
    await Future.delayed(const Duration(seconds: 2));
    final controller = Get.find<YtVideoController>(tag: videoId);
    final watch = _GateWatch(
      controller.asrPending,
      controller.asrGateSkippable,
      started,
      shot: 'yt_gate_$videoId',
      pageOpenedAt: () => controller.gateOpenedAt,
      pageSkippableAt: () => controller.gateSkippableAt,
    );
    int? gateOpenedMs;
    int? gateClosedMs;
    final gate = ever(controller.asrPending, (pending) {
      final ms = DateTime.now().difference(started).inMilliseconds;
      if (pending) {
        gateOpenedMs ??= ms;
      } else if (gateOpenedMs != null) {
        gateClosedMs ??= ms;
      }
    });
    // it may have started waiting before the listener was attached
    if (controller.asrPending.value) {
      gateOpenedMs ??= DateTime.now().difference(started).inMilliseconds;
    }
    for (var i = 0; i < 20 && controller.stage.value != .ready; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    final ownCaptions = [
      for (final c in controller.captions)
        '${c.languageCode}${c.isAutomatic ? '(auto)' : ''}',
    ];
    // the menu's path: picking the language (its name, the default source)
    if (!auto) {
      await controller.chooseLanguage(language, controller.planFor(language));
    }
    int? firstTranslatedMs;
    final shown = <String>[];
    for (var i = 0; i < holdSeconds; i++) {
      await Future.delayed(const Duration(seconds: 1));
      final track = controller
          .plPlayerController
          .videoPlayerController
          ?.state
          .track
          .subtitle;
      final title = track?.title;
      if (title == onDeviceLabel(language)) {
        firstTranslatedMs ??= DateTime.now().difference(started).inMilliseconds;
      }
      if (shown.isEmpty || shown.last != '$title') shown.add('$title');
    }
    gate.dispose();
    watch.dispose();
    final session = controller.translation.session.value;
    final translated = session?.results.values
        .map((r) => r.text)
        .whereType<String>()
        .toList();
    // into Chinese, some of it must read as Chinese; into another language
    // there is no such cheap check, and a translation at all has to do
    final inLanguage = language == 'zh'
        ? translated?.any((t) => RegExp(r'[一-鿿]').hasMatch(t)) ?? false
        : translated?.isNotEmpty ?? false;
    final result = {
      'pass':
          firstTranslatedMs != null &&
          inLanguage &&
          controller.captionIndex.value == -2,
      'into': language,
      'sampleTranslations': translated?.take(3).toList(),
      'videoId': videoId,
      'mode': auto ? 'auto' : 'menu',
      'videoOwnCaptions': ownCaptions,
      // the video's own captions when it has foreign ones, else a transcript
      'translated': controller.asrSession.value == null
          ? 'captions'
          : 'transcript',
      'gateOpenedMs': gateOpenedMs,
      'gateClosedMs': gateClosedMs,
      'gate': watch.toJson(),
      'menu': [for (final r in OnDeviceMenu.rowsFor(controller)) r.toJson()],
      'asrLanguage': controller.asrSession.value?.state.value.language,
      'translationStage': session?.state.value.stage.name,
      'msToTranslatedTrack': firstTranslatedMs,
      'subtitleTracksShown': shown,
      'captionIndex': controller.captionIndex.value,
      'translatedUnits': translated?.length,
      'sample': translated?.take(4).toList(),
    };
    await controller.stopAsr();
    Get.back();
    return result;
  }

  /// `--yt-steps VIDEO --steps off,asr,zh [--step-hold N]`: the subtitle
  /// menu picked in order, as a viewer clicks it, N seconds apart — and after
  /// each pick, what is on screen and what the menu says (user 2026-09-30:
  /// 关闭 → 原文 → 中文 left English on screen and 中文 doing nothing).
  static Future<Map<String, dynamic>> _ytSteps(
    String input,
    List<String> steps,
    int holdSeconds,
  ) async {
    await _setSwitch(SubtitleChoice.off);
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    unawaited(Get.toNamed('/ytVideo', parameters: {'id': videoId}));
    await Future.delayed(const Duration(seconds: 2));
    final controller = Get.find<YtVideoController>(tag: videoId);
    for (var i = 0; i < 20 && controller.stage.value != .ready; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    await controller.plPlayerController.play();
    Map<String, Object?> snapshot() {
      final session = controller.translation.session.value;
      return {
        'subtitleOnScreen': controller
            .plPlayerController
            .videoPlayerController
            ?.state
            .track
            .subtitle
            .title,
        'captionIndex': controller.captionIndex.value,
        'translationActive': controller.translation.isActive,
        'translationStage': session?.state.value.stage.name,
        'translatedUnits': session?.results.values
            .where((r) => r.text != null)
            .length,
        'asrStage': controller.asrSession.value?.state.value.stage.name,
        'position': controller.plPlayerController.position.value,
        'menu': [
          for (final r in OnDeviceMenu.rowsFor(controller))
            {
              'label': r.label,
              'checked': r.checked,
              'status': r.status?.text,
            },
        ],
      };
    }

    final out = <Map<String, Object?>>[
      {'step': 'opened', ...snapshot()},
    ];
    for (final step in steps) {
      // `asr@device` / `zh@platform`: the row's source icon, as tapped
      final parts = step.split('@');
      final code = parts.first;
      final via = parts.length > 1
          ? SubtitleSourcePreference.values
                .where((v) => v.name == parts[1])
                .firstOrNull
          : null;
      if (code == 'off') {
        await controller.chooseOff();
      } else {
        await controller.chooseLanguage(
          code,
          controller.planFor(code, via: via),
        );
      }
      await Future.delayed(Duration(seconds: holdSeconds));
      out.add({'step': step, ...snapshot()});
    }
    await controller.stopAsr();
    Get.back();
    final last = out.last;
    return {
      'pass':
          !steps.last.startsWith('zh') ||
          last['subtitleOnScreen'] == onDeviceLabel('zh'),
      'videoId': videoId,
      'steps': out,
    };
  }

  /// `--ctl-probe FILE [--hold N] [--hold-off M]`: the command-line reader
  /// (CtlServer) against a page that is transcribing. The setting is turned
  /// on in this profile's own storage, FILE opens in the page's local mode
  /// and its transcript is asked for from the menu's path; the run then
  /// holds N seconds with the reader serving, so `librepili_ctl.py
  /// --profile NAME status` can be run against it from outside, and M more
  /// with the setting turned off again (no ctl.json).
  ///
  /// It also asks itself, so the run passes or fails on its own: a request
  /// without the token is refused, and `/status` shows the file's page with
  /// its transcription moving.
  static Future<Map<String, dynamic>> _ctlProbe(
    String file, {
    required int hold,
    required int holdOff,
  }) async {
    if (!AsrService.to.modelsReady) {
      return {'pass': false, 'reason': 'models missing'};
    }
    await GStorage.setting.putAll({
      SettingBoxKey.ctlServer: true,
      // nothing starts by itself: the transcript is asked for below
      SettingBoxKey.subtitleChoice: SubtitleChoice.off,
    });
    await Ctl.apply(true);
    final served = Ctl.servedFile;
    if (served == null) return {'pass': false, 'reason': 'not serving'};
    final port = served['port'] as int;
    final token = served['token'] as String;
    final ctlFile = File(path.join(appSupportDirPath, 'ctl.json'));

    Future<(int, Object?)> ask(String route, {bool withToken = true}) async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port$route'),
        );
        if (withToken) {
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        return (response.statusCode, jsonDecode(body));
      } finally {
        client.close(force: true);
      }
    }

    const tag = 'selftest_ctl_local';
    unawaited(LocalPlayer.open(file, heroTag: tag));
    VideoDetailController? page;
    for (var i = 0; i < 20 && page == null; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        page = Get.find<VideoDetailController>(tag: tag);
      } catch (_) {}
    }
    if (page == null) return {'pass': false, 'reason': 'no page'};
    for (var i = 0; i < 20 && !page.videoState.value; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    // the menu's path to 原文（端侧）
    await page.showTranscript();
    EventLog.add('selftest', 'ctl probe: serving on $port for $hold s');

    final (refused, _) = await ask('/status', withToken: false);
    final (healthCode, _) = await ask('/health', withToken: false);
    // the transcription stage as /status reports it, each change once
    final stages = <String>[];
    Map? lastPage;
    final labels = <String>{};
    for (var i = 0; i < hold; i++) {
      final (code, status) = await ask('/status');
      if (code == 200 && status is Map) {
        final top = (status['pages'] as List).firstOrNull as Map?;
        if (top != null) {
          lastPage = top;
          final stage =
              (top['transcription'] as Map?)?['stage'] as String? ?? 'none';
          if (stages.isEmpty || stages.last != stage) stages.add(stage);
          for (final row in (top['onDevice'] as Map)['menu'] as List) {
            labels.add((row as Map)['text'] as String);
          }
        }
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    final (logCode, log) = await ask('/log');
    final (settingsCode, settings) = await ask('/settings');

    // off again: the server closes and its file goes
    await GStorage.setting.put(SettingBoxKey.ctlServer, false);
    await Ctl.apply(false);
    final fileGone = !ctlFile.existsSync();
    var refusedAfterOff = false;
    try {
      await ask('/health', withToken: false);
    } on SocketException {
      refusedAfterOff = true;
    }
    EventLog.add('selftest', 'ctl probe: reader off, holding $holdOff s');
    await Future.delayed(Duration(seconds: holdOff));

    final result = {
      'pass':
          refused == HttpStatus.unauthorized &&
          healthCode == 200 &&
          lastPage?['platform'] == 'local' &&
          stages.length >= 2 &&
          logCode == 200 &&
          (((log as Map?)?['count'] as int?) ?? 0) > 0 &&
          settingsCode == 200 &&
          !(jsonEncode(settings).contains('cookie')) &&
          fileGone &&
          refusedAfterOff,
      'port': port,
      'statusWithoutToken': refused,
      'health': healthCode,
      'stagesSeen': stages,
      'menuLabelsSeen': labels.toList(),
      'lastTranscription': lastPage?['transcription'],
      'title': lastPage?['title'],
      'logLines': (log as Map?)?['count'],
      'settingsKeys': (settings as Map?)?.length,
      'fileGoneWhenOff': fileGone,
      'refusedWhenOff': refusedAfterOff,
    };
    await page.stopAsr();
    Get.back();
    return result;
  }

  /// [_translatePage] on the bilibili page, which keeps a track list: the
  /// translation should arrive as its own 翻译 track after the transcript's,
  /// and be the one selected.
  ///
  /// With [auto] nothing is requested: automatic transcription and
  /// translation are switched on (in the self-test profile's own settings)
  /// and the page is left to start them itself, which is also the only way
  /// to see its loading gate hold for the translation.
  static Future<Map<String, dynamic>> _translatePageBili(
    String url,
    int holdSeconds, {
    required bool auto,
    String? into,
  }) async {
    final language = into ?? AsrService.appLanguage;
    if (!TranslationService.to.modelReady || !AsrService.to.modelsReady) {
      return {'pass': false, 'reason': 'models missing'};
    }
    await _setSwitch(auto ? language : SubtitleChoice.off);
    final opened = DateTime.now();
    int ms() => DateTime.now().difference(opened).inMilliseconds;
    // a local file: the page's local mode, where the video's own subtitles
    // are the files beside it (`<name>.<lang>.srt`)
    const localTag = 'selftest_translate_local';
    final local = File(url).existsSync();
    if (local) {
      unawaited(LocalPlayer.open(url, heroTag: localTag));
    } else {
      await PiliScheme.routePushFromUrl(url);
    }
    VideoDetailController? controller;
    for (var i = 0; i < 20 && controller == null; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        controller = Get.find<VideoDetailController>(
          tag: local
              ? localTag
              : Get.parameters['heroTag'] ?? Get.arguments?['heroTag'],
        );
      } catch (_) {
        if (local) continue;
        try {
          controller = Get.find<VideoDetailController>();
        } catch (_) {}
      }
    }
    if (controller == null) {
      return {'pass': false, 'reason': 'the page never opened'};
    }
    final page = controller;
    final watch = _GateWatch(
      page.asrPending,
      page.asrGateSkippable,
      opened,
      shot: 'bili_gate',
      pageOpenedAt: () => page.gateOpenedAt,
      pageSkippableAt: () => page.gateSkippableAt,
    );
    // how long the page holds itself in loading for the subtitles
    int? gateOpenedMs;
    int? gateClosedMs;
    final gate = ever(page.asrPending, (pending) {
      if (pending) {
        gateOpenedMs ??= ms();
      } else if (gateOpenedMs != null) {
        gateClosedMs ??= ms();
      }
    });
    if (page.asrPending.value) gateOpenedMs ??= ms();
    for (var i = 0; i < 20 && !page.videoState.value; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    final ownSubtitles = [for (final s in page.subtitles) s.lanDoc];
    // `--comments-first`: the comments are being translated (the same
    // model) when the subtitles are asked for, as a viewer may well do
    Future<Map<String, Object?>>? comments;
    if (debugCommentsFirst) {
      comments = _commentsProbe(page);
      await Future.delayed(const Duration(seconds: 2));
    }
    // the menu's path: picking the language (its name, the default source)
    // shows it, making it first
    if (!auto) await page.chooseLanguage(language, page.planFor(language));

    int? translatedTrackMs;
    int? selectedMs;
    // every 5 s, how far ahead of the viewer the transcript and its
    // translation are: whether the two keep up with playback
    final timeline = <Map<String, Object?>>[];
    for (var i = 0; i < holdSeconds; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (i % 5 == 4) {
        final asr = page.asrSession.value;
        final tr = page.translation.session.value;
        final at = page.plPlayerController.position.value.toDouble();
        timeline.add({
          'ms': ms(),
          'playhead': at,
          'buffering': page.plPlayerController.isBuffering.value,
          'asrStage': asr?.state.value.stage.name,
          'asrTo': asr?.transcript.coveredEnd(at),
          'asrSpeed': asr?.pace.speed,
          'translationStage': tr?.state.value.stage.name,
          'translatedTo': tr?.settledFrom(at),
          'translatedUnits': tr?.results.values.where((r) => !r.passed).length,
        });
      }
      final index = page.subtitles.indexWhere(
        (s) =>
            s.source == SubtitleSource.device &&
            s.lan == 'asr-translated' &&
            s.lanDoc == onDeviceLabel(language),
      );
      if (index >= 0) {
        translatedTrackMs ??= ms();
        if (page.vttSubtitlesIndex.value == index + 1) selectedMs ??= ms();
      }
    }
    gate.dispose();
    watch.dispose();
    final session = page.translation.session.value;
    // by the model, and shown as they are — already in the language asked
    // for (design 2026-09-26, 2A)
    final translated = session?.results.values
        .where((r) => !r.passed)
        .map((r) => r.text)
        .whereType<String>()
        .toList();
    final passed = session?.results.values
        .where((r) => r.passed)
        .map((r) => r.source)
        .toList();
    final result = {
      'pass':
          translatedTrackMs != null &&
          selectedMs != null &&
          ((translated?.isNotEmpty ?? false) || (passed?.isNotEmpty ?? false)),
      if (comments != null)
        'comments': await comments.timeout(
          const Duration(seconds: 60),
          onTimeout: () => {'error': 'comments still translating after 60 s'},
        ),
      'subtitleLabel': page.menuStatus(language)?.text,
      'translationStarting':
          page.translation.isActive && page.translation.session.value == null,
      'mode': auto ? 'auto' : 'menu',
      'timeline': timeline,
      'local': local,
      'videoOwnSubtitles': ownSubtitles,
      // the video's own subtitles when foreign ones exist, else a transcript
      'translated': page.asrSession.value == null ? 'captions' : 'transcript',
      'asrLanguage': page.asrSession.value?.state.value.language,
      'asrStage': page.asrSession.value?.state.value.stage.name,
      'translationStage': session?.state.value.stage.name,
      'gateOpenedMs': gateOpenedMs,
      'gateClosedMs': gateClosedMs,
      'gate': watch.toJson(),
      'menu': [for (final r in OnDeviceMenu.rowsFor(page)) r.toJson()],
      'msToTranslatedTrack': translatedTrackMs,
      'msToSelected': selectedMs,
      'tracks': [for (final s in page.subtitles) s.lanDoc],
      'selected': page.vttSubtitlesIndex.value,
      // the start of what the player was handed for it, as shown
      'shownVtt': switch (page.vttSubtitles[page.vttSubtitlesIndex.value - 1]) {
        (isData: true, :final id) =>
          id.length > 600 ? id.substring(0, 600) : id,
        _ => null,
      },
      'translatedUnits': translated?.length,
      'passedUnits': passed?.length,
      // whether the translation model was loaded at all: speech already in
      // the language asked for should never load it
      'modelLoaded': (session?.modelLoads ?? 0) > 0,
      'sample': translated?.take(4).toList(),
      'passedSample': passed?.take(4).toList(),
    };
    await page.stopAsr();
    Get.back();
    return result;
  }

  /// `--keepgoing-probe <file|BV…>`: automatic transcription (the
  /// "foreign videos" mode, which used to give up) on speech in the app's
  /// own language does not stop (design 2026-09-26, 3): the session never
  /// goes idle, and its transcript keeps growing after the language is
  /// known — where it used to end the run there and forget the language.
  /// Watched until the session is done, or for [seconds].
  static Future<Map<String, dynamic>> _keepGoingProbe(
    String video, {
    int seconds = 90,
  }) async {
    if (!AsrService.to.modelsReady) {
      return {'pass': false, 'reason': 'models missing'};
    }
    await GStorage.setting.putAll({
      // the speech as it is, remembered: what used to be automatic
      // transcription alone (design 2026-09-26, 1B)
      SettingBoxKey.subtitleChoice: SubtitleChoice.original,
      // a fresh profile does not play by itself, and a page that does not
      // play never resolves what it would transcribe
      SettingBoxKey.autoPlayEnable: true,
    });
    // a file: the page's local mode, with no platform subtitles in the way
    const localTag = 'selftest_keepgoing_local';
    final local = File(video).existsSync();
    if (local) {
      unawaited(LocalPlayer.open(video, heroTag: localTag));
    } else {
      await PiliScheme.routePushFromUrl(
        'https://www.bilibili.com/video/$video',
      );
    }
    VideoDetailController? page;
    for (var i = 0; i < 20 && page == null; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        page = Get.find<VideoDetailController>(
          tag: local
              ? localTag
              : Get.parameters['heroTag'] ?? Get.arguments?['heroTag'],
        );
      } catch (_) {}
    }
    if (page == null) return {'pass': false, 'reason': 'no page'};
    final clock = Stopwatch()..start();
    final stages = <String>[];
    String? language;
    int? cuesAtLanguage;
    int? msToLanguage;
    AsrSession? session;
    while (clock.elapsed < Duration(seconds: seconds)) {
      await Future.delayed(const Duration(milliseconds: 250));
      session = page.asrSession.value ?? session;
      final state = session?.state.value;
      final name = state?.stage.name ?? 'none';
      if (stages.isEmpty || stages.last != name) stages.add(name);
      if (language == null && state?.language != null) {
        language = state!.language;
        cuesAtLanguage = session!.cues.length;
        msToLanguage = clock.elapsedMilliseconds;
      }
      if (state?.stage == AsrStage.done ||
          state?.stage == AsrStage.failed ||
          (state?.stage == AsrStage.idle && (session?.runCount ?? 0) > 0)) {
        break;
      }
    }
    final state = session?.state.value;
    final cues = session?.cues.length ?? 0;
    final result = {
      // started by itself, never idle once running, the language found is
      // the app's own, and text kept coming after it was found
      'pass':
          session != null &&
          session.runCount > 0 &&
          !stages.contains(AsrStage.idle.name) &&
          !session.hasEnded &&
          language != null &&
          AsrService.isSameMajorLanguage(language, AsrService.appLanguage) &&
          cuesAtLanguage != null &&
          cues > cuesAtLanguage,
      'video': video,
      'asrStages': stages,
      'detectedLanguage': language,
      'msToLanguage': msToLanguage,
      'cuesAtLanguage': cuesAtLanguage,
      'cuesAtEnd': cues,
      'stageAtEnd': state?.stage.name,
      'languageAtEnd': state?.language,
      'runs': session?.runCount,
      'coveredSeconds': session?.coveredSeconds,
      'duration': session?.duration,
      'ms': clock.elapsedMilliseconds,
      'labelOriginal': page.menuStatus('asr')?.text,
      'tracks': [for (final t in page.subtitles) t.lanDoc],
    };
    await page.stopAsr();
    Get.back();
    return result;
  }

  /// The remembered subtitle switch, in the self-test profile's own
  /// settings (the profile has its own storage; the user's are not
  /// touched). Always set: the profile keeps it, and a menu run after an
  /// automatic one was found starting by itself.
  static Future<void> _setSwitch(String choice) =>
      GStorage.setting.put(SettingBoxKey.subtitleChoice, choice);

  /// Where `--shots` puts screenshots of the app, if anywhere.
  static String? _shots;

  /// The app's window as it is drawn now, as a PNG at [name] under
  /// [_shots]. From the root layer, so the window may be at the bottom of
  /// the z-order (see SelfTestWindow); what a platform texture shows (the
  /// video) may come out black. The path written, or null.
  /// `--models-page DIR`: the models page (with the optional English model)
  /// and the licence it comes under, as screenshots in DIR.
  static Future<Map<String, dynamic>> _modelsPage() async {
    unawaited(Get.to(() => const LocalModelsPage()));
    await Future.delayed(const Duration(seconds: 2));
    final page = await _shot('models_page');
    final english = _seesText('英语识别（可选）');
    final notice = _seesText(AsrModelCatalog.parakeet.licence!.notice);
    final context = Get.context;
    String? licence;
    if (context != null && context.mounted) {
      unawaited(AsrEntry.showLicence(context, AsrModelCatalog.parakeet));
      await Future.delayed(const Duration(seconds: 1));
      licence = await _shot('models_licence');
      Get.back();
      await Future.delayed(const Duration(milliseconds: 400));
    }
    Get.back();
    return {
      'pass': english && notice,
      'englishGroup': english,
      'notice': notice,
      'shots': [page, licence],
    };
  }

  /// The performance test as the models page runs it, with the profile's
  /// own models: started from its button, run to the end, its advice and
  /// 详细数据 shown and kept; then started again and left at once, which
  /// must stop it and keep the first result as the page's.
  static Future<Map<String, dynamic>> _benchModelsUi() async {
    // on a short window the card is below the fold: brought into view, as
    // a user scrolling to it would
    Future<void> reveal(String label) async {
      if (_findElement(_isText(label)) case final element?) {
        await Scrollable.ensureVisible(element, alignment: 0.5);
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    Future<void> openPage() async {
      unawaited(Get.to(() => const LocalModelsPage()));
      await Future.delayed(const Duration(seconds: 2));
      await reveal('开始测试');
      await reveal('重新测试');
    }

    Future<bool> waitFor(String label, Duration limit) async {
      final end = DateTime.now().add(limit);
      while (DateTime.now().isBefore(end)) {
        if (_seesText(label)) return true;
        await Future.delayed(const Duration(milliseconds: 250));
      }
      return false;
    }

    await openPage();
    final before = Pref.modelBench;
    final started = await _tapText('开始测试') || await _tapText('重新测试');
    final running = _seesText('取消测试');
    final finished = await waitFor('重新测试', const Duration(minutes: 3));
    final kept = Pref.modelBench;
    final advice = _seesLabel('翻译：') || _seesLabel('语音转录模型未下载');
    await reveal('详细数据');
    await _tapText('详细数据');
    final details = _seesLabel('语音转录（SenseVoice）');
    await reveal('详细数据');
    final shot = await _shot('bench_result');
    Get.back();
    await Future.delayed(const Duration(milliseconds: 600));

    // again, and away before it ends
    await openPage();
    final again = await _tapText('重新测试');
    await Future.delayed(const Duration(seconds: 3));
    final stillRunning = _seesText('取消测试');
    Get.back();
    await Future.delayed(const Duration(seconds: 3));
    final afterLeave = Pref.modelBench;
    return {
      'pass':
          started &&
          finished &&
          kept != null &&
          kept != before &&
          advice &&
          details &&
          again &&
          afterLeave == kept,
      'started': started,
      'runningShown': running,
      'finished': finished,
      'stored': kept != null && kept != before,
      'adviceShown': advice,
      'detailsShown': details,
      'secondStarted': again,
      'secondStillRunningAt3s': stillRunning,
      'keptAfterLeaving': afterLeave == kept,
      'stored_json': kept,
      'shots': [shot],
      'benchLog': [
        for (final line in EventLog.recent)
          if (line.contains('[bench]')) line,
      ],
    };
  }

  static Future<String?> _shot(String name, {bool whole = false}) async {
    final dir = _shots;
    if (dir == null) return null;
    try {
      await WidgetsBinding.instance.endOfFrame;
      final view = WidgetsBinding.instance.renderViews.first;
      final layer = view.debugLayer! as OffsetLayer;
      // the root layer draws in physical pixels: bounds in logical ones cut
      // a window at 125 % scaling down to its left 80 % (measured: a
      // 1086-logical-wide page came out showing 869 of it)
      final image = await layer.toImage(
        Offset.zero & view.flutterView.physicalSize,
      );
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File(path.join(dir, '$name.png'));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
      return file.path;
    } catch (e) {
      return 'failed: $e';
    }
  }

  /// `--remembered-probe FILE [--hold-off N] [--hold M] [--shots DIR]`: the
  /// remembered switch across videos (design 2026-09-26, phases 4/5). FILE
  /// opens in the page's local mode, which has no platform subtitles:
  /// 1. the switch remembered at the app's language: the video starts
  ///    making its subtitles with no menu action, behind the loading gate;
  /// 2. 关闭字幕 from the menu's path: remembered off, the transcription
  ///    winds down;
  /// 3. the next video (FILE again, on a new page) starts nothing in N s;
  /// 4. the language picked again from the menu's path: the transcription
  ///    never goes idle, and speech in the language needs no model — every
  ///    translated unit passes through.
  static Future<Map<String, dynamic>> _rememberedProbe(
    String file, {
    required int offHold,
    required int hold,
  }) async {
    if (!AsrService.to.modelsReady || !TranslationService.to.modelReady) {
      return {'pass': false, 'reason': 'models missing'};
    }
    final language = AsrService.appLanguage;
    await GStorage.setting.putAll({
      SettingBoxKey.subtitleChoice: language,
      // a fresh profile does not play by itself, and a page that does not
      // play never resolves what it would transcribe
      SettingBoxKey.autoPlayEnable: true,
    });

    Future<VideoDetailController?> open(String tag) async {
      unawaited(LocalPlayer.open(file, heroTag: tag));
      for (var i = 0; i < 20; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          return Get.find<VideoDetailController>(tag: tag);
        } catch (_) {}
      }
      return null;
    }

    // 1. remembered: starts by itself
    final opened = DateTime.now();
    int ms() => DateTime.now().difference(opened).inMilliseconds;
    final first = await open('selftest_remembered_1');
    if (first == null) return {'pass': false, 'reason': 'no page'};
    final watch = _GateWatch(
      first.asrPending,
      first.asrGateSkippable,
      opened,
      shot: 'remembered_gate',
      pageOpenedAt: () => first.gateOpenedAt,
      pageSkippableAt: () => first.gateSkippableAt,
    );
    int? sessionMs, translationMs, selectedMs;
    for (var i = 0; i < 120 && selectedMs == null; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (first.asrSession.value != null) sessionMs ??= ms();
      if (first.translation.isActive) translationMs ??= ms();
      if (first.onDeviceShown == language) selectedMs ??= ms();
    }
    watch.dispose();
    final step1 = {
      'pass': sessionMs != null && selectedMs != null,
      'msToSession': sessionMs,
      'msToTranslation': translationMs,
      'msToShown': selectedMs,
      'gate': watch.toJson(),
      'menuPicked': first.menuPicked,
      'menu': [for (final r in OnDeviceMenu.rowsFor(first)) r.toJson()],
    };

    // 2. 关闭字幕: remembered, and what the device made winds down
    final firstSession = first.asrSession.value;
    await first.chooseOff();
    await Future.delayed(const Duration(seconds: 3));
    final step2 = {
      'pass':
          Pref.subtitleChoice == SubtitleChoice.off &&
          first.vttSubtitlesIndex.value == 0 &&
          !first.translation.isActive &&
          (firstSession == null ||
              firstSession.isSwitchedOff ||
              firstSession.state.value.stage == AsrStage.done),
      'remembered': Pref.subtitleChoice,
      'selected': first.vttSubtitlesIndex.value,
      'asrStage': firstSession?.state.value.stage.name,
      'switchedOff': firstSession?.isSwitchedOff,
      'translationActive': first.translation.isActive,
      'label': first.menuStatus('asr')?.text,
    };
    Get.back();
    await Future.delayed(const Duration(seconds: 2));

    // 3. the next video, with the switch off: nothing starts
    final second = await open('selftest_remembered_2');
    if (second == null) {
      return {'pass': false, 'reason': 'no second page', 'step1': step1};
    }
    var started = false;
    for (var i = 0; i < offHold * 4; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (second.asrSession.value != null || second.translation.isActive) {
        started = true;
      }
    }
    final step3 = {
      'pass': !started && second.vttSubtitlesIndex.value <= 0,
      'startedSomething': started,
      'pendingGate': second.asrPending.value,
      'selected': second.vttSubtitlesIndex.value,
      'menuPicked': second.menuPicked,
    };

    // 4. the language again, from the menu's path
    final stages = <String>[];
    final repicked = DateTime.now();
    await second.chooseLanguage(language, second.planFor(language));
    AsrSession? session;
    int? shownMs;
    final clock = Stopwatch()..start();
    while (clock.elapsed < Duration(seconds: hold)) {
      await Future.delayed(const Duration(milliseconds: 250));
      session = second.asrSession.value ?? session;
      final name = session?.state.value.stage.name ?? 'none';
      if (stages.isEmpty || stages.last != name) stages.add(name);
      if (second.onDeviceShown == language) {
        shownMs ??= DateTime.now().difference(repicked).inMilliseconds;
      }
      if (session?.state.value.stage == AsrStage.done && shownMs != null) {
        // what is left to translate settles on the next ticks
        await Future.delayed(const Duration(seconds: 2));
        break;
      }
    }
    final results = second.translation.session.value?.results.values ?? [];
    final passed = results.where((r) => r.passed).length;
    final step4 = {
      'pass':
          session != null &&
          !stages.contains(AsrStage.idle.name) &&
          shownMs != null &&
          results.isNotEmpty &&
          passed == results.length &&
          (second.translation.session.value?.modelLoads ?? 0) == 0,
      'asrStages': stages,
      'msToShown': shownMs,
      'units': results.length,
      'passedUnits': passed,
      'modelLoads': second.translation.session.value?.modelLoads,
      'runs': session?.runCount,
      'cues': session?.cues.length,
      'label': second.menuStatus(language)?.text,
      'remembered': Pref.subtitleChoice,
    };
    await second.stopAsr();
    Get.back();
    return {
      'pass':
          step1['pass'] == true &&
          step2['pass'] == true &&
          step3['pass'] == true &&
          step4['pass'] == true,
      'file': file,
      'language': language,
      'step1RememberedStartsByItself': step1,
      'step2OffFromMenu': step2,
      'step3NextVideoStartsNothing': step3,
      'step4RepickedFromMenu': step4,
    };
  }

  /// `--switch-probe FILE [--off-at N] [--hold M]`: the switch turned off
  /// and on mid-video on the page (design 2026-09-26, 4). With 原文
  /// remembered, FILE (long enough to outlast the wind-down window) starts
  /// transcribing by itself; at N s 关闭字幕 from the menu's path winds it
  /// down — it goes on to a mark past the playhead, stops there at standby
  /// with 已关闭 — and 原文 picked again resumes the same session.
  static Future<Map<String, dynamic>> _switchProbe(
    String file, {
    required int offAt,
    required int hold,
  }) async {
    if (!AsrService.to.modelsReady) {
      return {'pass': false, 'reason': 'models missing'};
    }
    await GStorage.setting.putAll({
      SettingBoxKey.subtitleChoice: SubtitleChoice.original,
      SettingBoxKey.autoPlayEnable: true,
    });
    const tag = 'selftest_switch';
    unawaited(LocalPlayer.open(file, heroTag: tag));
    VideoDetailController? page;
    for (var i = 0; i < 20 && page == null; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        page = Get.find<VideoDetailController>(tag: tag);
      } catch (_) {}
    }
    if (page == null) return {'pass': false, 'reason': 'no page'};
    final clock = Stopwatch()..start();
    String now() => (clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
    final timeline = <String>[];
    String? last;
    void note() {
      final s = page!.asrSession.value;
      final line =
          '${s?.state.value.stage.name ?? 'none'}'
          '${s?.isSwitchedOff ?? false ? ' off' : ''}'
          '${s?.isWoundDown ?? false ? ' wound' : ''}'
          ' | ${page.menuStatus('asr')?.text}';
      if (line != last) timeline.add('${now()} s: $line');
      last = line;
    }

    while (clock.elapsed < Duration(seconds: offAt)) {
      await Future.delayed(const Duration(milliseconds: 250));
      note();
    }
    final session = page.asrSession.value;
    if (session == null) {
      return {'pass': false, 'reason': 'nothing started', 'timeline': timeline};
    }
    final playheadAtOff = page.plPlayerController.position.value;
    final coveredAtOff = session.coveredSeconds;
    await page.chooseOff();
    final mark = session.windDownUntil;
    timeline.add('${now()} s: 关闭字幕, mark ${mark?.toStringAsFixed(1)}');
    while (clock.elapsed < Duration(seconds: offAt + hold) &&
        !session.isWoundDown &&
        session.state.value.stage != AsrStage.done) {
      await Future.delayed(const Duration(milliseconds: 250));
      note();
    }
    final coveredEndAtWound = session.transcript.coveredEnd(
      playheadAtOff.toDouble(),
    );
    final woundStage = session.state.value.stage;
    final woundLabel = page.menuStatus('asr')?.text;
    final runsAtWound = session.runCount;
    // a while switched off: nothing new runs
    await Future.delayed(const Duration(seconds: 5));
    note();
    final runsAfterIdle = session.runCount;
    final coveredWhileOff = session.coveredSeconds;

    // 原文 again
    await page.chooseLanguage('asr', page.planFor('asr'));
    timeline.add('${now()} s: 原文 picked again');
    final resumedAt = clock.elapsed;
    var leftStandby = false;
    while (clock.elapsed - resumedAt < const Duration(seconds: 30)) {
      await Future.delayed(const Duration(milliseconds: 250));
      note();
      final stage = session.state.value.stage;
      if (stage == AsrStage.transcribing ||
          stage == AsrStage.extracting ||
          stage == AsrStage.done) {
        leftStandby = true;
        if (session.coveredSeconds > coveredWhileOff + 5 ||
            stage == AsrStage.done) {
          break;
        }
      }
    }
    final result = {
      'pass':
          !session.isWoundDown &&
          woundStage == AsrStage.standby &&
          (woundLabel?.startsWith(asrWoundDownMessage) ?? false) &&
          runsAfterIdle == runsAtWound &&
          identical(page.asrSession.value, session) &&
          !session.isSwitchedOff &&
          leftStandby &&
          session.coveredSeconds > coveredWhileOff,
      'file': file,
      'playheadAtOff': playheadAtOff,
      'coveredAtOff': coveredAtOff,
      'windDownMark': mark,
      'coveredEndAtWoundDown': coveredEndAtWound,
      'stageWoundDown': woundStage.name,
      'labelWoundDown': woundLabel,
      'runsWhileOff': runsAfterIdle - runsAtWound,
      'sameSessionAfterOn': identical(page.asrSession.value, session),
      'leftStandbyAfterOn': leftStandby,
      'coveredWhileOff': coveredWhileOff,
      'coveredAtEnd': session.coveredSeconds,
      'stageAtEnd': session.state.value.stage.name,
      'timeline': timeline,
    };
    await page.stopAsr();
    Get.back();
    return result;
  }

  /// The text of the VTT cue showing at [seconds], if any.
  static String? _vttLineAt(String vtt, double seconds) {
    final time = RegExp(
      r'(\d+):(\d+):(\d+)\.(\d+) --> (\d+):(\d+):(\d+)\.(\d+)\n([\s\S]*?)(?:\n\n|$)',
    );
    double at(Match m, int i) =>
        int.parse(m[i]!) * 3600 +
        int.parse(m[i + 1]!) * 60 +
        int.parse(m[i + 2]!) +
        int.parse(m[i + 3]!) / 1000;
    for (final m in time.allMatches(vtt)) {
      if (at(m, 1) <= seconds && seconds < at(m, 5)) return m[9];
    }
    return null;
  }

  /// LibrePili: how our transcription of a video compares with the
  /// captions YouTube ships for the same one.
  ///
  /// Compared on shape rather than on wording: how many cues, how long each
  /// is on screen, how many characters it carries, how much of the audio
  /// carries a subtitle at all. Those are the properties that were reported
  /// as wrong, and unlike the text they can be put side by side.
  static Future<Map<String, dynamic>> _captionCompare(String input) async {
    // Both platforms ship captions and both can be compared the same way;
    // only the fetching differs. A bilibili link goes down the bilibili path
    // so one flag covers either.
    if (IdUtils.bvRegex.firstMatch(input) case final bv?) {
      return _captionCompareBili(bv.group(0)!);
    }
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    final source = YtDirectSource.create();
    final router = YtSourceRouter(source);

    final info = await router.run((s) => s.detail(videoId));
    final detail = info.value;
    if (detail == null) {
      return {
        'pass': false,
        'reason': 'no detail',
        'verdict': '${info.verdict}',
      };
    }
    final tracks = detail.captionTracks;
    if (tracks.isEmpty) {
      return {'pass': false, 'reason': 'this video ships no captions'};
    }
    // Transcribe FIRST, because which track is a fair baseline depends on
    // what language is being spoken and only the recogniser can say.
    final streams = await router.run((s) => s.streams(videoId));
    final audioUrl = streams.value?.audioUrl;
    if (audioUrl == null || audioUrl.isEmpty) {
      return {'pass': false, 'reason': 'no audio stream'};
    }
    final ours = await _asr(audioUrl);
    final durationSeconds = detail.duration.inSeconds.toDouble();

    // Both kinds, where the video has both. "视频自带" and "平台生成" are
    // different things and the question was about both: an author's track is
    // hand-written and usually the better-typeset one, the automatic track
    // is the one guaranteed to be a transcript of the speech.
    final spoken = ours['language'] as String?;
    final chosen = _baselinesFor(
      tracks,
      isAutomatic: (t) => t.isAutomatic,
      languageOf: (t) => t.languageCode,
      spoken: spoken,
    );
    final baselines = <Map<String, Object?>>[];
    for (final candidate in chosen) {
      final t = candidate.track;
      final content = await router.run((s) => s.captionContent(t));
      final cues = content.value == null
          ? const <AsrCue>[]
          : _parseVtt(content.value!);
      baselines.add({
        'kind': candidate.kind,
        'track':
            '${t.languageCode} ${t.name}'
            '${t.isAutomatic ? ' (auto)' : ''}',
        'cueCount': cues.length,
        'script': cues.isEmpty ? null : _scriptMix(cues),
        'stats': cues.isEmpty ? null : _cueStats(cues, durationSeconds),
      });
    }
    if (baselines.isEmpty) {
      return {'pass': false, 'reason': 'caption fetch failed'};
    }
    // the primary one stays the transcript where there is one
    final picked = chosen.first;
    final track = picked.track;
    final primary = await router.run((s) => s.captionContent(track));
    final theirs = primary.value == null
        ? const <AsrCue>[]
        : _parseVtt(primary.value!);

    return {
      'pass': ours['pass'] == true && theirs.isNotEmpty,
      'videoId': videoId,
      'durationSeconds': durationSeconds,
      'theirTrack':
          '${track.languageCode} ${track.name}'
          '${track.isAutomatic ? ' (auto)' : ''}',
      'baselineChosenBy': picked.kind,
      'baselineMayBeTranslation': picked.mayBeTranslation,
      // every track worth measuring against, not just the chosen one
      'baselines': baselines,
      // every track, because which one is a transcript and which a
      // translation decides what the comparison means
      'allTracks': [
        for (final t in tracks)
          '${t.languageCode}${t.isAutomatic ? ' (auto)' : ''}'
              '${t.name.isEmpty ? '' : ' ${t.name}'}',
      ],
      'theirCueCount': theirs.length,
      // Which script each side wrote in. The recogniser supports zh/en/ja/
      // ko/yue and picks one; if it picks the wrong one it still produces
      // fluent-looking text, just in the wrong language. Counting characters
      // says which, without putting either transcript side by side.
      'theirScript': _scriptMix(theirs),
      'theirStats': _cueStats(theirs, durationSeconds),
      'ourLanguage': ours['language'],
      'ourCueCount': ours['cueCount'],
      'ourScript': ours['script'],
      'ourStats': ours['cueStats'],
      'ourCoverageVsVad': ours['coverageVsVad'],
      // the text itself, to see WHERE the breaks land — a statistic about
      // line length says nothing about whether a line ends mid-word
      'ourSampleCues': ours['cues'],
      'ourRawTokens': ours['rawTokens'],
      'ourSegments': ours['segments'],
      'ourBuiltCues': ours['builtCues'],
    };
  }

  /// The same comparison for a bilibili video.
  ///
  /// bilibili marks a machine-made track with `type == 1` (`isAi`), which is
  /// the counterpart of YouTube's automatic track: the one guaranteed to be
  /// a transcript rather than a translation. Where a video has both, the AI
  /// track is the baseline for the same reason.
  static Future<Map<String, dynamic>> _captionCompareBili(String bvid) async {
    final intro = await VideoHttp.videoIntro(bvid: bvid);
    final detail = intro.dataOrNull;
    if (detail == null) {
      return {'pass': false, 'reason': 'no detail', 'bvid': bvid};
    }
    final cid = detail.cid;
    if (cid == null) {
      return {'pass': false, 'reason': 'no cid', 'bvid': bvid};
    }

    final info = await VideoHttp.playInfo(bvid: bvid, cid: cid);
    var tracks =
        info.dataOrNull?.subtitle?.subtitles ?? const <bili_sub.Subtitle>[];
    final loggedIn = Accounts.main.isLogin;
    var viaGrpc = false;
    // The same fallback the video page uses. `player/wbi/v2` returns an empty
    // list to an anonymous caller — measured across six request shapes,
    // including one carrying a valid bili_ticket — while the gRPC DmView
    // interface returns the tracks perfectly well without an account. The
    // probe called only the REST endpoint, which is why the list looked
    // unavailable and got written up as "you have to be logged in". It is the
    // other way round: this is the anonymous path, and it works.
    final aid = detail.aid;
    if (tracks.isEmpty && aid != null) {
      final view = await DmGrpc.dmView(aid, cid);
      if (view case Success(:final response) when response.hasSubtitle()) {
        tracks = response.subtitle.subtitles
            .map(
              (i) => bili_sub.Subtitle(
                lan: i.lan,
                lanDoc: i.lanDoc,
                // `getSubtitles` prepends the scheme, as the REST list omits it
                subtitleUrl: i.subtitleUrl.replaceFirst(
                  RegExp('^https?:'),
                  '',
                ),
                isAi: i.type == SubtitleType.AI,
                source: i.type == SubtitleType.AI
                    ? SubtitleSource.platform
                    : SubtitleSource.author,
              ),
            )
            .toList();
        viaGrpc = tracks.isNotEmpty;
      }
    }

    final play = await VideoHttp.videoUrl(
      bvid: bvid,
      cid: cid,
      qn: 64,
      tryLook: true,
      videoType: VideoType.ugc,
    );
    final audioUrl = play.dataOrNull?.dash?.audio?.firstOrNull?.baseUrl;
    if (audioUrl == null || audioUrl.isEmpty) {
      return {'pass': false, 'reason': 'no audio stream', 'bvid': bvid};
    }
    final ours = await _asr(audioUrl);
    final durationSeconds = (detail.duration ?? 0).toDouble();

    List<AsrCue> theirs = const [];
    bili_sub.Subtitle? track;
    String baselineReason = 'no track';
    var mayBeTranslation = false;
    if (tracks.isNotEmpty) {
      final picked = _baselinesFor(
        tracks,
        isAutomatic: (t) => t.isAi,
        languageOf: (t) => t.lan,
        spoken: ours['language'] as String?,
      ).first;
      track = picked.track;
      baselineReason = picked.kind;
      mayBeTranslation = picked.mayBeTranslation;
      final url = track.subtitleUrl;
      if (url != null && url.isNotEmpty) {
        final body = await VideoHttp.getSubtitles(url);
        if (body != null) theirs = _parseVtt(body);
      }
    }

    return {
      'pass': ours['pass'] == true && theirs.isNotEmpty,
      'bvid': bvid,
      'cid': cid,
      'loggedIn': loggedIn,
      // which interface the list came from, so an empty one is never again
      // read as a statement about accounts
      'trackSource': viaGrpc ? 'grpc DmView' : 'rest player/wbi/v2',
      'durationSeconds': durationSeconds,
      'theirTrack': track == null
          ? null
          : '${track.lan} ${track.lanDoc}${track.isAi ? ' (auto)' : ''}',
      'baselineChosenBy': baselineReason,
      'baselineMayBeTranslation': mayBeTranslation,
      'allTracks': [
        for (final t in tracks)
          '${t.lan}${t.isAi ? ' (auto)' : ''} ${t.lanDoc}',
      ],
      'theirCueCount': theirs.length,
      'theirScript': theirs.isEmpty ? null : _scriptMix(theirs),
      'theirStats': theirs.isEmpty ? null : _cueStats(theirs, durationSeconds),
      'ourLanguage': ours['language'],
      'ourCueCount': ours['cueCount'],
      'ourScript': ours['script'],
      'ourStats': ours['cueStats'],
      'ourCoverageVsVad': ours['coverageVsVad'],
    };
  }

  /// Which caption track to measure ours against.
  ///
  /// Only a machine-made track is guaranteed to be a *transcript*. An
  /// author's track is very often a translation, and a translation is in
  /// another language by design — measuring against one and concluding "the
  /// recogniser picked the wrong language" is a conclusion about the
  /// baseline, not about the recogniser. That mistake has now been made
  /// twice: once on a Japanese video whose author uploaded zh/ko/en, and
  /// again on a Chinese one with no automatic track at all, where falling
  /// back to `tracks.first` picked the English translation.
  ///
  /// So: the automatic track where there is one; otherwise the author track
  /// whose language matches what was actually recognised; otherwise the
  /// first, flagged so the numbers are not read as a language verdict.
  static List<({T track, String kind, bool mayBeTranslation})> _baselinesFor<T>(
    List<T> tracks, {
    required bool Function(T) isAutomatic,
    required String Function(T) languageOf,
    required String? spoken,
  }) {
    final out = <({T track, String kind, bool mayBeTranslation})>[];
    if (tracks.firstWhereOrNull(isAutomatic) case final auto?) {
      out.add((track: auto, kind: '平台生成', mayBeTranslation: false));
    }
    // the author's own track in the spoken language: hand-written, and the
    // fair reference for how a subtitle should be broken and timed
    if (spoken != null && spoken.isNotEmpty) {
      final match = tracks.firstWhereOrNull(
        (t) => !isAutomatic(t) && _sameMajorLanguage(languageOf(t), spoken),
      );
      if (match != null) {
        out.add((track: match, kind: '视频自带', mayBeTranslation: false));
      }
    }
    if (out.isEmpty && tracks.isNotEmpty) {
      out.add((
        track: tracks.first,
        kind: '回退（可能是译文）',
        mayBeTranslation: true,
      ));
    }
    return out;
  }

  /// `zh-CN` and `zh` are the same language here; `ai-zh` is bilibili's.
  static bool _sameMajorLanguage(String a, String b) {
    String major(String code) {
      final cleaned = code.toLowerCase().replaceFirst(RegExp(r'^ai-'), '');
      final cut = cleaned.indexOf(RegExp(r'[-_]'));
      return cut == -1 ? cleaned : cleaned.substring(0, cut);
    }

    return AsrService.isSameMajorLanguage(major(a), major(b));
  }

  /// A WebVTT body into cues. Only the timing lines matter here; cue
  /// settings (`align:`, `position:`) and any styling blocks are skipped.
  static List<AsrCue> _parseVtt(String body) {
    final cues = <AsrCue>[];
    final lines = body.replaceAll('\r\n', '\n').split('\n');
    final arrow = RegExp(
      r'(\d{1,2}:\d{2}:\d{2}[.,]\d{1,3}|\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[.,]\d{1,3}|\d{1,2}:\d{2}[.,]\d{1,3})',
    );
    double parse(String stamp) {
      final clean = stamp.replaceAll(',', '.');
      final parts = clean.split(':');
      var seconds = 0.0;
      for (final part in parts) {
        seconds = seconds * 60 + (double.tryParse(part) ?? 0);
      }
      return seconds;
    }

    for (var i = 0; i < lines.length; i++) {
      final match = arrow.firstMatch(lines[i]);
      if (match == null) continue;
      final from = parse(match.group(1)!);
      final to = parse(match.group(2)!);
      final text = StringBuffer();
      for (var j = i + 1; j < lines.length; j++) {
        final line = lines[j].trim();
        if (line.isEmpty || arrow.hasMatch(line)) break;
        if (text.isNotEmpty) text.write(' ');
        // strip the inline timing tags an auto-caption carries
        text.write(
          line
              .replaceAll(RegExp(r'<[^>]*>'), '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim(),
        );
      }
      final content = text.toString().trim();
      if (content.isNotEmpty) {
        cues.add(AsrCue(from: from, to: to, content: content));
      }
    }
    return cues;
  }

  /// LibrePili: open a bilibili video the way a link does, and report what
  /// the player is actually doing.
  ///
  /// Written for "this video will not play": the useful answer is not
  /// whether it failed but *where* — the API refusing, no stream of a usable
  /// quality coming back, the URL resolving but the transport stalling, or
  /// the page throwing while it draws. Each of those looks the same from the
  /// outside and needs a different fix, so each is reported separately.

  /// Comment translation with the real model
  /// (research/comment-translation-design-2026-09-25.md, C2): whether the
  /// marks standing for emotes, @names, timestamps and links come back, what
  /// the translations read like, and how long each takes.
  static Future<Map<String, dynamic>> _commentTranslateProbe() async {
    Content c(
      String message, {
      List<String> emotes = const [],
      List<String> at = const [],
    }) {
      final content = Content(message: message);
      for (final e in emotes) {
        content.emotes[e] = Emote(text: e);
      }
      for (final name in at) {
        content.atNameToMid[name] = Int64(1);
      }
      return content;
    }

    final comments = [
      c('This part at 3:20 is my favourite [doge]', emotes: ['[doge]']),
      c('@小明 you have to watch this, it is amazing', at: ['小明']),
      c('この動画めっちゃ好きです[笑哭]', emotes: ['[笑哭]']),
      c('한국에서 보고 있어요 너무 좋아요'),
      c('Who else is here after the update? 1:02:15 is the best bit'),
      c('The song is https://example.com/song check it out'),
      c("C'est vraiment une très belle vidéo, merci [OK]", emotes: ['[OK]']),
      c('I love how you explained it, thanks!'),
      c(
        '@Alice @Bob look at 12:30 [doge][doge]',
        emotes: ['[doge]'],
        at: ['Alice', 'Bob'],
      ),
      c('Das ist wirklich sehr schön gemacht'),
    ];
    final results = <Map<String, Object?>>[];
    final clock = Stopwatch()..start();
    for (final content in comments) {
      final protected = CommentTranslator.protect(content);
      final started = clock.elapsedMilliseconds;
      final reply = await TranslationService.to.translateText(
        protected.text,
        into: 'zh',
      );
      final restored = reply == null ? null : protected.restore(reply);
      results.add({
        'source': content.message,
        'sent': protected.text,
        'reply': reply,
        'restored': restored,
        'marksKept': restored != null,
        'ms': clock.elapsedMilliseconds - started,
      });
    }
    final kept = results.where((r) => r['marksKept'] == true).length;
    return {
      'pass': kept == results.length,
      'kept': '$kept/${results.length}',
      'results': results,
    };
  }

  /// `--comment-bilingual`: a bilibili video's comments with the list's
  /// switch on (bilingual), one comment turned back to its original by its
  /// own button, then the switch off and that comment turned on alone.
  static Future<Map<String, dynamic>> _commentBilingualBili(String url) async {
    await PiliScheme.routePushFromUrl(url);
    await Future.delayed(const Duration(seconds: 5));
    final VideoDetailController controller;
    try {
      controller = Get.find<VideoDetailController>(
        tag: Get.parameters['heroTag'] ?? Get.arguments?['heroTag'],
      );
    } catch (e) {
      return {'pass': false, 'reason': 'the page never opened: $e'};
    }
    controller.tabCtr.animateTo(1);
    final reply = Get.find<VideoReplyController>(tag: controller.heroTag);
    if (reply.loadingState.value is Loading) unawaited(reply.queryData());
    for (var i = 0; i < 80 && reply.loadingState.value is! Success; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    final state = reply.loadingState.value;
    if (state is! Success<List<ReplyInfo>?>) {
      return {'pass': false, 'reason': '$state'};
    }
    final list = state.response ?? const [];
    final result = await _commentBilingual(
      prefix: 'bili',
      translator: reply.translator,
      master: () => reply.translator.toggle(list),
      ids: [for (final r in list) CommentTranslator.idOf(r)],
    );
    Get.back();
    await Future.delayed(const Duration(seconds: 1));
    return result;
  }

  /// [_commentBilingualBili] for a YouTube video.
  static Future<Map<String, dynamic>> _commentBilingualYt(String input) async {
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    unawaited(Get.toNamed('/ytVideo', parameters: {'id': videoId}));
    await Future.delayed(const Duration(seconds: 4));
    final controller = Get.find<YtVideoController>(tag: videoId);
    for (var i = 0; i < 20 && controller.stage.value != .ready; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    await _tapText('评论');
    controller.ensureCommentsStarted();
    for (var i = 0; i < 80 && controller.comments.isEmpty; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    final translator = controller.commentTranslator;
    final result = await _commentBilingual(
      prefix: 'yt',
      translator: translator,
      master: () => translator.toggleTexts(controller.loadedCommentTexts),
      ids: [for (final c in controller.comments) c.commentId],
    );
    Get.back();
    await Future.delayed(const Duration(seconds: 1));
    return result;
  }

  /// The three screens, the same way on both platforms: [master] is what
  /// the list's 翻译 button does; each comment's own button is tapped.
  static Future<Map<String, dynamic>> _commentBilingual({
    required String prefix,
    required CommentTranslator translator,
    required VoidCallback master,
    required List<String> ids,
  }) async {
    CommentTranslator.debugDisplay = CommentTranslationDisplay.bilingual;
    try {
      bool button(Element e, String id) => switch (e.widget) {
        CommentTranslateButton(id: final i) => i == id,
        _ => false,
      };
      String? target;
      // the comment's button low in the view, so its text above it shows
      Future<void> reveal() async {
        final id = target;
        final element = id == null ? null : _findElement((e) => button(e, id));
        if (element != null) {
          await Scrollable.ensureVisible(element, alignment: 0.75);
        }
        await Future.delayed(const Duration(milliseconds: 600));
      }

      master();
      final clock = Stopwatch()..start();
      while (translator.busy && clock.elapsed < const Duration(minutes: 4)) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      final translated = ids.where(translator.showsTranslation).toList();
      // the first translated comment that is built
      for (final id in translated) {
        final element = _findElement((e) => button(e, id));
        if (element == null) continue;
        await Scrollable.ensureVisible(element, alignment: 0.75);
        target = id;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 800));
      await reveal();
      final masterOn = await _shot(
        '${prefix}_1_master_on_bilingual',
        whole: true,
      );
      final first = {
        'master': translator.enabled.value,
        'translated': translated.length,
        'loaded': ids.length,
        'ms': clock.elapsedMilliseconds,
      };
      if (target == null) {
        return {
          'pass': false,
          'reason': 'no translated comment with a button on screen',
          'masterOn': first,
          'shots': [masterOn],
        };
      }
      final id = target;
      // one comment back to its original, by its own button
      final tappedOff = await _tap((e) => button(e, id));
      await Future.delayed(const Duration(milliseconds: 500));
      await reveal();
      final oneOff = await _shot('${prefix}_2_one_item_off', whole: true);
      final second = {
        'master': translator.enabled.value,
        'shows': translator.shows(id),
        'overrides': translator.overrides,
      };
      // the switch off, then that comment on alone
      master();
      await Future.delayed(const Duration(milliseconds: 800));
      final tappedOn = await _tap((e) => button(e, id));
      for (var i = 0; i < 120 && translator.pending(id); i++) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      await Future.delayed(const Duration(milliseconds: 500));
      await reveal();
      final oneOn = await _shot('${prefix}_3_master_off_one_on', whole: true);
      final third = {
        'master': translator.enabled.value,
        'shows': translator.shows(id),
        'showsTranslation': translator.showsTranslation(id),
        'othersShown': translated
            .where((e) => e != id && translator.shows(e))
            .length,
        'overrides': translator.overrides,
      };
      return {
        'pass':
            tappedOff &&
            tappedOn &&
            first['master'] == true &&
            second['master'] == true &&
            second['shows'] == false &&
            third['master'] == false &&
            third['showsTranslation'] == true &&
            third['othersShown'] == 0,
        'comment': id,
        'masterOn': first,
        'oneOff': second,
        'masterOffOneOn': third,
        'shots': [masterOn, oneOff, oneOn],
      };
    } finally {
      CommentTranslator.debugDisplay = null;
    }
  }

  /// `--focus-probe`: see [_focusProbe]; also presses keys (see
  /// [_keyProbe]).
  static bool debugFocusProbe = false;

  /// `--comments-probe`: see [_commentsProbe].
  static bool debugCommentsProbe = false;

  /// `--comments-first`: see [_translatePageBili].
  static bool debugCommentsFirst = false;

  /// The page's comments, translated as the 翻译 button does it
  /// (research/comment-translation-design-2026-09-25.md, E3): how many were
  /// to be translated, how many were, a few of them side by side, and how
  /// long it took. The comments tab is shown, so they are rendered.
  static Future<Map<String, Object?>> _commentsProbe(
    VideoDetailController controller,
  ) async {
    controller.tabCtr.animateTo(1);
    final reply = Get.find<VideoReplyController>(tag: controller.heroTag);
    if (reply.loadingState.value is Loading) unawaited(reply.queryData());
    for (var i = 0; i < 80 && reply.loadingState.value is! Success; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    final state = reply.loadingState.value;
    if (state is! Success<List<ReplyInfo>?>) return {'error': '$state'};
    final list = state.response ?? const [];
    final translator = reply.translator;
    final clock = Stopwatch()..start();
    translator.toggle(list);
    final total = translator.total.value;
    while (translator.done.value < translator.total.value &&
        clock.elapsed < const Duration(minutes: 3)) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    final pairs = [
      for (final r in list)
        if (translator.contentFor(r) case final t?)
          {'from': r.content.message, 'to': t.message},
    ];
    final failedList = [
      for (final r in list)
        if (translator.failedFor(r)) r,
      for (final r in list)
        for (final c in r.replies)
          if (translator.failedFor(c)) c,
    ];
    final failed = failedList.length;
    // what failed, and what the model makes of it now, to see why
    final failedDetail = <Map<String, Object?>>[];
    for (final r in failedList.take(5)) {
      final protected = CommentTranslator.protect(r.content);
      final reply = await TranslationService.to.translateText(
        protected.text,
        into: TextLanguage.native.first,
      );
      failedDetail.add({
        'source': r.content.message,
        'sent': protected.text,
        'reply': reply,
        'restored': reply == null ? null : protected.restore(reply),
      });
    }
    // leave it off, as a viewer would find it
    translator.toggle(const []);
    return {
      'native': TextLanguage.native,
      'loaded': list.length,
      'toTranslate': total,
      'translated': pairs.length,
      'failed': failed,
      'failedDetail': failedDetail,
      'ms': clock.elapsedMilliseconds,
      'samples': pairs.take(6).toList(),
    };
  }

  /// [_commentsProbe] for a YouTube page: what language the comments are
  /// in, by [TextLanguage], and how they translate.
  static Future<Map<String, Object?>> _ytCommentsProbe(
    YtVideoController controller,
  ) async {
    controller.ensureCommentsStarted();
    for (var i = 0; i < 80 && controller.comments.isEmpty; i++) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    final items = controller.comments.toList();
    final languages = <String, int>{};
    for (final c in items) {
      final lang =
          TextLanguage.detect(
            CommentTranslator.protectPlain(c.content).plain,
          ) ??
          'none';
      languages[lang] = (languages[lang] ?? 0) + 1;
    }
    final translator = controller.commentTranslator;
    final clock = Stopwatch()..start();
    translator.toggleTexts(controller.loadedCommentTexts);
    final total = translator.total.value;
    while (translator.done.value < translator.total.value &&
        clock.elapsed < const Duration(minutes: 3)) {
      await Future.delayed(const Duration(milliseconds: 250));
    }
    final pairs = [
      for (final c in items)
        if (translator.textFor(c.commentId) case final t?)
          {'from': c.content, 'to': t},
    ];
    final failed = items
        .where((c) => translator.textFailed(c.commentId))
        .length;
    translator.toggleTexts(const []);
    return {
      'native': TextLanguage.native,
      'loaded': items.length,
      'languages': languages,
      'toTranslate': total,
      'translated': pairs.length,
      'failed': failed,
      'ms': clock.elapsedMilliseconds,
      'samples': pairs.take(6).toList(),
    };
  }

  /// `--dump-urls`: pages report the stream URLs they played.
  static bool debugDumpUrls = false;

  /// Presses [logical] the way a keyboard does: the key message goes to the
  /// focus system (the handler the engine calls), from the focused node up.
  /// A key pressed for [hold] (a tap by default). Held, it repeats as a
  /// keyboard does: after 500 ms, every 33 ms.
  static Future<void> _press(
    LogicalKeyboardKey logical,
    PhysicalKeyboardKey physical, {
    Duration hold = const Duration(milliseconds: 80),
  }) async {
    final handler = ServicesBinding.instance.keyEventManager.keyMessageHandler;
    if (handler == null) return;
    Duration now() =>
        Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);
    final down = DateTime.now();
    handler(
      KeyMessage([
        KeyDownEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: now(),
        ),
      ], null),
    );
    const repeatAfter = Duration(milliseconds: 500);
    if (hold <= repeatAfter) {
      await Future.delayed(hold);
    } else {
      await Future.delayed(repeatAfter);
      while (DateTime.now().difference(down) < hold) {
        handler(
          KeyMessage([
            KeyRepeatEvent(
              physicalKey: physical,
              logicalKey: logical,
              timeStamp: now(),
            ),
          ], null),
        );
        await Future.delayed(const Duration(milliseconds: 33));
      }
    }
    handler(
      KeyMessage([
        KeyUpEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: now(),
        ),
      ], null),
    );
  }

  /// Whether the keyboard controls [player]: -> moves playback on, space
  /// pauses it.
  static Future<Map<String, Object?>> _keyProbe(
    PlPlayerController player,
  ) async {
    int? pos() => player.videoPlayerController?.state.position.inMilliseconds;
    final before = pos();
    await _press(LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
    await Future.delayed(const Duration(milliseconds: 1500));
    final after = pos();
    final playingBefore = player.videoPlayerController?.state.playing;
    await _press(LogicalKeyboardKey.space, PhysicalKeyboardKey.space);
    await Future.delayed(const Duration(milliseconds: 800));
    final playingAfter = player.videoPlayerController?.state.playing;
    // as it was
    if (playingBefore == true && playingAfter == false) {
      await player.play();
    }
    // -> held while playing: faster while held, the speed back on release,
    // and no seek step on top (user 2026-09-29: does letting go jump?)
    await Future.delayed(const Duration(milliseconds: 800));
    final rateBefore = player.videoPlayerController?.state.rate;
    final holdStart = pos();
    double? rateHeld;
    // what mpv says of the picture meanwhile: a picture that falls behind
    // at the fast speed catches up on release, and looks like a jump
    final native = player.videoPlayerController;
    final samples = <Map<String, Object?>>[];
    final clock = Stopwatch()..start();
    var phase = 'held';
    // every 20 ms by default: a stall on release shorter than a quarter
    // second would not show at a coarser step. `--probe-sample-ms` coarser
    // where reading mpv's properties this often slows playback itself (a
    // Pixel 6 Pro kept up with only 40-94 % of the samples)
    final sampler = Timer.periodic(Duration(milliseconds: probeSampleMs), (_) {
      String? prop(String name) {
        try {
          return native?.getProperty(name);
        } catch (_) {
          return null;
        }
      }

      samples.add({
        'ms': clock.elapsedMilliseconds,
        'phase': phase,
        'pos': pos(),
        'rate': player.videoPlayerController?.state.rate,
        'timePos': prop('time-pos'),
        'framedrop': prop('framedrop'),
        'avsync': prop('avsync'),
        'frameDrops': prop('frame-drop-count'),
        'decoderDrops': prop('decoder-frame-drop-count'),
        'delayedFrames': prop('vo-delayed-frame-count'),
      });
    });
    // the release as the player sees it: when, and mpv's position before
    // the speed changes
    Map<String, Object?>? release;
    PlPlayerController.debugOnRelease = (timePos) =>
        release = {'ms': clock.elapsedMilliseconds, 'timePos': timePos};
    final holding = _press(
      LogicalKeyboardKey.arrowRight,
      PhysicalKeyboardKey.arrowRight,
      hold: const Duration(seconds: 2),
    );
    await Future.delayed(const Duration(milliseconds: 1500));
    rateHeld = player.videoPlayerController?.state.rate;
    await holding;
    phase = 'released';
    final released = pos();
    await Future.delayed(const Duration(milliseconds: 4000));
    sampler.cancel();
    PlPlayerController.debugOnRelease = null;
    final afterRelease = pos();
    final rateAfter = player.videoPlayerController?.state.rate;
    final held = holdStart == null || released == null
        ? null
        : released - holdStart;
    final sinceRelease = released == null || afterRelease == null
        ? null
        : afterRelease - released;
    return {
      'longPress': {
        'playing': player.videoPlayerController?.state.playing,
        'rateBefore': rateBefore,
        'rateHeld': rateHeld,
        'rateAfter': rateAfter,
        // 2 s held: about 0.2 s at the old speed and 1.8 s at the fast one
        'movedWhileHeldMs': held,
        // 1 s of playback, and a seek step if letting go jumped
        'movedInSecondAfterReleaseMs': sinceRelease,
        'jumpedOnRelease': sinceRelease != null && sinceRelease > 3000,
        'seekStepMs': player.fastForBackwardDuration.inMilliseconds,
        'release': release,
        'samples': samples,
      },
      'focus': _focusChainNow().take(3).join(' > '),
      'positionBefore': before,
      'positionAfterArrowRight': after,
      // playback alone moves it 1.5 s; the key, by the seek step on top
      'arrowRightSeeked':
          before != null && after != null && after - before > 3000,
      'playingBefore': playingBefore,
      'playingAfterSpace': playingAfter,
      'spacePaused': playingBefore == true && playingAfter == false,
    };
  }

  static List<String> _focusChainNow() => [
    for (
      FocusNode? node = FocusManager.instance.primaryFocus;
      node != null;
      node = node.parent
    )
      node.debugLabel ?? '${node.runtimeType}',
  ];

  /// Where focus is after a SmartDialog and after a route dialog open and
  /// close: whether the player still gets the keys.
  static Future<Map<String, Object>> _focusProbe() async {
    final out = <String, Object>{'before': _focusChainNow()};
    SmartDialog.show(
      tag: 'focus-probe',
      builder: (_) => const AlertDialog(content: Text('probe')),
    );
    await Future.delayed(const Duration(milliseconds: 600));
    out['smartDialogOpen'] = _focusChainNow();
    await SmartDialog.dismiss(tag: 'focus-probe');
    await Future.delayed(const Duration(milliseconds: 600));
    out['afterSmartDialog'] = _focusChainNow();
    final context = Get.context;
    if (context != null && context.mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('probe')),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 600));
      out['routeDialogOpen'] = _focusChainNow();
      Get.back<void>();
      await Future.delayed(const Duration(milliseconds: 600));
      out['afterRouteDialog'] = _focusChainNow();
    }
    return out;
  }

  /// `--danmaku-probe <BV>`: whether a video page's danmaku follow the
  /// picture (research: TODO 「快进/后退后弹幕清空」 and 「弹幕跟随
  /// isBuffering」).
  ///
  /// - After a seek forward and one back, how many danmaku are on screen
  ///   once playback has landed, and how many of them are already part way
  ///   across. The screen used to be emptied by the seek and filled only as
  ///   new ones came: a few at most, all at the right edge.
  /// - All along (sampled every 20 ms from before the page opens), whether
  ///   the danmaku were moving while mpv said "playing" but was buffering —
  ///   the first frame not yet in, or a seek into what was not downloaded.
  ///
  /// `--no-refill` and `--no-buffer-follow` turn each fix off, for the
  /// reverse checks: the matching assertion has to fail.
  static Future<Map<String, dynamic>> _danmakuProbe(
    String bv, {
    required int seekTo,
  }) async {
    PlPlayerController? player;
    // how wide the danmaku's view is: what "on screen" is measured against
    double viewWidth() {
      final screen = _findElement((e) => e.widget is DanmakuScreen)?.widget;
      return screen is DanmakuScreen ? screen.size.width : 0;
    }

    // on screen now: scrolling ones painted and inside the view, static ones
    ({int scroll, int fixed, int partWay}) onScreen() {
      final ctr = player?.danmakuController;
      if (ctr == null) return (scroll: 0, fixed: 0, partWay: 0);
      final width = viewWidth();
      var scroll = 0;
      var partWay = 0;
      for (final track in ctr.scrollDanmaku) {
        for (final item in track) {
          if (item.expired || item.drawTick == null) continue;
          if (item.xPosition + item.width <= 0 || item.xPosition >= width) {
            continue;
          }
          scroll++;
          // left of the middle: on screen for a good while already
          if (item.xPosition < width / 2) partWay++;
        }
      }
      final fixed = ctr.staticDanmaku.nonNulls.length;
      return (scroll: scroll, fixed: fixed, partWay: partWay);
    }

    // the sampler: mpv "playing" but buffering, and the danmaku then
    var samples = 0;
    var playingBuffering = 0;
    var runningWhileBuffering = 0;
    var runningWhilePaused = 0;
    final bufferingLog = <String>[];
    final clock = Stopwatch()..start();
    final sampler = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final p = player;
      final ctr = p?.danmakuController;
      if (p == null || ctr == null) return;
      samples++;
      final playing = p.playerStatus.isPlaying;
      final buffering = p.isBuffering.value;
      if (playing && buffering) {
        playingBuffering++;
        if (ctr.running) runningWhileBuffering++;
        if (bufferingLog.length < 40) {
          bufferingLog.add(
            '${clock.elapsedMilliseconds} ms: running=${ctr.running} '
            'pos=${p.videoPlayerController?.state.position.inMilliseconds}',
          );
        }
      }
      if (!playing &&
          ctr.running &&
          !ctr.scrollDanmaku.every((t) => t.isEmpty)) {
        runningWhilePaused++;
      }
    });

    VideoDetailController? controller;
    final seeks = <Map<String, Object?>>[];
    try {
      final routed = await PiliScheme.routePushFromUrl(
        'https://www.bilibili.com/video/$bv',
      );
      for (var i = 0; i < 100 && controller == null; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        try {
          controller = Get.find<VideoDetailController>(
            tag: Get.parameters['heroTag'] ?? Get.arguments?['heroTag'],
          );
        } catch (_) {}
      }
      if (controller == null) {
        return {'pass': false, 'routed': routed, 'reason': 'no page'};
      }
      for (var i = 0; i < 30 && !controller.videoState.value; i++) {
        await Future.delayed(const Duration(seconds: 1));
      }
      final p = player = controller.plPlayerController;
      await p.play();

      int position() =>
          p.videoPlayerController?.state.position.inMilliseconds ?? -1;
      // playing, and some danmaku shown
      for (var i = 0; i < 300; i++) {
        final now = onScreen();
        if (position() > 5000 && now.scroll + now.fixed > 0) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      final before = onScreen();

      Future<Map<String, Object?>> seekAndCount(int seconds) async {
        final target = seconds * 1000;
        final from = position();
        final sw = Stopwatch()..start();
        await p.seekTo(Duration(seconds: seconds));
        // landed: playing from there (mpv reports the target at once, before
        // it has anything to show), not buffering
        var landedMs = -1;
        while (sw.elapsed < const Duration(seconds: 30)) {
          final at = position();
          if (at >= target + 300 &&
              at <= target + 4000 &&
              p.playerStatus.isPlaying &&
              !p.isBuffering.value) {
            landedMs = sw.elapsedMilliseconds;
            break;
          }
          await Future.delayed(const Duration(milliseconds: 10));
        }
        // a few frames: the refilled ones are placed after their first
        await Future.delayed(const Duration(milliseconds: 250));
        final after = onScreen();
        final record = {
          'from': from,
          'to': target,
          'landedAfterMs': landedMs,
          'positionAtCount': position(),
          'onScreenScroll': after.scroll,
          'onScreenFixed': after.fixed,
          'partWay': after.partWay,
          'refill': PlDanmaku.debugLastRefill == null
              ? null
              : {
                  'alive': PlDanmaku.debugLastRefill!.alive,
                  'placed': PlDanmaku.debugLastRefill!.placed,
                  'ms': PlDanmaku.debugLastRefill!.micros / 1000,
                },
        };
        PlDanmaku.debugLastRefill = null;
        // settle before the next one: danmaku seen again
        await Future.delayed(const Duration(seconds: 3));
        record['onScreenAfter3s'] = onScreen().scroll + onScreen().fixed;
        return record;
      }

      seeks
        ..add(await seekAndCount(seekTo))
        ..add(await seekAndCount(seekTo - 60))
        // far ahead: nothing of it downloaded, so mpv buffers there
        ..add(
          await seekAndCount(
            math.max(seekTo + 60, p.duration.value * 3 ~/ 4),
          ),
        );
      // what plain playback keeps on screen, for comparison: longer than a
      // danmaku lives, so nothing refilled is left
      await Future.delayed(
        Duration(
          milliseconds:
              (p.danmakuController?.option.durationInMilliseconds ?? 10000)
                  .round() +
              1000,
        ),
      );
      final steady = onScreen();

      final landedAll = seeks.every((s) => (s['landedAfterMs'] as int) >= 0);
      final minOnScreen = seeks
          .map(
            (s) => (s['onScreenScroll'] as int) + (s['onScreenFixed'] as int),
          )
          .reduce(math.min);
      final minPartWay = seeks.map((s) => s['partWay'] as int).reduce(math.min);
      final refilled = minOnScreen >= 8 && minPartWay >= 3;
      final followed = playingBuffering > 0 && runningWhileBuffering == 0;
      return {
        'pass': landedAll && refilled && followed,
        'refill': PlDanmaku.debugRefill,
        'followBuffering': PlDanmaku.debugFollowBuffering,
        'routed': routed,
        'duration': p.duration.value,
        'danmakuLoaded': PlDanmakuController.lastLoadedCount,
        // the first segment asked for directly: whether danmaku come at all
        'segment1': switch (await DmGrpc.dmSegMobile(
          cid: controller.cid.value,
          segmentIndex: 1,
        )) {
          Success(:final response) => '${response.elems.length} danmaku',
          final other => '$other',
        },
        'trackCount': p.danmakuController?.trackCount,
        'viewWidth': viewWidth(),
        'option': {
          'duration': p.danmakuController?.option.duration,
          'staticDuration': p.danmakuController?.option.staticDuration,
          'fixedVelocity': p.danmakuController?.option.scrollFixedVelocity,
          'massive': p.danmakuController?.option.massiveMode,
        },
        'beforeSeek': {
          'scroll': before.scroll,
          'fixed': before.fixed,
          'partWay': before.partWay,
        },
        'seeks': seeks,
        'steadyOnScreen': steady.scroll + steady.fixed,
        'landedAll': landedAll,
        'minOnScreenAfterSeek': minOnScreen,
        'minPartWayAfterSeek': minPartWay,
        'refilled': refilled,
        'samples': samples,
        'playingBufferingSamples': playingBuffering,
        'runningWhileBuffering': runningWhileBuffering,
        'runningWhilePaused': runningWhilePaused,
        'followedBuffering': followed,
        'bufferingLog': bufferingLog,
      };
    } finally {
      sampler.cancel();
      if (controller != null) {
        Get.back<void>();
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  static Future<Map<String, dynamic>> _openBili(
    String url,
    int holdSeconds, {
    bool autoplay = false,
    bool recovery = true,
    int sampleMs = 2000,
    int sampleSeconds = 50,
    int? seekTo,
    int seekAfterMs = 0,
    bool dumpUrls = false,
    bool noHostSwitch = false,
  }) async {
    // the control for a recovery: what the viewer got before it existed.
    // Set before the page opens: the cut shows within its first seconds
    PlPlayerController.debugDisableRecovery = !recovery;
    VideoDetailController.debugNoHostSwitch = noHostSwitch;
    // a seek made the way the progress bar makes it, [seekAfterMs] after
    // the link is opened: early enough and it lands while the page is
    // still loading its source
    final seekLog = <String>[];
    if (seekTo != null) {
      final opened = DateTime.now();
      unawaited(() async {
        await Future.delayed(Duration(milliseconds: seekAfterMs));
        VideoDetailController? page;
        while (page == null &&
            DateTime.now().difference(opened).inSeconds < 20) {
          try {
            page = Get.find<VideoDetailController>(
              tag: Get.parameters['heroTag'] ?? Get.arguments?['heroTag'],
            );
          } catch (_) {
            await Future.delayed(const Duration(milliseconds: 20));
          }
        }
        final player = page?.plPlayerController;
        seekLog.add(
          'at ${DateTime.now().difference(opened).inMilliseconds} ms: '
          'status=${player?.dataStatus.value.name} '
          'processing=${player?.processing} '
          'position=${player?.videoPlayerController?.state.position}',
        );
        await player?.seekTo(Duration(seconds: seekTo), isSeek: false);
      }());
    }
    final routed = await PiliScheme.routePushFromUrl(url);
    await Future.delayed(const Duration(seconds: 5));

    VideoDetailController? controller;
    try {
      controller = Get.find<VideoDetailController>(
        tag: Get.parameters['heroTag'] ?? Get.arguments?['heroTag'],
      );
    } catch (_) {
      // fall back to whatever instance is registered
      try {
        controller = Get.find<VideoDetailController>();
      } catch (_) {}
    }
    if (controller == null) {
      return {
        'pass': false,
        'routed': routed,
        'reason': 'no VideoDetailController — the page never opened',
        'route': Get.currentRoute,
      };
    }

    // wait for the play URL to resolve
    for (var i = 0; i < holdSeconds && !controller.videoState.value; i++) {
      await Future.delayed(const Duration(seconds: 1));
    }

    final urlData = controller.data;
    final player = controller.plPlayerController;
    // mpv's own account of what it is doing. Everything measured so far says
    // the stream is complete and decodable, so the reason it stops has to be
    // asked of the thing that stops.
    final log = <String>[];
    final logSub = player.videoPlayerController?.stream.log.listen((e) {
      if (log.length < 60) log.add('${e.level}/${e.prefix}: ${e.text}');
    });
    final completedSub = player.videoPlayerController?.stream.completed.listen(
      (done) => log.add('== completed=$done'),
    );
    if (!autoplay) await player.play();
    // Watched for a fixed stretch and sampled, rather than stopped at the
    // first sign of movement. The reported symptom is a stall a few seconds
    // in, and 1.5s of progress is indistinguishable from that — the earlier
    // version of this loop returned exactly when the fault was starting.
    final timeline = <int>[];
    final hosts = <String>[];
    // the end of what arrived: a track cut off leaves the playhead running
    // past it (see PlPlayerController._watchForDryTrack)
    final cacheEnds = <String>[];
    final states = <String>[];
    // 50 s whatever the interval: a finer one shows how the playhead moves
    // in the first seconds (a jump back to the start before a resume)
    // when each sample was really taken: the interval asked for is not what
    // passes between two samples, and a playhead compared against it showed
    // a jump that was only a late sample
    final sampledAt = <int>[];
    final clock = Stopwatch()..start();
    for (var i = 0; i < sampleSeconds * 1000 ~/ sampleMs; i++) {
      await Future.delayed(Duration(milliseconds: sampleMs));
      sampledAt.add(clock.elapsedMilliseconds);
      timeline.add(
        player.videoPlayerController?.state.position.inMilliseconds ?? -1,
      );
      if (player.videoPlayerController case final NativePlayer mpv) {
        cacheEnds.add(mpv.getProperty('demuxer-cache-time'));
        states.add(
          'pause=${mpv.getProperty('pause')} '
          'cache=${mpv.getProperty('paused-for-cache')} '
          'status=${player.playerStatus.value.name} '
          // what the viewer sees, not what mpv reads while a source opens
          'shown=${player.position.value} '
          'buffering=${player.isBuffering.value} vid=${mpv.getProperty('vid')} '
          'apts=${mpv.getProperty('audio-pts')} tpos=${mpv.getProperty('time-pos')} '
          'drops=${mpv.getProperty('frame-drop-count')} '
          'epoch=${player.videoControllerEpoch.value} '
          'gate=${controller.asrPending.value} '
          // a second player during a handover: what it costs
          'rss=${ProcessInfo.currentRss >> 20} '
          'speed=${mpv.getProperty('cache-speed')} '
          'ahead=${mpv.getProperty('demuxer-cache-duration')} '
          'qa=${controller.currentVideoQa.value?.code}',
        );
      }
      final host = Uri.tryParse(controller.videoUrl ?? '')?.host;
      if (host != null && (hosts.isEmpty || hosts.last != host)) {
        hosts.add(host);
      }
    }
    final buffer = player.videoPlayerController?.state.buffer.inMilliseconds;
    final last = player.videoPlayerController?.state.position;
    // real playback moves roughly with the clock; a stall does not
    final played = timeline.length >= 2 && timeline.last >= 15000;

    // what mpv is actually doing with it: a stream that "plays" while
    // software-decoding AV1 with no cache is a stream that stutters, and
    // position alone cannot tell that apart from healthy playback
    Map<String, Object?> health = const {};
    if (player.videoPlayerController case final NativePlayer mpv) {
      health = {
        for (final name in const [
          'hwdec-current',
          'video-codec',
          'video-format',
          'demuxer-cache-duration',
          'cache-speed',
          'paused-for-cache',
          'frame-drop-count',
          'decoder-frame-drop-count',
          'estimated-vf-fps',
          'container-fps',
          'video-bitrate',
        ])
          name: mpv.getProperty(name),
      };
    }

    // Which host is being read from, and how the alternatives compare.
    // A stream that arrives at 2 KB/s is not a decode problem and not a
    // quality problem; it is a route problem, and the app has other routes.
    final videoItem = controller.firstVideo;
    final urls = <String>[
      ?videoItem.baseUrl,
      ...?videoItem.backupUrl,
    ];
    final cdnSpeeds = <Map<String, Object?>>[];
    for (final candidate in VideoUtils.cdnCandidates(urls).take(4)) {
      cdnSpeeds.add(await _timeRange(candidate));
    }
    // The audio stream is the one mpv says dies at 11668 bytes. Fetched here
    // with a Referer and again without one, because a CDN that cuts a
    // connection short is usually answering the headers, not the bytes.
    // Every audio stream on offer, and every CDN host each one has: the
    // question is no longer whether one is broken but whether another works,
    // because that decides whether the fix is picking a different quality or
    // a different route.
    final audioMatrix = <Map<String, Object?>>[];
    for (final item in controller.data.dash?.audio ?? const []) {
      final hosts = VideoUtils.cdnCandidates([
        ?item.baseUrl,
        ...?item.backupUrl,
      ]);
      for (final host in hosts.take(3)) {
        final probe = await _timeRange(host, wanted: 256 << 10);
        audioMatrix.add({'id': item.id, 'codecs': item.codecs, ...probe});
      }
    }

    final audioProbe = <String, Object?>{
      'withReferer': await _timeRange(controller.audioUrl ?? '', referer: true),
      'withoutReferer': await _timeRange(
        controller.audioUrl ?? '',
        referer: false,
      ),
      'fullGetNoRange': await _timeRange(
        controller.audioUrl ?? '',
        referer: true,
        useRange: false,
      ),
    };

    // Reported: plays to ~5s, pauses, and resuming starts from the
    // beginning — which is what mpv does at end of file. So the question is
    // how long each track actually is, measured by opening each one on its
    // own rather than trusting the API's timeLength.
    final trackDurations = <String, Object?>{
      'apiTimeLengthMs': controller.data.timeLength,
      'video': await _urlDuration(controller.videoUrl),
      'audio': await _urlDuration(controller.audioUrl),
    };
    // and the same quality in every codec it is offered in, because a
    // duration mpv cannot read may be a property of one encode rather than
    // of the video
    final byCodec = <Map<String, Object?>>[];
    final currentId = controller.currentVideoQa.value?.code;
    for (final item in controller.data.dash?.video ?? const []) {
      if (item.id != currentId) continue;
      final measured = await _urlDuration(item.baseUrl);
      byCodec.add({
        'codecs': item.codecs,
        'id': item.id,
        ...measured,
      });
    }
    trackDurations['byCodec'] = byCodec;
    // How many bytes the CDN will actually serve, against how many a full
    // 20 minutes at this bitrate would need. A short file is a preview, not
    // a decoding problem — and a preview is what an account-less request
    // gets for some videos.
    final chosen = controller.firstVideo;
    trackDurations['videoBytes'] = await _totalBytes(controller.videoUrl);
    trackDurations['audioBytes'] = await _totalBytes(controller.audioUrl);
    trackDurations['videoBandwidth'] = chosen.bandWidth;
    if (chosen.bandWidth case final bw? when bw > 0) {
      trackDurations['expectedBytesForFullLength'] =
          (bw / 8 * (controller.data.timeLength ?? 0) / 1000).round();
    }

    final qa = controller.currentVideoQa.value;
    final dash = controller.data.dash;
    final result = {
      'pass': played,
      'routed': routed,
      'route': Get.currentRoute,
      'bvid': controller.bvid,
      'cid': controller.cid.value,
      // did the API answer at all, and with what
      'urlDash': urlData.dash != null,
      'videoState': controller.videoState.value,
      'isUgc': controller.isUgc,
      'currentQa': qa?.desc,
      'currentQaCode': qa?.code,
      'decodeFormat': controller.currentDecodeFormats.description,
      'availableQa': dash?.video
          ?.map((e) => '${e.id} ${e.codecs ?? ''}')
          .toList(),
      'videoStreams': dash?.video?.length ?? 0,
      'audioStreams': dash?.audio?.length ?? 0,
      'hasDurl': controller.data.durl?.isNotEmpty == true,
      'videoUrlSet': controller.videoUrl?.isNotEmpty == true,
      'audioUrlSet': controller.audioUrl?.isNotEmpty == true,
      // and what the player made of it
      'played': played,
      'positionTimeline': timeline,
      'hostTimeline': hosts,
      // where focus is left after a dialog of each kind opens and closes
      if (debugFocusProbe) 'focusAfterDialogs': await _focusProbe(),
      if (debugFocusProbe) 'keys': await _keyProbe(player),
      if (debugCommentsProbe) 'comments': await _commentsProbe(controller),
      // where the keyboard goes: a key the player is to act on has to reach
      // PlayerFocus, from the focused node up
      'focusChain': [
        for (
          FocusNode? node = FocusManager.instance.primaryFocus;
          node != null;
          node = node.parent
        )
          '${node.debugLabel ?? node.runtimeType}'
              '${node.context?.widget.runtimeType == null ? '' : ' <${node.context!.widget.runtimeType}>'}',
      ],
      'cacheEndTimeline': cacheEnds,
      'sampledAtMs': sampledAt,
      // the URLs themselves, for probing the same streams outside the app
      // (they carry a signature, and expire)
      if (dumpUrls) ...{
        'videoUrlFull': controller.videoUrl,
        'audioUrlFull': controller.audioUrl,
      },
      'seekLog': seekLog,
      'stateTimeline': states,
      'videoFile': Uri.tryParse(controller.videoUrl ?? '')?.pathSegments.last,
      'buffer': buffer,
      'position': last?.inMilliseconds,
      'playerDuration':
          player.videoPlayerController?.state.duration.inMilliseconds,
      'playerLog': player.videoPlayerController?.state.buffering,
      'timeLength': controller.data.timeLength,
      'health': health,
      'playingHost': Uri.tryParse(controller.videoUrl ?? '')?.host,
      'cdnSpeeds': cdnSpeeds,
      'audioProbe': audioProbe,
      'audioMatrix': audioMatrix,
      'trackDurations': trackDurations,
      'playRepeat': player.playRepeat.toString(),
    };
    await logSub?.cancel();
    await completedSub?.cancel();
    result['mpvLog'] = log;
    Get.back();
    await Future.delayed(const Duration(seconds: 1));
    return result;
  }

  /// The size the CDN reports for [url], read from a one-byte ranged GET.
  static Future<Object?> _totalBytes(String? url) async {
    if (url == null || url.isEmpty) return null;
    final client = HttpClient()..idleTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(url))
        ..headers.set(HttpHeaders.rangeHeader, 'bytes=0-0')
        ..headers.set(HttpHeaders.refererHeader, 'https://www.bilibili.com')
        ..headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      await response.drain<void>();
      // 'bytes 0-0/12345678'
      final total = range?.split('/').lastOrNull;
      return int.tryParse(total ?? '') ??
          range ??
          'HTTP ${response.statusCode}';
    } catch (e) {
      return '$e';
    } finally {
      client.close(force: true);
    }
  }

  /// Opens one URL on its own and reports the duration it claims.
  ///
  /// The player is fed two tracks; if either is shorter than the video,
  /// playback ends there. That is invisible while they are combined.
  static Future<Map<String, Object?>> _urlDuration(String? url) async {
    if (url == null || url.isEmpty) return {'url': null};
    final player = await Player.create();
    try {
      await player.open(Media(url), play: false);
      for (var i = 0; i < 24; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (player.state.duration > Duration.zero) break;
      }
      return {
        'host': Uri.tryParse(url)?.host,
        'durationMs': player.state.duration.inMilliseconds,
        'videoTracks': player.state.tracks.video.length,
        'audioTracks': player.state.tracks.audio.length,
      };
    } catch (e) {
      return {'host': Uri.tryParse(url)?.host, 'error': '$e'};
    } finally {
      await player.dispose();
    }
  }

  /// Fetches the first 2 MB of [url] and reports how fast it came.
  ///
  /// The same shape mpv uses — a ranged GET — so the number is comparable
  /// to what playback gets, and no bilibili cookies are attached: the CDN
  /// URLs are signed and need none.
  static Future<Map<String, Object?>> _timeRange(
    String url, {
    bool referer = true,
    bool useRange = true,
    int wanted = 2 << 20,
  }) async {
    if (url.isEmpty) return {'error': 'no url'};
    final uri = Uri.parse(url);
    final client = HttpClient()..idleTimeout = const Duration(seconds: 10);
    final started = DateTime.now();
    var received = 0;
    String? error;
    try {
      final request = await client.getUrl(uri);
      if (useRange) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${wanted - 1}');
      }
      if (referer) {
        request.headers
          ..set(HttpHeaders.refererHeader, 'https://www.bilibili.com')
          ..set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode >= 400) {
        error = 'HTTP ${response.statusCode}';
        await response.drain<void>();
      } else {
        await for (final chunk in response.timeout(
          const Duration(seconds: 10),
        )) {
          received += chunk.length;
          if (received >= wanted) break;
        }
      }
    } catch (e) {
      error = '$e';
    } finally {
      client.close(force: true);
    }
    final ms = DateTime.now().difference(started).inMilliseconds;
    return {
      'host': uri.host,
      'bytes': received,
      'ms': ms,
      'kbPerSec': ms == 0 ? null : (received / 1024 / (ms / 1000)).round(),
      'error': error,
    };
  }

  /// The writing systems a set of cues is made of, as fractions.
  ///
  /// Hangul says Korean, kana says Japanese, Han alone says Chinese. A
  /// recogniser that picked the wrong language still writes fluently — in
  /// the wrong script — so this is what tells the two apart.
  static Map<String, String> _scriptMix(List<AsrCue> cues) {
    var hangul = 0;
    var kana = 0;
    var han = 0;
    var latin = 0;
    var total = 0;
    for (final cue in cues) {
      for (final rune in cue.content.runes) {
        if (rune <= 0x20) continue;
        total++;
        if (rune >= 0xAC00 && rune <= 0xD7A3) {
          hangul++;
        } else if ((rune >= 0x3040 && rune <= 0x309F) ||
            (rune >= 0x30A0 && rune <= 0x30FF)) {
          kana++;
        } else if (rune >= 0x4E00 && rune <= 0x9FFF) {
          han++;
        } else if ((rune >= 0x41 && rune <= 0x5A) ||
            (rune >= 0x61 && rune <= 0x7A)) {
          latin++;
        }
      }
    }
    String pct(int n) => total == 0 ? '0' : (n / total).toStringAsFixed(3);
    return {
      'hangul': pct(hangul),
      'kana': pct(kana),
      'han': pct(han),
      'latin': pct(latin),
      'chars': '$total',
    };
  }

  /// Splits the audio that carries no subtitle into "the VAD heard nothing
  /// there" and "the VAD heard speech and it produced no cue".
  ///
  /// Coverage alone cannot separate those, and they need opposite fixes: the
  /// first is a video with pauses in it, the second is speech being lost.
  static Map<String, Object?> _coverageVsVad(
    List<AsrCue> cues,
    List<({double start, double duration})> segments,
    double audioSeconds,
  ) {
    if (audioSeconds <= 0) return const {};
    // millisecond buckets are precise enough and make the overlap trivial
    const step = 0.1;
    final slots = (audioSeconds / step).ceil();
    final speech = List<bool>.filled(slots, false);
    final covered = List<bool>.filled(slots, false);
    void mark(List<bool> into, double from, double to) {
      final a = (from / step).floor().clamp(0, slots - 1);
      final b = (to / step).ceil().clamp(0, slots);
      for (var i = a; i < b; i++) {
        into[i] = true;
      }
    }

    for (final segment in segments) {
      mark(speech, segment.start, segment.start + segment.duration);
    }
    for (final cue in cues) {
      mark(covered, cue.from, cue.to);
    }

    var speechSlots = 0;
    var uncovered = 0;
    var uncoveredSpeech = 0;
    final lost = <String>[];
    var runStart = -1;
    for (var i = 0; i < slots; i++) {
      if (speech[i]) speechSlots++;
      if (!covered[i]) {
        uncovered++;
        if (speech[i]) {
          uncoveredSpeech++;
          if (runStart < 0) runStart = i;
          continue;
        }
      }
      if (runStart >= 0) {
        final length = (i - runStart) * step;
        if (length >= 1.0) {
          lost.add(
            '${(runStart * step).toStringAsFixed(0)}s '
            '+${length.toStringAsFixed(1)}s',
          );
        }
        runStart = -1;
      }
    }
    lost.sort((a, b) => b.split('+').last.compareTo(a.split('+').last));
    return {
      'segments': segments.length,
      'vadSpeechSeconds': (speechSlots * step).toStringAsFixed(1),
      'uncoveredSeconds': (uncovered * step).toStringAsFixed(1),
      // the answer to "how much of the uncovered time is真静音"
      'uncoveredButSilentSeconds': ((uncovered - uncoveredSpeech) * step)
          .toStringAsFixed(1),
      'uncoveredSpeechSeconds': (uncoveredSpeech * step).toStringAsFixed(1),
      'speechLostRuns': lost.take(8).toList(),
    };
  }

  /// How the cues actually land on screen: how long each is up, how long
  /// the screen is empty between them, and how much text each carries.
  ///
  /// Reported as "many subtitles flash and then nothing until the next
  /// sentence, and some run to three lines" — both are distributions, and
  /// neither can be judged from a handful of examples.
  static Map<String, Object?> _cueStats(
    List<AsrCue> cues,
    double audioSeconds,
  ) {
    if (cues.isEmpty) return const {};
    final shown = <double>[];
    final gaps = <double>[];
    final chars = <int>[];
    for (var i = 0; i < cues.length; i++) {
      shown.add(cues[i].to - cues[i].from);
      chars.add(cues[i].content.length);
      if (i + 1 < cues.length) gaps.add(cues[i + 1].from - cues[i].to);
    }
    List<double> sorted(List<double> v) => [...v]..sort();
    double at(List<double> v, double q) =>
        v.isEmpty ? 0 : v[(v.length * q).clamp(0, v.length - 1).floor()];
    final s = sorted(shown);
    final g = sorted(gaps);
    final c = sorted(chars.map((e) => e.toDouble()).toList());
    return {
      'shownP10': at(s, 0.1).toStringAsFixed(2),
      'shownMedian': at(s, 0.5).toStringAsFixed(2),
      'shownP90': at(s, 0.9).toStringAsFixed(2),
      // a cue nobody can read
      'underOneSecond': shown.where((e) => e < 1.0).length,
      'underHalfSecond': shown.where((e) => e < 0.5).length,
      'gapMedian': at(g, 0.5).toStringAsFixed(2),
      'gapP90': at(g, 0.9).toStringAsFixed(2),
      // screen empty for longer than the cue before it was up
      'gapOverTwoSeconds': gaps.where((e) => e > 2).length,
      'charsMedian': at(c, 0.5).round(),
      'charsP90': at(c, 0.9).round(),
      'charsMax': chars.reduce((a, b) => a > b ? a : b),
      // roughly a line at this font size; three lines is the complaint
      'overTwoLines': chars.where((e) => e > 40).length,
      // Against the whole audio, not the span between the first and last
      // cue: "large stretches with no subtitle at all" is a statement about
      // the video, and a fraction measured inside the transcript cannot see
      // a piece of it that produced nothing.
      'coverage': audioSeconds <= 0
          ? null
          : (shown.fold<double>(0, (a, b) => a + b) / audioSeconds)
                .toStringAsFixed(3),
      'beforeFirstCue': cues.first.from.toStringAsFixed(1),
      'afterLastCue': (audioSeconds - cues.last.to).toStringAsFixed(1),
      'biggestGaps': () {
        final holes = <(double, double)>[];
        if (cues.first.from > 0) holes.add((0, cues.first.from));
        for (var i = 0; i + 1 < cues.length; i++) {
          final hole = cues[i + 1].from - cues[i].to;
          if (hole > 0) holes.add((cues[i].to, hole));
        }
        if (audioSeconds > cues.last.to) {
          holes.add((cues.last.to, audioSeconds - cues.last.to));
        }
        holes.sort((a, b) => b.$2.compareTo(a.$2));
        return [
          for (final hole in holes.take(6))
            '${hole.$1.toStringAsFixed(0)}s +${hole.$2.toStringAsFixed(1)}s',
        ];
      }(),
      'gapsOverFiveSeconds': () {
        var n = 0;
        for (var i = 0; i + 1 < cues.length; i++) {
          if (cues[i + 1].from - cues[i].to > 5) n++;
        }
        return n;
      }(),
      'emptyFraction':
          (gaps.fold<double>(0, (a, b) => a + (b > 0 ? b : 0)) /
                  (cues.last.to - cues.first.from))
              .toStringAsFixed(3),
    };
  }

  /// LibrePili: what this build actually renders at.
  ///
  /// Reported as "everything is one size smaller than PiliPlus, and both
  /// say the scale is 1.00". Comparing screenshots cannot answer that; the
  /// numbers the framework is working from can.
  static Future<Map<String, dynamic>> _uiMetrics() async {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final context = Get.context;
    final scaler = context == null ? null : MediaQuery.textScalerOf(context);
    return {
      'pass': true,
      'uiScalePref': Pref.uiScale,
      'devicePixelRatioScaled':
          ScaledWidgetsFlutterBinding.instance.devicePixelRatioScaled,
      // what the OS reports, before anything the app does to it
      'viewDevicePixelRatio': view.devicePixelRatio,
      'physicalWidth': view.physicalSize.width,
      // and what the widget tree is laid out in
      'mediaDevicePixelRatio': context == null
          ? null
          : MediaQuery.devicePixelRatioOf(context),
      'logicalWidth': context == null ? null : MediaQuery.widthOf(context),
      'textScalerOn14': scaler?.scale(14),
      // What Windows itself asks for (Accessibility → Text size). The app
      // overrides MediaQuery's scaler with TextScaler.linear(defaultTextScale)
      // unconditionally, so anything the system asked for is discarded — and
      // the value above was read from Get.context, which may sit ABOVE that
      // override and therefore report the wrong number.
      'platformTextScaleFactor':
          WidgetsBinding.instance.platformDispatcher.textScaleFactor,
      'defaultTextScalePref': Pref.defaultTextScale,
      'fontFamily': FontUtils.fontFamily,
      'appFontWeight': Pref.appFontWeight.value,
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
          youtubeRoute == '/ytSearch' && bilibiliRoute == '/search' && allAsks,
      'youtubeRoute': youtubeRoute,
      'bilibiliRoute': bilibiliRoute,
      'allAsks': allAsks,
    };
  }

  /// LibrePili: can we list a channel's uploads? Subscriptions depend on it,
  /// and stage 1 never parsed a channel page — so this asks before any UI is
  /// built on the assumption.
  /// `--yt-channel ID`: every tab the channel has, each paged to its end
  /// (yt-channel-tabs plan §6). Pass: the tabs come from the response, the
  /// 视频 tab's every item has a date and views, the avatar is not the
  /// banner, every tab ends cleanly (a page with no token, not an error),
  /// and — on Kurzgesagt — 视频 = 251 and Shorts = 140, which with the
  /// uploads playlist's 391 (`--yt-playlist`) is the whole channel.
  static Future<Map<String, dynamic>> _youtubeChannel(String channelId) async {
    final source = YtDirectSource.create();
    final router = YtSourceRouter(source);
    final first = await router.run(
      (s) => (s as YtDirectSource).channelTab(channelId, YtChannelTab.videos),
    );
    if (!first.ok || first.value == null) {
      return {'pass': false, 'verdict': first.verdict.toString()};
    }
    final page = first.value!;
    final info = page.info;
    final tabs = <String, Object?>{};
    var allEnded = true;
    var videosDated = true;
    for (final tab in YtChannelTab.values) {
      if (!page.tabs.containsKey(tab)) continue;
      final pages = <int>[];
      final sample = <String>[];
      var withPublished = 0;
      var withViews = 0;
      var live = 0;
      String? error;
      var next = tab == YtChannelTab.videos ? page : null;
      if (next == null) {
        final r = await router.run(
          (s) => (s as YtDirectSource).channelTab(
            channelId,
            tab,
            channelName: info?.name,
          ),
        );
        if (r.ok && r.value != null) {
          next = r.value!;
        } else {
          error = r.verdict.toString();
        }
      }
      while (next != null) {
        pages.add(next.items.length);
        for (final item in next.items) {
          if (sample.length < 3) sample.add('$item');
          if (item case final YtSearchItem v) {
            if (v.publishedText != null) withPublished++;
            if (v.viewCountText != null) withViews++;
            if (v.isLive) live++;
          }
        }
        final token = next.continuation;
        if (token == null || pages.length > 60) break;
        final r = await router.run(
          (s) => (s as YtDirectSource).channelTab(
            channelId,
            tab,
            continuation: token,
            channelName: info?.name,
          ),
        );
        if (!r.ok || r.value == null) {
          error = r.verdict.toString();
          break;
        }
        next = r.value!;
      }
      final total = pages.fold(0, (a, b) => a + b);
      allEnded &= error == null;
      if (tab == YtChannelTab.videos) {
        videosDated = withPublished == total && withViews == total;
      }
      tabs[tab.name] = {
        'pages': pages,
        'total': total,
        if (tab == YtChannelTab.videos || tab == YtChannelTab.streams) ...{
          'withPublished': withPublished,
          'withViews': withViews,
          'live': live,
        },
        'error': ?error,
        'sample': sample,
      };
    }
    // the sort chips, and that choosing one reloads the list
    Map<String, Object?>? sort;
    if (page.chips.length > 1) {
      final chip = page.chips[1];
      final r = await router.run(
        (s) => (s as YtDirectSource).channelTab(
          channelId,
          YtChannelTab.videos,
          continuation: chip.token,
          channelName: info?.name,
        ),
      );
      sort = {
        'chips': [for (final c in page.chips) c.text],
        'chosen': chip.text,
        'items': r.value?.items.length,
        'first': r.value?.items.firstOrNull?.toString(),
        'error': r.ok ? null : r.verdict.toString(),
      };
    }
    final avatarNotBanner =
        info?.avatar != null && info?.avatar?.url != info?.banner?.url;
    final kurzgesagt = channelId == 'UCsXVk37bltHxD1rDPwtNM8Q';
    final videos = tabs['videos'] as Map?;
    final shorts = tabs['shorts'] as Map?;
    final counts =
        !kurzgesagt || (videos?['total'] == 251 && shorts?['total'] == 140);
    return {
      'pass':
          info != null &&
          tabs.isNotEmpty &&
          allEnded &&
          videosDated &&
          avatarNotBanner &&
          counts,
      'channelId': channelId,
      // 'name' is the framework's key for the scenario; do not collide
      'channelName': info?.name,
      'handle': info?.handle,
      'subscribers': info?.subscriberText,
      'videoCount': info?.videoCountText,
      'avatar': info?.avatar?.toString(),
      'banner': info?.banner?.toString(),
      'avatarNotBanner': avatarNotBanner,
      'link': info?.link,
      'tabsListed': [for (final t in page.tabs.keys) t.name],
      'tabs': tabs,
      'sort': sort,
      'expectedCounts': kurzgesagt ? '视频 251 + Shorts 140' : null,
    };
  }

  /// `--yt-playlist ID`: a playlist paged to its end. Pass: the total is the
  /// header's 'N 个视频' (the uploads list `UUsX…` → 391).
  static Future<Map<String, dynamic>> _youtubePlaylist(
    String playlistId,
  ) async {
    final router = YtSourceRouter(YtDirectSource.create());
    final pages = <int>[];
    YtPlaylistInfo? info;
    String? token;
    String? error;
    do {
      final current = token;
      final r = await router.run(
        (s) => (s as YtDirectSource).playlist(
          playlistId,
          continuation: current,
        ),
      );
      if (!r.ok || r.value == null) {
        error = r.verdict.toString();
        break;
      }
      info ??= r.value!.info;
      pages.add(r.value!.videos.items.length);
      token = r.value!.videos.continuation;
    } while (token != null && pages.length < 60);
    final total = pages.fold(0, (a, b) => a + b);
    return {
      'pass': error == null && info?.count != null && total == info!.count,
      'playlistId': playlistId,
      'title': info?.title,
      'owner': info?.ownerName,
      'countText': info?.countText,
      'pages': pages,
      'total': total,
      'error': ?error,
    };
  }

  /// `--yt-post-probe ID`: the channel's first post opened as its detail
  /// page, and its comments paged twice and a thread's replies — through
  /// `browse`, where a video's go through `next`.
  static Future<Map<String, dynamic>> _youtubePostProbe(
    String channelId,
  ) async {
    final router = YtSourceRouter(YtDirectSource.create());
    final tab = await router.run(
      (s) => (s as YtDirectSource).channelTab(channelId, YtChannelTab.posts),
    );
    final post = tab.value?.items.whereType<YtPost>().firstOrNull;
    final params = post?.detailParams;
    if (params == null) {
      return {'pass': false, 'error': 'no post', 'verdict': '${tab.verdict}'};
    }
    final detail = await router.run(
      (s) => (s as YtDirectSource).postDetail(params),
    );
    final token = detail.value?.commentsToken;
    if (token == null) {
      return {'pass': false, 'error': 'no comments token', 'post': '$post'};
    }
    final page1 = await router.run(
      (s) => (s as YtDirectSource).postComments(token),
    );
    final next = page1.value?.continuation;
    final page2 = next == null
        ? null
        : await router.run((s) => (s as YtDirectSource).postComments(next));
    final threaded = page1.value?.items.where((c) => c.hasReplies).firstOrNull;
    final replies = threaded == null
        ? null
        : await router.run(
            (s) => (s as YtDirectSource).postComments(threaded.replyToken!),
          );
    return {
      'pass':
          detail.value?.post.postId == post!.postId &&
          (page1.value?.items.length ?? 0) > 0 &&
          (page2 == null || (page2.value?.items.length ?? 0) > 0) &&
          (replies == null || (replies.value?.items.length ?? 0) > 0),
      'post': '$post',
      'commentCount': post.commentCountText,
      'page1': page1.value?.items.length,
      'page2': page2?.value?.items.length,
      'replies': replies?.value?.items.length,
      'firstComment': page1.value?.items.firstOrNull?.toString(),
    };
  }

  /// The bounds of the cards on screen and of the parts inside each, for
  /// `--ui-shots`: numbers to compare two builds by, where a screenshot
  /// would be compared by eye. Found by type *name*, so the same probe runs
  /// on a build without the newer widgets. A part's rect is relative to its
  /// card, so two cards at different scroll positions still compare.
  static Map<String, Object?> _uiGeometry() {
    const cards = {
      'VideoCardH',
      'VideoCardHMemberVideo',
      'SeasonSeriesCard',
      'YtVideoTile',
      'YtPlaylistCard',
      'DynamicPanel',
      'YtPostCard',
      'UserInfoCard',
      'YtChannelHeader',
      'PgcCardVMemberPgc',
      'PortraitCardFrame',
      'TabBar',
      'SliverFloatingHeaderWidget',
    };
    const parts = {
      'NetworkImgLayer',
      'PBadge',
      'StatWidget',
      'VideoPopupMenu',
      'Text',
      'PendantAvatar',
      'FilledButton',
      'TextButton',
      'Tab',
      'VerticalDivider',
      'CachedNetworkImage',
    };
    String fmt(Rect x) =>
        '${x.left.toStringAsFixed(1)},${x.top.toStringAsFixed(1)} '
        '${x.width.toStringAsFixed(1)}x${x.height.toStringAsFixed(1)}';
    Rect? rectOf(Element e) {
      final box = e.renderObject;
      if (box is RenderBox && box.hasSize && box.attached) {
        return box.localToGlobal(Offset.zero) & box.size;
      }
      return null;
    }

    final out = <String, List<Object?>>{};
    void visit(Element e) {
      final name = e.widget.runtimeType.toString();
      if (cards.contains(name) && (out[name]?.length ?? 0) < 2) {
        final rect = rectOf(e);
        if (rect != null && rect.width > 0) {
          final inner = <String>[];
          void visitInner(Element c) {
            final n = c.widget.runtimeType.toString();
            if (parts.contains(n) && inner.length < 24) {
              final r = rectOf(c);
              if (r != null) {
                final w = c.widget;
                final label = w is Text
                    ? '"${(w.data ?? w.textSpan?.toPlainText() ?? '').characters.take(8)}"'
                    : '';
                inner.add('$n$label ${fmt(r.shift(-rect.topLeft))}');
              }
            }
            c.visitChildren(visitInner);
          }

          e.visitChildren(visitInner);
          (out[name] ??= []).add({'rect': fmt(rect), 'parts': inner});
        }
      }
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return out;
  }

  /// `--ui-shots DIR`: the bilibili lists that share a card frame with
  /// YouTube (search, related, the space's 投稿 / 动态 / 合集), and the
  /// YouTube channel with each of its tabs, a playlist and a post, at one
  /// wide and one narrow width. Run on a build before and after a change to
  /// the shared components to see that both sides moved together.
  ///
  /// Widgets are found by type *name*, so the same probe also runs on a
  /// build where a YouTube widget does not exist yet.
  static Future<Map<String, dynamic>> _uiShots({
    required String mid,
    required String bvid,
    required String channel,
    required String query,
    String streamsChannel = 'UCknLrEdhRCp1aegoMqRaCZg',
  }) async {
    final shots = <String?>[];
    final missing = <String>[];
    final geometry = <String, Object?>{};
    // how many UI errors had been raised when each shot was taken, so an
    // error can be placed between two steps
    final errorsAt = <String, int>{};
    Future<void> settle([int seconds = 5]) =>
        Future.delayed(Duration(seconds: seconds));
    Future<void> shot(String name) async {
      shots.add(await _shot(name));
      geometry[name] = _uiGeometry();
      errorsAt[name] = uiErrors.length;
    }

    Future<bool> tapType(String type) =>
        _tap((e) => e.widget.runtimeType.toString() == type);
    Future<void> tab(String label, String name) async {
      if (await _tapText(label)) {
        await settle(4);
        await shot(name);
      } else {
        missing.add(name);
      }
    }

    Future<void> back() async {
      Get.back();
      await settle(1);
    }

    for (final (width, tag) in const [(1100.0, 'wide'), (420.0, 'narrow')]) {
      await SelfTestWindow.setSize(Size(width, 900));
      await settle(2);
      await shot('${tag}_bili_home');

      unawaited(
        Get.toNamed(
          '/searchResult',
          parameters: {'keyword': query, 'tag': 'shots$tag'},
        ),
      );
      await settle(6);
      await shot('${tag}_bili_search');
      await back();

      unawaited(
        PiliScheme.routePushFromUrl('https://www.bilibili.com/video/$bvid'),
      );
      await settle(8);
      await shot('${tag}_bili_video');
      await back();

      unawaited(Get.toNamed('/member?mid=$mid'));
      await settle(6);
      await shot('${tag}_bili_space');
      await tab('投稿', '${tag}_bili_space_contribute');
      // a 合集 opened as SeasonSeriesPage opens one (the page a YouTube
      // playlist is aligned with): by the first season among the 投稿
      // sub-tabs, which every UP with a 合集 has, unlike the 全部合集/列表 tab
      final contribute =
          _findElement((e) => e.widget is MemberContribute)?.widget
              as MemberContribute?;
      final heroTag = contribute?.heroTag;
      final season =
          heroTag != null && Get.isRegistered<MemberContributeCtr>(tag: heroTag)
          ? Get.find<MemberContributeCtr>(
              tag: heroTag,
            ).items?.where((i) => i.seasonId != null).firstOrNull
          : null;
      if (season != null) {
        unawaited(
          Get.to(
            SimpleScaffold(
              appBar: AppBar(title: Text(season.title ?? '')),
              body: ViewSafeArea(
                child: MemberVideo(
                  type: ContributeType.season,
                  heroTag: heroTag,
                  mid: int.parse(mid),
                  seasonId: season.seasonId,
                  title: season.title,
                ),
              ),
            ),
          ),
        );
        await settle(6);
        await shot('${tag}_bili_season_page');
        await back();
      } else {
        missing.add('${tag}_bili_season_page');
      }
      await tab('动态', '${tag}_bili_space_dynamic');
      await back();

      unawaited(
        Get.toNamed('/ytSearchResult', parameters: {'keyword': query}),
      );
      await settle(6);
      await shot('${tag}_yt_search');
      await back();

      // tabs are chosen through the page's own tab controller: a tap on a
      // label found by its text can land on a covered route's label of the
      // same text (the home page has a 直播 tab)
      Future<void> ytTab(String id, YtChannelTab t, String name) async {
        final page = Get.isRegistered<YtChannelController>(tag: id)
            ? Get.find<YtChannelController>(tag: id)
            : null;
        final index = page?.tabs.indexOf(t) ?? -1;
        if (page == null || index < 0) {
          missing.add(name);
          return;
        }
        page.tabController?.animateTo(index);
        await settle(5);
        await shot(name);
      }

      unawaited(Get.toNamed('/ytChannel', parameters: {'id': channel}));
      await settle(6);
      await shot('${tag}_yt_channel');
      await ytTab(channel, YtChannelTab.videos, '${tag}_yt_videos');
      await ytTab(channel, YtChannelTab.shorts, '${tag}_yt_shorts');
      await ytTab(channel, YtChannelTab.posts, '${tag}_yt_posts');
      // opened as its own tap does, not by tapping its centre: that lands
      // on the image as often as not, and opens the image viewer
      if (_findElement((e) => e.widget is YtPostCard)?.widget
          case final YtPostCard card) {
        YtPostCard.open(card.post);
        await settle(8);
        await shot('${tag}_yt_post_detail');
        await back();
      } else {
        missing.add('${tag}_yt_post_detail');
      }
      await ytTab(channel, YtChannelTab.playlists, '${tag}_yt_playlists');
      if (await tapType('YtPlaylistCard')) {
        await settle(6);
        await shot('${tag}_yt_playlist');
        await back();
      } else {
        missing.add('${tag}_yt_playlist');
      }
      await back();

      // 直播 needs a channel that streams
      unawaited(Get.toNamed('/ytChannel', parameters: {'id': streamsChannel}));
      await settle(6);
      await ytTab(streamsChannel, YtChannelTab.streams, '${tag}_yt_streams');
      await back();
    }
    return {
      'pass': !shots.any((s) => s == null || s.startsWith('failed')),
      'shots': shots,
      'missing': missing,
      'errorsAt': errorsAt,
      'geometry': geometry,
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
    var commentsShownFromEarlyTab = false;
    var previewEntries = 0;
    var narrowErrors = const <String>[];
    var threadSheetOpened = false;
    String? routeWithThreadOpen;
    var commentsBefore = 0;
    var commentsAfter = 0;
    var repliesBefore = 0;
    var repliesAfter = 0;
    var threadHasMore = false;
    var threadFooterSeen = false;
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
      // Open the comments tab immediately, while the video is still
      // loading. Doing that used to close the "already started" latch on an
      // attempt made before the token existed, and the tab then stayed empty
      // for good.
      await Future.delayed(const Duration(milliseconds: 1200));
      await _tapText('评论');
      await Future.delayed(const Duration(seconds: 5));
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
      // and they are on screen, not merely fetched: the tab was opened
      // before any of this and never touched again
      commentsShownFromEarlyTab = controller.comments.any(
        (c) => _seesText(c.author),
      );
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
      // Phone width, which is where a row that grew a new button overflows.
      // Every probe so far ran in a wide desktop window, so the narrow
      // layout — the one most people use — was never rendered at all.
      narrowErrors = await _atWidth(400, const Duration(seconds: 3));

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
                  e.widget is Text && _textOf(e.widget as Text).contains('条回复'),
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
        // tapping a comment must open the thread: the row used to be inert
        // unless it happened to carry a reply preview
        // the thread opened is the one that has replies, so the panel's own
        // pagination can be exercised
        final head = thread;
        if (await _tapText(head.content)) {
          // the panel's own chrome, not just that something opened: the
          // title bar and the 「相关回复共N条」 line bilibili puts above the
          // replies
          threadSheetOpened =
              (_seesText('评论详情') || _seesLabel('评论详情')) && _seesLabel('相关回复');
          // in-pane or window-wide? Both show the title, so the title
          // cannot tell them apart. A sheet inside the comment area is a
          // local history entry and leaves the route alone; a panel pushed
          // over the window does not.
          routeWithThreadOpen = Get.currentRoute;
          if (threadSheetOpened) {
            // and its own second page: the panel asks for more replies the
            // same way the list asks for more comments, from the row at the
            // end, so it too has to be scrolled to
            final threadId = head.commentId;
            {
              for (var i = 0; i < 12; i++) {
                await Future.delayed(const Duration(seconds: 1));
                repliesBefore = controller.replies[threadId]?.length ?? 0;
                if (repliesBefore > 0) break;
              }
              final panel = _boxOf(
                (e) =>
                    e.widget is Text &&
                    _textOf(e.widget as Text).startsWith('评论详情'),
              );
              if (panel != null && repliesBefore > 0) {
                final at = panel.localToGlobal(
                  panel.size.center(const Offset(0, 200)),
                );
                for (var round = 0; round < 6; round++) {
                  await _scroll(at, 600);
                  final now = controller.replies[threadId]?.length ?? 0;
                  if (now > repliesBefore) break;
                }
                repliesAfter = controller.replies[threadId]?.length ?? 0;
              }
              // "no next page" and "never scrolled to the row that asks"
              // look the same in the counts alone
              threadHasMore = controller.hasMoreReplies(threadId);
              threadFooterSeen = _seesText('加载中...') || _seesText('没有更多了');
            }
            Get.back();
            await Future.delayed(const Duration(milliseconds: 700));
          }
        }

        repliesShown =
            first != null &&
            _findElement(
                  (e) =>
                      e.widget is Text &&
                      _textOf(e.widget as Text).startsWith(first.author),
                ) !=
                null;
        // page two: scroll to the end of the list and see whether more
        // comments arrive. The trigger lives in the footer's build, so a
        // list that is never scrolled never asks.
        final box = _boxOf(
          (e) => e.widget is Text && _textOf(e.widget as Text) == head.content,
        );
        if (box != null) {
          commentsBefore = controller.comments.length;
          final at = box.localToGlobal(box.size.center(Offset.zero));
          for (var round = 0; round < 6; round++) {
            await _scroll(at, 600);
            if (controller.comments.length > commentsBefore) break;
          }
          commentsAfter = controller.comments.length;
        }
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
        openedBuffer =
            player.videoPlayerController?.state.buffer.inMilliseconds;
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
          if (!subtitlePanel)
            afterSubtitleTap = _visibleTexts().take(24).toList();
        }
        // closes whichever of the two is open
        Get.back();
        await Future.delayed(const Duration(milliseconds: 700));
      }
      player.showControls.value = true;
      await Future.delayed(const Duration(milliseconds: 700));
      if (await _tapTooltip('字幕')) {
        // the caption menu is where someone stands when they find a video
        // has no subtitles, so the transcription row has to be reachable
        // from here and not only from 更多设置
        captionMenu = _seesText('关闭字幕') && _seesLabel('语音识别字幕');
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
          commentsShownFromEarlyTab &&
          narrowErrors.isEmpty &&
          threadSheetOpened &&
          routeWithThreadOpen?.startsWith('/ytVideo') == true &&
          commentsAfter > commentsBefore &&
          repliesAfter > repliesBefore &&
          // the resize has to have happened for its result to mean anything
          (narrowLogicalWidth ?? 9999) < 500 &&
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
      'commentsShownFromEarlyTab': commentsShownFromEarlyTab,
      'previewEntries': previewEntries,
      'narrowErrors': narrowErrors,
      'threadSheetOpened': threadSheetOpened,
      'routeWithThreadOpen': routeWithThreadOpen,
      'commentsBefore': commentsBefore,
      'commentsAfter': commentsAfter,
      'repliesBefore': repliesBefore,
      'repliesAfter': repliesAfter,
      'threadHasMore': threadHasMore,
      'threadFooterSeen': threadFooterSeen,
      'narrowWidth': narrowLogicalWidth,
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
  /// LibrePili: the watch history kept on this device, end to end.
  ///
  /// A bilibili video [bili] (a link or BV id) and a YouTube video [yt] are
  /// each played a few seconds, sought to [seekTo] s, played on, paused and
  /// left; both must be in [LocalHistory] with their platform, the part and
  /// a progress within 3 s of where the player was. With 暂停记录 on, a third
  /// video [paused] leaves no entry. Each is then opened again from its
  /// entry, the way the 本机 tab opens it, and must start where it was left
  /// (a fresh profile has no account: this device's point is the only one).
  /// Last, the 观看记录 page must list both with their platform marks.
  ///
  /// Clears the profile's local history first.
  static Future<Map<String, dynamic>> _historyProbe(
    String bili, {
    required String yt,
    required String paused,
    required int seekTo,
  }) async {
    final result = <String, dynamic>{};
    final fails = <String>[];
    await LocalHistory.setPaused(false);
    await LocalHistory.clear();

    String biliUrl(String s) =>
        s.startsWith('http') ? s : 'https://www.bilibili.com/video/$s';

    VideoDetailController? findVideoPage() {
      try {
        return Get.find<VideoDetailController>(
          tag: Get.parameters['heroTag'] ?? Get.arguments?['heroTag'],
        );
      } catch (_) {
        return null;
      }
    }

    Future<VideoDetailController?> waitVideoPage() async {
      for (var i = 0; i < 180; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        final page = findVideoPage();
        if (page != null && page.videoState.value) {
          // the player may still be opening the source
          await Future.delayed(const Duration(seconds: 2));
          return page;
        }
      }
      return null;
    }

    int? position(PlPlayerController player) =>
        player.videoPlayerController?.state.position.inMilliseconds;

    /// plays [lead] s, seeks to [seekTo], plays [after] s, pauses; returns
    /// the position at the pause (ms)
    Future<int?> watch(
      PlPlayerController player, {
      int lead = 4,
      int after = 5,
      bool seek = true,
    }) async {
      await player.play();
      await Future.delayed(Duration(seconds: lead));
      if (seek) {
        await player.seekTo(Duration(seconds: seekTo), isSeek: false);
        await player.play();
      }
      await Future.delayed(Duration(seconds: after));
      final at = position(player);
      await player.pause();
      await Future.delayed(const Duration(seconds: 1));
      return at;
    }

    Map<String, dynamic> describe(LocalWatchEntry? e) => {
      if (e != null) ...{
        'key': e.key,
        'platform': e.platform.name,
        'title': e.title,
        'author': e.author,
        'hasCover': e.cover?.isNotEmpty == true,
        'last': e.last,
        'parts': e.parts.length,
        'progress': e.lastPart?.progress,
        'duration': e.lastPart?.duration,
        'page': e.lastPart?.page,
      },
    };

    // ---- bilibili
    await PiliScheme.routePushFromUrl(biliUrl(bili));
    final page = await waitVideoPage();
    if (page == null) {
      return {'pass': false, 'reason': 'bilibili page never became ready'};
    }
    final biliKey = LocalHistory.ugcKey(page.aid);
    final biliCid = page.cid.value;
    final biliAt = await watch(page.plPlayerController);
    Get.back();
    await Future.delayed(const Duration(seconds: 3));
    final biliEntry = LocalHistory.get(biliKey);
    result['bili'] = {
      'aid': page.aid,
      'cid': biliCid,
      'positionAtPause': biliAt,
      'timeLength': page.data.timeLength,
      'entry': describe(biliEntry),
    };
    if (biliEntry == null) {
      fails.add('no bilibili entry');
    } else {
      final progress = biliEntry.lastPart?.progress ?? -1;
      if (biliEntry.platform != LocalHistoryPlatform.bili) {
        fails.add('bilibili platform');
      }
      if (biliEntry.last != '$biliCid') fails.add('bilibili part');
      if (biliEntry.title.isEmpty) fails.add('bilibili title');
      if (biliAt == null || (progress - biliAt).abs() > 3000) {
        fails.add('bilibili progress $progress vs $biliAt');
      }
      if (progress < seekTo * 1000) fails.add('bilibili seek not recorded');
      if ((biliEntry.lastPart?.duration ?? 0) <= 0) {
        fails.add('bilibili duration');
      }
    }

    // ---- YouTube
    final ytId = tryParseYouTubeVideoId(yt) ?? yt;
    unawaited(Get.toNamed('/ytVideo', parameters: {'id': ytId}));
    YtVideoController? ytPage;
    for (var i = 0; i < 180; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        ytPage = Get.find<YtVideoController>(tag: ytId);
      } catch (_) {}
      if (ytPage?.stage.value == YtPageStage.ready) break;
    }
    if (ytPage?.stage.value != YtPageStage.ready) {
      Get.back();
      return {
        ...result,
        'pass': false,
        'reason': 'YouTube page never became ready: ${ytPage?.message.value}',
      };
    }
    await Future.delayed(const Duration(seconds: 2));
    final ytAt = await watch(ytPage!.plPlayerController);
    Get.back();
    await Future.delayed(const Duration(seconds: 3));
    final ytEntry = LocalHistory.get(LocalHistory.ytKey(ytId));
    result['yt'] = {
      'id': ytId,
      'positionAtPause': ytAt,
      'entry': describe(ytEntry),
    };
    if (ytEntry == null) {
      fails.add('no YouTube entry');
    } else {
      final progress = ytEntry.lastPart?.progress ?? -1;
      if (ytEntry.platform != LocalHistoryPlatform.yt) {
        fails.add('YouTube platform');
      }
      if (ytEntry.title.isEmpty) fails.add('YouTube title');
      if (ytAt == null || (progress - ytAt).abs() > 3000) {
        fails.add('YouTube progress $progress vs $ytAt');
      }
      if (progress < seekTo * 1000) fails.add('YouTube seek not recorded');
      if ((ytEntry.lastPart?.duration ?? 0) <= 0) {
        fails.add('YouTube duration');
      }
    }
    final order = [for (final e in LocalHistory.entries()) e.key];
    result['order'] = order;
    if (order.length != 2 ||
        order.first != LocalHistory.ytKey(ytId) ||
        order.last != biliKey) {
      fails.add('order $order');
    }

    // ---- 暂停记录
    await LocalHistory.setPaused(true);
    await PiliScheme.routePushFromUrl(biliUrl(paused));
    final pausedPage = await waitVideoPage();
    if (pausedPage == null) {
      fails.add('paused video never became ready');
    } else {
      await watch(pausedPage.plPlayerController, seek: false);
      Get.back();
      await Future.delayed(const Duration(seconds: 3));
    }
    final afterPause = [for (final e in LocalHistory.entries()) e.key];
    result['whilePaused'] = afterPause;
    if (afterPause.length != 2) fails.add('recorded while paused');
    await LocalHistory.setPaused(false);

    // ---- opened again from the entries: resumes where it was left
    Future<int?> firstPosition(PlPlayerController player) async {
      // the player opens at the start point: wait for it to report one
      for (var i = 0; i < 20; i++) {
        final at = position(player);
        if (at != null && at > 0) return at;
        await Future.delayed(const Duration(milliseconds: 500));
      }
      return position(player);
    }

    if (biliEntry != null) {
      LocalHistoryItem.open(biliEntry);
      final again = await waitVideoPage();
      final at = again == null
          ? null
          : await firstPosition(again.plPlayerController);
      if (again != null) Get.back();
      await Future.delayed(const Duration(seconds: 3));
      final saved = biliEntry.lastPart?.progress ?? 0;
      result['biliReopenedAt'] = at;
      if (at == null || (at - saved).abs() > 3000) {
        fails.add('bilibili reopened at $at, saved $saved');
      }
    }
    if (ytEntry != null) {
      LocalHistoryItem.open(ytEntry);
      YtVideoController? again;
      for (var i = 0; i < 180; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          again = Get.find<YtVideoController>(tag: ytId);
        } catch (_) {}
        if (again?.stage.value == YtPageStage.ready) break;
      }
      final at = again == null
          ? null
          : await firstPosition(again.plPlayerController);
      if (again != null) Get.back();
      await Future.delayed(const Duration(seconds: 3));
      final saved = ytEntry.lastPart?.progress ?? 0;
      result['ytReopenedAt'] = at;
      if (at == null || (at - saved).abs() > 3000) {
        fails.add('YouTube reopened at $at, saved $saved');
      }
    }

    // ---- the page
    unawaited(Get.toNamed('/history'));
    await Future.delayed(const Duration(seconds: 3));
    final shown = {
      'bili title': biliEntry != null && _seesText(biliEntry.title),
      'yt title': ytEntry != null && _seesText(ytEntry.title),
      'B 站': _seesText(LocalHistoryPlatform.bili.label),
      'YouTube': _seesText(LocalHistoryPlatform.yt.label),
      // no account in a fresh profile: no tabs
      'no account tab': !_seesText('B 站账号'),
    };
    result['page'] = shown;
    for (final MapEntry(:key, :value) in shown.entries) {
      if (!value) fails.add('page: $key');
    }
    Get.back();
    await Future.delayed(const Duration(seconds: 1));

    return {...result, 'pass': fails.isEmpty, 'fails': fails};
  }

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
    // the video's language as the menu has it before any transcript: from
    // the platform's tracks alone (a dubbed video's first automatic track
    // was taken for it, 2026-09-29)
    final spokenAtReady = controller.spoken;
    final kinds = <String, int>{};
    for (final t in controller.platformTracks) {
      kinds[t.kind.name] = (kinds[t.kind.name] ?? 0) + 1;
    }
    final player = controller.plPlayerController;
    // autoplay is a user setting; the probe presses play itself so a paused
    // preference cannot be mistaken for a stream that will not run
    await player.play();
    await Future.delayed(const Duration(seconds: 2));
    final first = player.videoPlayerController?.state.position;
    await Future.delayed(Duration(seconds: holdSeconds));
    final second = player.videoPlayerController?.state.position;
    final keys = debugFocusProbe ? await _keyProbe(player) : null;
    final comments = debugCommentsProbe
        ? await _ytCommentsProbe(controller)
        : null;

    // captions are the half that the Invidious route could never deliver
    var captionOk = false;
    if (controller.captions.isNotEmpty) {
      await controller.setCaption(0);
      captionOk = controller.captionIndex.value == 0;
    }

    final advanced =
        first != null &&
        second != null &&
        second > first + const Duration(seconds: 1);

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
      'pass':
          controller.stage.value == YtPageStage.ready && advanced && stopped,
      'stage': controller.stage.value.name,
      'message': controller.message.value,
      'title': controller.detail.value?.title,
      'positionBefore': first?.inMilliseconds,
      'positionAfter': second?.inMilliseconds,
      'advanced': advanced,
      'buffer': player.videoPlayerController?.state.buffer.inMilliseconds,
      'captionTracks': controller.captions.length,
      'spokenAtReady': spokenAtReady,
      'trackKinds': kinds,
      'captionShown': captionOk,
      'via': controller.streams?.sourceId,
      // the streams themselves, for probes run against them (--dump-urls)
      if (debugDumpUrls) 'audioUrlFull': controller.streams?.audioUrl,
      'stoppedOnLeave': stopped,
      'positionAfterBack': afterBack?.inMilliseconds,
      'positionAfterBack2': afterBack2?.inMilliseconds,
      'keys': ?keys,
      'comments': ?comments,
    };
  }

  /// LibrePili: drives the YouTube data layer against the live service.
  ///
  /// The client identities in `yt_identity.dart` are documented as rotting:
  /// the offline fixture tests cannot notice when YouTube changes its mind,
  /// so this asks the real thing before the layer is wired to the player.
  /// `--quality-codecs <BV… | YouTube id>`: for every quality the list
  /// offers, the codecs it comes in, the one the player would pick, and
  /// whether the list marks it 「软解码」 on this device. Anonymous, like
  /// the app's own requests unless login mode is on.
  static Future<Map<String, dynamic>> _qualityCodecs(String input) async {
    // the start's own check runs unawaited; the answer is wanted here
    await CodecSupport.check();
    final hardware = CodecSupport.hardware;
    final hardwareDecoding = CodecSupport.hardwareDecodingOn;
    final result = <String, dynamic>{
      'hardware': {for (final e in hardware.entries) e.key.name: e.value},
      'hardwareDecodingOn': hardwareDecoding,
      'av1Hardware': GStorage.setting.get(SettingBoxKey.av1Hardware),
      'preferCodecs': [for (final c in Pref.preferCodecs) c.name],
    };
    final bv = IdUtils.bvRegex.firstMatch(input)?.group(0);
    if (bv != null) {
      final intro = await VideoHttp.videoIntro(bvid: bv);
      final cid = intro.dataOrNull?.cid;
      if (cid == null) return {...result, 'pass': false, 'reason': 'no cid'};
      Future<PlayUrlModel?> play(int qn) async => (await VideoHttp.videoUrl(
        bvid: bv,
        cid: cid,
        qn: qn,
        tryLook: true,
        videoType: VideoType.ugc,
      )).dataOrNull;
      // the page's two requests: the best, then what it left out below it
      final data = await play(VideoQuality.hdrVivid.code);
      final videos = data?.dash?.video;
      if (data == null || videos == null) {
        return {...result, 'pass': false, 'reason': 'no dash'};
      }
      final missing = data.missingVideoQualityBelowHighest;
      if (missing != -1) videos.merge((await play(missing))?.dash?.video);
      final preference = [for (final c in Pref.preferCodecs) c.codes];
      final software = biliSoftwareQualities(
        videos: videos,
        preference: preference,
        hardware: hardware,
        hardwareDecoding: hardwareDecoding,
      );
      final byQuality = <int, List<String>>{};
      for (final v in videos) {
        (byQuality[v.id] ??= []).add(v.codecs ?? '?');
      }
      result
        ..['bvid'] = bv
        ..['title'] = intro.dataOrNull?.title
        ..['supportFormats'] = [
          for (final f in data.supportFormats ?? const <FormatItem>[])
            {'quality': f.quality, 'desc': f.newDesc, 'codecs': f.codecs},
        ]
        ..['qualities'] = [
          for (final MapEntry(key: qa, value: offered) in byQuality.entries)
            {
              'quality': qa,
              'desc': VideoQuality.fromCode(qa).desc,
              'offered': offered,
              'picked': pickCodec(offered, preference),
              'software': software.contains(qa),
              'hardwareAlternative': ?hardwareAlternative(
                offered: offered,
                preference: preference,
                hardware: hardware,
              ),
            },
        ];
      return {...result, 'pass': true};
    }
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    final router = YtSourceRouter(YtDirectSource.create());
    final detail = await router.run((s) => s.detail(videoId));
    final formats = detail.value?.formats;
    if (formats == null) {
      return {...result, 'pass': false, 'reason': detail.verdict.toString()};
    }
    final heights = <int>{
      for (final f in formats)
        if (f.isVideo && f.isPlayable && f.height != null) f.height!,
    }.toList()..sort((a, b) => b.compareTo(a));
    final software = ytSoftwareHeights(
      formats: formats,
      heights: heights,
      hardware: hardware,
      hardwareDecoding: hardwareDecoding,
    );
    result
      ..['videoId'] = videoId
      ..['title'] = detail.value?.title
      ..['heights'] = [
        for (final h in heights)
          {
            'height': h,
            'offered': {
              for (final f in formats)
                if (f.isVideo && f.isPlayable && f.height == h) f.codecFamily,
            }.toList(),
            'picked': switch (selectYtVideoFormat(
              formats,
              YtFormatPreference(maxHeight: h),
            )) {
              final f? => '${f.codec} ${f.width}x${f.height}',
              null => null,
            },
            'software': software.contains(h),
          },
      ];
    return {...result, 'pass': true};
  }

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
      configuration: PlayerConfiguration(
        logLevel: MPVLogLevel.error,
        // muted unless the run asked for sound (see selfTestSound)
        options: {if (!selfTestSound) 'mute': 'yes'},
      ),
    );
    final native = player;
    final samples = <Map<String, dynamic>>[];
    try {
      native
        ..setProperty('cache', 'yes')
        ..setProperty('cache-secs', '16');
      player.setMediaHeader(
        userAgent: BrowserUa.pc,
        referer: HttpString.baseUrl,
      );
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
  static Future<Map<String, dynamic>> _asrDownload(
    String dir, {
    bool english = false,
  }) async {
    // An empty --asr-download resolves Directory('') to the working
    // directory, and 240 MB of models landed in the repo. A blank argument
    // means "wherever the app keeps them", which under --selftest is the
    // self test's own profile and persists between runs.
    final store = AsrModelStore(
      root: dir.trim().isEmpty ? null : Directory(dir),
    );
    final started = DateTime.now();
    var lastLabel = '';
    final steps = <String>[];
    // one background job over both, as the app holds one per user action
    // (lib/services/background_transfer.dart). Scheduled only if the app is
    // on screen: `am start` behind the lock screen gets `keepAlive` false,
    // and the download is then cut off with the rest of the app's network.
    final transfer = BackgroundTransfer.instance;
    final bytes = [
      ...store.missing,
      if (english && !store.isEnglishReady) AsrModelCatalog.parakeet,
    ].fold(0, (sum, model) => sum + model.totalSize);
    await transfer.run(
      title: '下载语音识别模型',
      bytes: bytes,
      token: AsrCancelToken(),
      body: (keepAlive) async {
        void onProgress(AsrProgress p) {
          keepAlive(p);
          if (p.label != lastLabel) {
            lastLabel = p.label;
            steps.add(p.label);
          }
        }

        await store.ensureAll(onProgress: onProgress);
        // `--with-english`: the optional English model too (Parakeet, from
        // the project's mirror), with the licence files it is installed with
        if (english) {
          await store.ensure(AsrModelCatalog.parakeet, onProgress: onProgress);
        }
      },
    );
    final ms = DateTime.now().difference(started).inMilliseconds;
    final models = [
      ...AsrModelCatalog.required,
      if (english) AsrModelCatalog.parakeet,
    ];
    return {
      'pass':
          store.isReady &&
          (!english || store.isInstalled(AsrModelCatalog.parakeet)),
      'ms': ms,
      'bytes': store.installedBytes(),
      'steps': steps,
      'keepAlive': transfer.lastStart?.scheduled,
      'keepAliveReason': transfer.lastStart?.reason,
      if (english)
        'englishNotice': File(
          path.join(store.dirOf(AsrModelCatalog.parakeet).path, 'NOTICE.txt'),
        ).existsSync(),
      'files': [
        for (final model in models)
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
  /// Chunked transcription, probe P0
  /// (research/chunked-transcription-design-2026-09-25.md): audio extracted
  /// from each position in [at], [window] seconds of it, through a proxy
  /// that counts the bytes. Answers where a run from a position really
  /// starts (the PCM is kept in [dir] to be lined up against a run from 0),
  /// whether the audio before it is downloaded, and how long it takes.
  static Future<Map<String, dynamic>> _asrStartProbe(
    String source, {
    required List<double> at,
    required double window,
    required String dir,
  }) async {
    await Directory(dir).create(recursive: true);
    final last = at.reduce(math.max);
    final runs = <Map<String, Object?>>[];
    for (final start in at) {
      final proxy = _CuttingProxy(1 << 50);
      await proxy.start();
      final output = path.join(dir, 'pcm_${start.round()}.pcm');
      final cancel = '$output.cancel';
      // the run from 0 goes past every other start, to line them up with
      final seconds = start == 0 ? last + window : window;
      final clock = Stopwatch()..start();
      Timer? watch;
      watch = Timer.periodic(const Duration(milliseconds: 100), (_) {
        final file = File(output);
        if (file.existsSync() &&
            file.lengthSync() >= seconds * asrBytesPerSecond) {
          File(cancel).writeAsStringSync('stop');
          watch?.cancel();
        }
      });
      Object? error;
      try {
        await AsrAudioExtractor.extract(
          source: proxy.wrap(source),
          output: output,
          referer: HttpString.baseUrl,
          userAgent: BrowserUa.pc,
          cancelPath: cancel,
          startSeconds: start,
          timeout: const Duration(minutes: 10),
        );
      } catch (e) {
        error = e;
      } finally {
        watch.cancel();
        await proxy.close();
      }
      final landing = File(AsrAudioExtractor.landingFileFor(output));
      runs.add({
        'at': start,
        'wallMs': clock.elapsedMilliseconds,
        'pcmBytes': File(output).existsSync() ? File(output).lengthSync() : 0,
        'bytesDownloaded': proxy.bytesSent,
        'requests': proxy.requests,
        'landing': landing.existsSync()
            ? jsonDecode(landing.readAsStringSync())
            : null,
        'error': ?error?.toString(),
      });
    }
    return {'pass': runs.every((r) => r['error'] == null), 'runs': runs};
  }

  /// Chunked transcription, V7
  /// (research/chunked-transcription-design-2026-09-25.md): a transcription
  /// as a page runs it — [AsrService.start], extraction and recognition
  /// overlapping — and what its session ends up holding, written as SRT with
  /// [srtOut]. `--asr` drives the recogniser alone and never sees the
  /// session; a change to how the session keeps the text is checked with
  /// this, a run before it against a run after, cue for cue.
  /// Every segment (by its time) and cue (by its start and text) of
  /// [session], for `--asr-off-at`: what was made before the switch-off
  /// must all be there at the end.
  static List<String> _switchKeys(AsrSession session) => [
    for (final s in session.segments)
      'segment ${s.start.toStringAsFixed(2)}+${s.duration.toStringAsFixed(2)}',
    for (final c in session.cues)
      'cue ${c.from.toStringAsFixed(2)} ${c.content}',
  ];

  static AsrPower? _power(String? name) =>
      AsrPower.values.where((p) => p.name == name).firstOrNull;

  static bool _isBiliUrl(String source) {
    final host = Uri.tryParse(source)?.host ?? '';
    return host.contains('bilivideo') || host.contains('akamaized');
  }

  /// [power] forces the lead rule (design 12) — `battery` on a desktop is
  /// how pausing and resuming are exercised here — and [playheadSpeed]
  /// moves a pretend playhead from 0 at that many times real time, as a
  /// viewer watching straight through would (only faster). Without it the
  /// playhead stays at 0, as it did before there was one.
  ///
  /// [offAt] and [onAt] (media seconds of that playhead; `--asr-off-at`,
  /// `--asr-on-at`) turn the subtitle switch off and on again there
  /// (design 2026-09-26, 4): [AsrSession.windDown], then
  /// [AsrSession.resumeOn]. Reported under `switch`: where the wind-down
  /// was to stop and where it did, every stage seen while off, the runs
  /// started meanwhile, and whether any segment made before the switch-off
  /// was gone at the end. Without [onAt] it ends 10 s after winding down.
  ///
  /// A local file is kept in the subtitle cache (design 2026-09-26, 9B):
  /// run again on the same profile, what was kept is shown at once and only
  /// the rest is transcribed. Reported under `cache`: the seconds the entry
  /// covered at the start, and the recogniser runs it took after. [stopAt]
  /// (`--asr-stop-at`) stops the session once what it covers from 0 reaches
  /// that far, for a partial entry.
  static Future<Map<String, dynamic>> _asrSession(
    String source, {
    String? srtOut,
    AsrPower? power,
    double? playheadSpeed,
    double? offAt,
    double? onAt,
    double? stopAt,
    bool? english,
  }) async {
    final service = AsrService.to;
    if (!service.modelsReady) {
      return {'pass': false, 'reason': 'models missing'};
    }
    // `--asr-english 0|1`: the English model switched off or on, as the
    // setting does (it is on unless switched off)
    if (english != null) {
      await GStorage.setting.put(SettingBoxKey.asrEnglishModel, english);
    }
    if ((offAt != null || onAt != null) && playheadSpeed == null) {
      return {'pass': false, 'reason': '--asr-off-at needs a playhead speed'};
    }
    final isFile = File(source).existsSync();
    final clock = Stopwatch()..start();
    double playheadNow() => clock.elapsedMilliseconds / 1000 * playheadSpeed!;
    var changes = 0;
    final session = await service.start(
      key: 'selftest-session',
      source: source,
      referer: _isBiliUrl(source) ? HttpString.baseUrl : null,
      userAgent: isFile ? null : BrowserUa.pc,
      power: power,
      playhead: playheadSpeed == null ? null : playheadNow,
      cache: isFile ? SubtitleCacheKey.local(source) : null,
    );
    // each change is one segment's cues arriving: the pace every listener
    // (page gates, the translation track) is woken at
    final sub = session.cues.listen((_) => changes++);
    _progress = () => {
      ...session.debugStatus,
      'runs': session.runCount,
      'pauses': session.pauses,
      'resumes': session.resumes,
      'covered': session.coveredSeconds,
      'englishLoadMs': session.englishLoadMs,
      'englishFrom': session.englishFrom,
    };
    // when the first cue was there: at once, from a cache entry
    int? firstCueMs;
    final firstCue = session.cues.listen((cues) {
      if (cues.isNotEmpty) firstCueMs ??= clock.elapsedMilliseconds;
    });
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    var stopped = false;
    while (session.state.value.isBusy && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (offAt != null && playheadNow() >= offAt) break;
      if (stopAt != null && session.transcript.coveredEnd(0) >= stopAt) {
        stopped = true;
        break;
      }
    }
    // the switch, when asked for
    Map<String, Object?>? switched;
    List<String>? before;
    final stagesOff = <String>[];
    DateTime? woundAt;
    var on = false;
    // standby is alive too: paused ahead of a playhead still coming, or
    // switched off
    while (!stopped &&
        (session.state.value.isBusy ||
            session.state.value.stage == AsrStage.standby) &&
        DateTime.now().isBefore(deadline)) {
      final p = playheadSpeed == null ? 0.0 : playheadNow();
      if (offAt != null && switched == null && p >= offAt) {
        before = _switchKeys(session);
        session.windDown();
        switched = {
          'offAt': p,
          'windDownUntil': session.windDownUntil,
          'window': (session.windDownUntil ?? p) - p,
          'speedAtOff': session.pace.speed,
          'restartCostAtOff': session.pace.restartCost,
          'coveredEndAtOff': coveredEndOf(session.transcript.covered, p),
          'runsAtOff': session.runCount,
          'segmentsAtOff': before.length,
        };
      }
      if (switched != null && !on) {
        final stage = session.state.value.stage.name;
        if (stagesOff.isEmpty || stagesOff.last != stage) stagesOff.add(stage);
        if (woundAt == null && session.isWoundDown) {
          woundAt = DateTime.now();
          switched
            ..['woundDownAtPlayhead'] = p
            ..['coveredEndAtWoundDown'] = coveredEndOf(
              session.transcript.covered,
              offAt!,
            )
            ..['runsAtWoundDown'] = session.runCount
            ..['messageAtWoundDown'] = session.state.value.message;
        }
        if (onAt != null && p >= onAt) {
          on = true;
          switched
            ..['onAt'] = p
            ..['runsAtOn'] = session.runCount
            ..['stageAtOn'] = stage
            ..['coveredEndAtOn'] = coveredEndOf(
              session.transcript.covered,
              offAt!,
            );
          session.resumeOn();
        }
        if (onAt == null &&
            woundAt != null &&
            DateTime.now().difference(woundAt) > const Duration(seconds: 10)) {
          switched
            ..['runsAtEnd'] = session.runCount
            ..['stageAtEnd'] = stage;
          break;
        }
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (switched != null) {
      final after = _switchKeys(session).toSet();
      switched
        ..['stagesWhileOff'] = stagesOff
        ..['missingAfter'] = [
          for (final k in before!)
            if (!after.contains(k)) k,
        ];
    }
    await sub.cancel();
    await firstCue.cancel();
    final cues = session.cues.toList();
    final segments = session.segments.length;
    final segmentList = session.segments;
    final state = session.state.value;
    final runs = session.runCount;
    final pace = session.pace;
    final coveredAtEnd = session.coveredSeconds;
    await service.stop(only: session);
    // the entry written as the session ended, before the report says so
    final entry = session.cache;
    if (entry != null) await entry.save();
    if (srtOut != null && cues.isNotEmpty) {
      await File(srtOut).writeAsString(cues.toSrt());
    }
    return {
      'runs': runs,
      'pauses': session.pauses,
      'resumes': session.resumes,
      'power': session.power.name,
      'speed': pace.speed,
      'speedSamples': pace.speedSamples,
      'restartCost': pace.restartCost,
      'restartSamples': pace.costSamples,
      'seams': session.debugSeams,
      'pass': (stopped || state.stage == AsrStage.done) && cues.isNotEmpty,
      'switch': ?switched,
      'cache': {
        'kept': entry != null,
        'cachedSecondsAtStart': session.cachedSeconds,
        'coveredSecondsAtEnd': coveredAtEnd,
        'firstCueMs': firstCueMs,
        'stoppedAt': stopped ? session.transcript.coveredEnd(0) : null,
        'dir': service.cache.dir.path,
      },
      'source': source,
      'stage': state.stage.name,
      'language': state.language,
      'ms': clock.elapsedMilliseconds,
      'cueCount': cues.length,
      'segmentCount': segments,
      'cueChanges': changes,
      'lastCueEnd': cues.isEmpty ? null : cues.last.to,
      // the English model (AsrEnglishGate): whether it was there, where the
      // gate said English, how long its background load took, and where
      // its first segment starts — every one after it in a run from 0 is
      // its own
      'english': {
        'setting': Pref.asrEnglishModel,
        'installed': service.store.isEnglishReady,
        'wanted': session.englishWanted,
        'decidedAt': session.englishDecidedAt,
        'loadMs': session.englishLoadMs,
        'from': session.englishFrom,
      },
      'segments': [
        for (final s in segmentList)
          {
            'start': s.start,
            'duration': s.duration,
            'lang': s.language,
            'run': s.run,
          },
      ],
    };
  }

  /// Chunked transcription, V4/V5
  /// (research/chunked-transcription-design-2026-09-25.md): a transcription
  /// as a page runs it, the viewer jumping to each of [seeks] in turn; for
  /// each, how long until the transcript covers [window] seconds from there
  /// — what the page hands the player at once when it does — and how many
  /// runs the session has made by then.
  static Future<Map<String, dynamic>> _asrSeekProbe(
    String source, {
    required List<double> seeks,
    required double window,
    int dwell = 0,
  }) async {
    final service = AsrService.to;
    if (!service.modelsReady) {
      return {'pass': false, 'reason': 'models missing'};
    }
    final isFile = File(source).existsSync();
    final isBili =
        (Uri.tryParse(source)?.host ?? '').contains('bilivideo') ||
        (Uri.tryParse(source)?.host ?? '').contains('akamaized');
    final clock = Stopwatch()..start();
    // the viewer: at each seek point in turn, playing on from there
    var seekAt = seeks.first;
    final seekClock = Stopwatch()..start();
    final session = await service.start(
      key: 'selftest-seek',
      source: source,
      referer: isBili ? HttpString.baseUrl : null,
      userAgent: isFile ? null : BrowserUa.pc,
      playhead: () => seekAt + seekClock.elapsedMilliseconds / 1000,
    );
    bool covers(double from, double to) {
      final span = coveredSpanOf(session.transcript.covered, from);
      return span.from <= from && span.to >= to;
    }

    final rows = <Map<String, Object?>>[];
    for (final p in seeks) {
      seekAt = p;
      seekClock.reset();
      final runsBefore = session.runCount;
      final coveredBefore = covers(p, p + window);
      final deadline = DateTime.now().add(const Duration(minutes: 20));
      while (!covers(p, p + window) &&
          session.state.value.stage != AsrStage.failed &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      rows.add({
        'seek': p,
        'coveredAlready': coveredBefore,
        'msToCover': covers(p, p + window)
            ? seekClock.elapsedMilliseconds
            : null,
        'sinceStartMs': clock.elapsedMilliseconds,
        'runsBefore': runsBefore,
        'runsAfter': session.runCount,
        'stage': session.state.value.stage.name,
      });
      // a little viewing before the next jump
      await Future.delayed(Duration(seconds: dwell));
      rows.last['runsAfterDwell'] = session.runCount;
    }
    final covered = [
      for (final s in session.transcript.covered) [s.from, s.to],
    ];
    final pace = session.pace;
    await service.stop(only: session);
    return {
      'pass': rows.every((r) => r['msToCover'] != null),
      'speed': pace.speed,
      'restartCost': pace.restartCost,
      'seams': session.debugSeams,
      'source': source,
      'window': window,
      'rows': rows,
      'covered': covered,
    };
  }

  /// Chunked transcription, V3
  /// (research/chunked-transcription-design-2026-09-25.md): seams against a
  /// transcription from 0.
  ///
  /// First the whole media from 0, never pausing: the baseline. Then a
  /// session whose viewer lands at each of [at] in turn — each moved to the
  /// middle of the baseline cue nearest it, so the jump lands mid-speech —
  /// and jumps on once [lead] seconds past it are known. On a desktop that
  /// session then runs forward to the end and fills the gaps, so every kind
  /// of seam appears: a start mid-speech, a start exactly where known text
  /// ends, and joins into known text. Both transcripts, cue by cue with
  /// their times, and what each seam did go to [out] for comparison.
  static Future<Map<String, dynamic>> _asrSeamProbe(
    String source, {
    required List<double> at,
    required double lead,
    String? out,
  }) async {
    final service = AsrService.to;
    if (!service.modelsReady) {
      return {'pass': false, 'reason': 'models missing'};
    }
    final isFile = File(source).existsSync();
    Future<AsrSession> open(String key, double Function() playhead) =>
        service.start(
          key: key,
          source: source,
          referer: _isBiliUrl(source) ? HttpString.baseUrl : null,
          userAgent: isFile ? null : BrowserUa.pc,
          power: AsrPower.unlimited,
          playhead: playhead,
        );
    Future<void> settle(AsrSession session) async {
      final deadline = DateTime.now().add(const Duration(minutes: 30));
      while (session.state.value.stage != AsrStage.done &&
          session.state.value.stage != AsrStage.failed &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }

    List<Map<String, Object?>> dump(List<AsrCue> cues) => [
      for (final c in cues) {'from': c.from, 'to': c.to, 'text': c.content},
    ];

    final baseClock = Stopwatch()..start();
    final base = await open('selftest-seam-base', () => 0);
    await settle(base);
    final baseCues = base.cues.toList();
    final baseStage = base.state.value.stage.name;
    await service.stop(only: base);
    final baseMs = baseClock.elapsedMilliseconds;

    // each point moved into the cue nearest it
    final points = [
      for (final t in at)
        if (baseCues.isNotEmpty)
          () {
            final cue = baseCues.reduce(
              (a, b) =>
                  ((a.from + a.to) / 2 - t).abs() <=
                      ((b.from + b.to) / 2 - t).abs()
                  ? a
                  : b,
            );
            return (cue.from + cue.to) / 2;
          }(),
    ];
    if (points.isEmpty) {
      return {'pass': false, 'reason': 'baseline has no cues'};
    }
    var viewer = points.first;
    final viewClock = Stopwatch()..start();
    final clock = Stopwatch()..start();
    final session = await open(
      'selftest-seam',
      () => viewer + viewClock.elapsedMilliseconds / 1000,
    );
    final jumps = <Map<String, Object?>>[];
    for (var i = 0; i < points.length; i++) {
      viewer = points[i];
      viewClock.reset();
      jumps.add({'to': viewer, 'atMs': clock.elapsedMilliseconds});
      if (i == points.length - 1) break;
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (DateTime.now().isBefore(deadline)) {
        final span = coveredSpanOf(session.transcript.covered, viewer);
        if (span.from <= viewer && span.to >= viewer + lead) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    await settle(session);
    final cues = session.cues.toList();
    final result = {
      'pass':
          baseStage == 'done' &&
          session.state.value.stage == AsrStage.done &&
          cues.isNotEmpty,
      'source': source,
      'baseStage': baseStage,
      'baseMs': baseMs,
      'stage': session.state.value.stage.name,
      'ms': clock.elapsedMilliseconds,
      'runs': session.runCount,
      'language': session.state.value.language,
      'speed': session.pace.speed,
      'restartCost': session.pace.restartCost,
      'jumps': jumps,
      'seams': session.debugSeams,
      'covered': [
        for (final s in session.transcript.covered) [s.from, s.to],
      ],
      'baseCueCount': baseCues.length,
      'cueCount': cues.length,
    };
    await service.stop(only: session);
    if (out != null) {
      await File(out).writeAsString(
        jsonEncode({
          ...result,
          'baseCues': dump(baseCues),
          'cues': dump(cues),
        }),
      );
    }
    return result;
  }

  /// Chunked transcription, V0
  /// (research/chunked-transcription-design-2026-09-25.md): does stopping a
  /// transcription give back the recogniser's native memory?
  ///
  /// Each cycle goes through the app's own path — [AsrService.start], then
  /// [AsrService.stop] once the first segment is in, the way leaving a page
  /// does — and the process RSS is read [settleMs] after the stop. A stop
  /// that leaks shows as RSS climbing by about one recogniser per cycle; one
  /// that does not, as a flat line within noise.
  static Future<Map<String, dynamic>> _asrLeak(
    String source, {
    required int cycles,
    required int settleMs,
  }) async {
    final service = AsrService.to;
    if (!service.modelsReady) {
      return {
        'pass': false,
        'error': 'models missing under ${service.store.root.path}',
      };
    }
    int rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);
    final isBili =
        (Uri.tryParse(source)?.host ?? '').contains('bilivideo') ||
        (Uri.tryParse(source)?.host ?? '').contains('akamaized');
    final rows = <Map<String, Object?>>[];
    final baseline = rssMb();
    String? error;
    for (var i = 0; i < cycles; i++) {
      final clock = Stopwatch()..start();
      final session = await service.start(
        key: 'selftest-leak',
        source: source,
        referer: isBili ? HttpString.baseUrl : null,
        userAgent: BrowserUa.pc,
      );
      // stop mid-run, as a page does: the recogniser is loaded and busy
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (session.segments.isEmpty &&
          session.state.value.stage != AsrStage.failed &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      final firstSegmentMs = clock.elapsedMilliseconds;
      final segments = session.segments.length;
      final stage = session.state.value.stage.name;
      final running = rssMb();
      final transcriber = session.debugTranscriber;
      final stopClock = Stopwatch()..start();
      int? exitMs;
      unawaited(
        transcriber?.exited.then((_) => exitMs = stopClock.elapsedMilliseconds),
      );
      await service.stop(only: session);
      final stopMs = stopClock.elapsedMilliseconds;
      await Future.delayed(Duration(milliseconds: settleMs));
      rows.add({
        // how long the caller was held, and how long the isolate took to go
        'stopMs': stopMs,
        'exitMs': exitMs,
        'killed': transcriber?.killed,
        'cycle': i,
        'firstSegmentMs': firstSegmentMs,
        'segments': segments,
        'stageAtStop': stage,
        'rssRunningMb': running,
        'rssAfterStopMb': rssMb(),
      });
      if (segments == 0) {
        error = 'cycle $i produced no segment (stage $stage)';
        break;
      }
    }
    // anything freed late shows up here rather than in the last row
    await Future.delayed(const Duration(seconds: 10));
    final after = [for (final r in rows) r['rssAfterStopMb'] as int];
    return {
      'pass': error == null,
      'error': ?error,
      'source': source,
      'cycles': rows.length,
      'settleMs': settleMs,
      'rssBaselineMb': baseline,
      'rssAfterStopSeriesMb': after,
      'rssFinalMb': rssMb(),
      // first stop to last: one-off growth (models mapped once, caches
      // warmed) is in the first row, a per-stop leak is in the slope
      'mbPerCycle': after.length < 2
          ? null
          : (after.last - after.first) / (after.length - 1),
      'rows': rows,
    };
  }

  static Future<Map<String, dynamic>> _asr(
    String source, {
    String? modelDir,
    String? srtOut,
    String? pcmOut,
    String? forceLanguage,
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
    // bilibili's CDN refuses a request with no Referer; YouTube's does not
    // need one, and sending it bilibili's would tell Google where the
    // request came from for no benefit.
    final isBili =
        !(Uri.tryParse(source)?.host.contains('googlevideo') ?? false);
    final audio = await AsrAudioExtractor.extract(
      source: source,
      output: pcm,
      referer: isBili ? HttpString.baseUrl : null,
      userAgent: BrowserUa.pc,
    );
    final extractMs = DateTime.now().difference(extractStarted).inMilliseconds;

    final transcribeStarted = DateTime.now();
    final cues = <AsrCue>[];
    String? language;
    // the whole sequence, not the first: the language is now decided by a
    // running vote and corrects itself after a noisy opening, which a
    // first-wins capture cannot see
    final languageEvents = <String>[];
    // what the VAD called speech, so an uncovered stretch can be told apart
    // from a silent one
    final segments = <({double start, double duration})>[];
    // what the recogniser actually emits, which decides where a cue may end
    final rawTokens = <String>[];
    // every segment with its full token list, so the boundaries between
    // them can be judged: is a VAD cut a sentence end, a breath, or the 20 s
    // hard cap? That decides what unit a translator should be handed.
    final segmentDump = <Map<String, Object?>>[];
    String? error;
    final vote = AsrLanguageVote();
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
      // empty lets the recogniser decide; a value forces it, which is how
      // to tell "the model cannot do this language" from "the model picked
      // the wrong one"
      language: forceLanguage ?? '',
      // the probe extracts first and transcribes after, so the file is
      // complete before this starts: measuring the recogniser, not the
      // download it now runs alongside
      follow: false,
      japaneseSegmenter: await loadJapaneseSegmenter(),
      chineseSegmenter: await loadChineseSegmenter(),
      // `--asr-itn 0` turns it off, to see which recogniser artefacts it causes
      itn: _itn,
    ));
    await for (final event in transcriber.events) {
      switch (event) {
        case AsrCuesEvent(cues: final batch):
          cues.addAll(batch);
        case AsrSegmentEvent(
          :final start,
          :final duration,
          :final tokens,
          :final times,
          language: final tagged,
          :final weight,
          :final hidden,
        ):
          // the vote a session keeps (see AsrLanguageVote)
          if (vote.add(tagged, weight) case final lang?) {
            language = lang;
            if (languageEvents.isEmpty || languageEvents.last != lang) {
              languageEvents.add(lang);
            }
          }
          segments.add((start: start, duration: duration));
          if (rawTokens.length < 60) rawTokens.addAll(tokens);
          segmentDump.add({
            'start': start,
            'duration': duration,
            // SenseVoice's own tag for this segment, before the vote
            'lang': tagged,
            // not shown, and why (AsrSegmentFilter); its 'lang' is then
            // empty, withheld from the vote like its text from the screen
            'hidden': ?hidden?.name,
            'text': tokens.join(),
            'tokens': tokens,
            'times': times,
          });
        case AsrErrorEvent(message: final message):
          error = message;
        case AsrProgressUpdate() || AsrRunEndEvent() || AsrTagEvent():
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

    final shown = cues.displayed;
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
      'languageEvents': languageEvents,
      // echoed so "the flag never arrived" and "the model ignored it" are
      // not the same observation
      'forcedLanguage': forceLanguage ?? '(auto)',
      // Measured as SHOWN, not as built. The two differ — gaps are closed
      // when the track is serialised — and measuring the wrong one is how a
      // real defect stayed invisible for three rounds: every cue duration in
      // the file was fine while the player was reloading the track every
      // five seconds and blinking the line off screen.
      'rawTokens': rawTokens.take(60).toList(),
      'segments': segmentDump,
      'cueCount': shown.length,
      'builtCueCount': cues.length,
      'cueStats': _cueStats(shown, audio.durationSeconds),
      'script': _scriptMix(shown),
      'coverageVsVad': _coverageVsVad(shown, segments, audio.durationSeconds),
      // every cue as built, before layout: what translation units are made
      // of, for replaying the translation layout on real speech
      'builtCues': [
        for (final cue in cues)
          {'from': cue.from, 'to': cue.to, 'content': cue.content},
      ],
      'cues': [
        for (final cue in shown.take(40))
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
  /// Chunked transcription P4 on a real page (research/chunked-
  /// transcription-design-2026-09-25.md, 13): a local [file] played with its
  /// transcript under the battery rule, a seek that leaves a gap, the menu's
  /// status read along the way, and 保存字幕 driven through the settings
  /// sheet — cancelled once, then sent to the background and left to finish.
  /// Saves go to [dir] instead of the save dialog.
  static Future<Map<String, dynamic>> _asrExportProbe(
    String file, {
    required String dir,
  }) async {
    if (!AsrService.to.modelsReady) {
      return {'pass': false, 'reason': 'models missing'};
    }
    Directory(dir).createSync(recursive: true);
    final written = <String, int>{};
    final wrote = Completer<String>();
    VideoDetailController.debugSaveTo = (name, bytes) async {
      final out = path.join(dir, name);
      await File(out).writeAsBytes(bytes);
      written[out] = bytes.length;
      if (!wrote.isCompleted) wrote.complete(out);
    };
    const heroTag = 'selftest_asr_export';
    final clock = Stopwatch()..start();
    final seen = <Map<String, Object?>>[];
    final steps = <String, Object?>{};
    try {
      unawaited(LocalPlayer.open(file, heroTag: heroTag));
      await Future.delayed(const Duration(seconds: 6));
      final ctr = Get.find<VideoDetailController>(tag: heroTag)
        ..autoPlay = true;
      await ctr.playerInit(autoplay: true);
      final player = ctr.plPlayerController;
      await ctr.showTranscript();
      AsrSession? session;
      for (var i = 0; i < 100 && session == null; i++) {
        session = ctr.asrSession.value;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (session == null) return {'pass': false, 'reason': 'no session'};
      // a desktop never pauses: the phone's battery rule, so that there is
      // a lead to pause at and a gap for the save to fill
      session
        ..power = AsrPower.battery
        ..debugPowerFixed = true;

      void note(String at) {
        final label = ctr.menuStatus('asr')?.text;
        if (seen.isEmpty || seen.last['label'] != label) {
          seen.add({
            'at': at,
            'ms': clock.elapsedMilliseconds,
            'playhead': player.position.value,
            'label': label,
            'stage': session!.state.value.stage.name,
            'covered': [
              for (final s in session.transcript.covered)
                '${s.from.toStringAsFixed(1)}-${s.to.toStringAsFixed(1)}',
            ],
          });
        }
      }

      /// The menu, opened the way a viewer opens it: the transcript's row.
      Future<String?> menuLabel() async {
        player.showControls.value = true;
        await Future.delayed(const Duration(milliseconds: 700));
        if (!await _tapTooltip('字幕')) return null;
        final prefix = onDeviceLabel(null);
        final element = _findElement(
          (e) =>
              e.widget is Text && _textOf(e.widget as Text).startsWith(prefix),
        );
        final text = element == null ? null : _textOf(element.widget as Text);
        Get.back();
        await Future.delayed(const Duration(milliseconds: 500));
        return text;
      }

      // 1. running from 0 until paused ahead of the viewer
      for (
        var i = 0;
        i < 120 && session.state.value.stage != AsrStage.standby;
        i++
      ) {
        note('first run');
        await Future.delayed(const Duration(milliseconds: 500));
      }
      note('paused');
      steps['menuWhilePaused'] = await menuLabel();
      final duration = session.duration ?? player.duration.value.toDouble();
      steps['duration'] = duration;

      // 2. a seek well past what is known: a second stretch, a gap between
      final seekTo = (duration * 0.85).floorToDouble();
      await player.seekTo(Duration(seconds: seekTo.toInt()), isSeek: false);
      final runs = session.runCount;
      for (var i = 0; i < 120; i++) {
        note('after seek');
        if (session.runCount > runs &&
            session.state.value.stage == AsrStage.standby) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      note('after seek, settled');
      steps['menuWithGap'] = await menuLabel();
      steps['coveredBeforeSave'] = [
        for (final s in session.transcript.covered) [s.from, s.to],
      ];

      /// 保存字幕 through the settings sheet, else straight to the
      /// controller (the sheet is a lazy list: the row may not be built).
      Future<String> startSave() async {
        player.showControls.value = true;
        await Future.delayed(const Duration(milliseconds: 700));
        if (await _tapTooltip('更多设置') && await _tapText('保存字幕')) {
          final prefix = onDeviceLabel(null);
          if (await _tap(
            (e) =>
                e.widget is Text &&
                _textOf(e.widget as Text).startsWith(prefix),
          )) {
            return 'ui';
          }
          Get.back();
        }
        final index = ctr.subtitles.indexWhere((s) => s.lan == 'asr');
        ctr.saveOnDeviceSubtitle(index, SubtitleFormat.vtt, name: 'p4.vtt');
        await Future.delayed(const Duration(milliseconds: 600));
        return 'controller';
      }

      String? dialogTitle() => switch (_findElement(
        (e) =>
            e.widget is Text && _textOf(e.widget as Text).startsWith('正在补全字幕'),
      )) {
        final e? => _textOf(e.widget as Text),
        null => null,
      };

      // 3. 取消: nothing saved, the lead rule back
      steps['saveVia'] = await startSave();
      steps['dialogAtCancel'] = dialogTitle();
      steps['fullWhileDialog'] = session.fullCoverageRequested;
      steps['cancelTapped'] = await _tapText('取消');
      steps['fullAfterCancel'] = session.fullCoverageRequested;
      steps['dialogAfterCancel'] = dialogTitle();
      await Future.delayed(const Duration(seconds: 2));
      steps['writtenAfterCancel'] = written.length;
      note('after cancel');

      // 4. again, 放到后台继续, and left to finish
      steps['saveVia2'] = await startSave();
      steps['dialogAtBackground'] = dialogTitle();
      steps['backgroundTapped'] = await _tapText('放到后台继续');
      steps['dialogAfterBackground'] = dialogTitle();
      steps['fullInBackground'] = session.fullCoverageRequested;
      final started = clock.elapsedMilliseconds;
      String? out;
      while (clock.elapsedMilliseconds - started < 180000 && out == null) {
        note('background');
        if (wrote.isCompleted) out = await wrote.future;
        await Future.delayed(const Duration(milliseconds: 250));
      }
      steps['savedAfterMs'] = out == null
          ? null
          : clock.elapsedMilliseconds - started;
      steps['toastSeen'] = _seesText('字幕已补全并保存');
      await Future.delayed(const Duration(seconds: 1));
      note('saved');
      steps['menuWhenWhole'] = await menuLabel();
      steps['fullAfterSave'] = session.fullCoverageRequested;
      final cues = out == null
          ? 0
          : RegExp('-->').allMatches(File(out).readAsStringSync()).length;
      steps['savedFile'] = out;
      steps['savedCues'] = cues;
      steps['sessionCues'] = session.cues.length;
      steps['runs'] = session.runCount;
      final pass =
          out != null &&
          written.length == 1 &&
          steps['writtenAfterCancel'] == 0 &&
          steps['fullAfterCancel'] == false &&
          steps['fullAfterSave'] == false &&
          session.state.value.stage == AsrStage.done &&
          cues > 0;
      Get.back();
      await Future.delayed(const Duration(seconds: 2));
      return {'pass': pass, 'steps': steps, 'labels': seen};
    } finally {
      VideoDetailController.debugSaveTo = null;
    }
  }

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

  /// `--local-feed-probe MID`: the 本地 → 动态 page as the user meets it:
  /// MID followed locally (in the self-test profile only), the local page
  /// opened, and what its feed tab then shows — how many video cards, and
  /// whether it says fetching failed.
  static Future<Map<String, dynamic>> _localFeedProbe(int mid) async {
    await LocalLibrary.follow(mid);
    final clock = Stopwatch()..start();
    unawaited(Get.to(() => const Scaffold(body: LocalPage())));
    var cards = 0;
    var failedText = '';
    var emptyText = false;
    while (clock.elapsed < const Duration(seconds: 30)) {
      await Future.delayed(const Duration(milliseconds: 500));
      cards = 0;
      failedText = '';
      emptyText = false;
      void visit(Element e) {
        final w = e.widget;
        if (w is VideoCardH) cards++;
        if (w is Text) {
          final t = w.data ?? '';
          if (t.contains('获取失败')) failedText = t;
          if (t == '暂无投稿') emptyText = true;
        }
        e.visitChildren(visit);
      }

      void findFeed(Element e) {
        if (e.widget is LocalFeedTab) {
          e.visitChildren(visit);
          return;
        }
        e.visitChildren(findFeed);
      }

      WidgetsBinding.instance.rootElement?.visitChildren(findFeed);
      if (cards > 0 || failedText.isNotEmpty || emptyText) break;
    }
    final ms = clock.elapsedMilliseconds;
    Get.back();
    await LocalLibrary.unfollow(mid);
    return {
      'pass': cards > 0 && failedText.isEmpty,
      'mid': mid,
      'cards': cards,
      'ms': ms,
      'failed': failedText.isEmpty ? null : failedText,
      'empty': emptyText,
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

/// 调试模式's overlay as a probe sees it (`--debug-overlay`): its lines once
/// a second, a shot every few, and a line of its own counting up in place —
/// whether anything else reports progress during the run or not.
class _OverlayWatch {
  final _samples = <Map<String, Object?>>[];
  final _shots = <String?>[];
  Timer? _timer;
  var _ticks = 0;

  /// Keys whose line changed while it stayed one line.
  final _inPlace = <String>{};
  final _lastText = <String, String>{};
  var _maxLines = 0;
  var _mpvNonErrors = 0;
  var _eventLines = 0;

  void start() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    _ticks++;
    // the probe's own line: 0..100 over 20 s, in place; then left alone,
    // to go 15 s later
    if (_ticks <= 20) {
      final n = _ticks * 5;
      DebugOverlay.progress('selftest', 'selftest', () => 'overlay probe $n%');
    }
    // the bars shown before a shot: the lines move up above them
    if (_ticks == 11) PlPlayerController.instance?.controls = true;
    if (_ticks == 42) unawaited(_menu());
    final lines = DebugOverlay.model.lines;
    if (lines.length > _maxLines) _maxLines = lines.length;
    final byKey = <String, int>{};
    var events = 0;
    for (final line in lines) {
      final key = line.key;
      if (key == null) {
        events++;
        if (line.text.contains('[mpv]') &&
            !line.text.contains('[mpv] error') &&
            !line.text.contains('[mpv] fatal')) {
          _mpvNonErrors++;
        }
        continue;
      }
      byKey[key] = (byKey[key] ?? 0) + 1;
      final was = _lastText[key];
      if (was != null && was != line.text) _inPlace.add(key);
      _lastText[key] = line.text;
    }
    // a key on two lines at once would not be in place
    _inPlace.removeWhere((key) => (byKey[key] ?? 0) > 1);
    _eventLines = math.max(_eventLines, events);
    _samples.add({
      's': _ticks,
      'lines': [for (final line in lines) line.text],
    });
    if (_ticks % 4 == 0 && _ticks <= 40) {
      SelfTest._shot(
        'debug_overlay_${_ticks.toString().padLeft(2, '0')}',
      ).then(_shots.add);
    }
  }

  /// 调试模式 in the player's ⋮ menu: off and on again from there, at once.
  final _menuSteps = <String, Object?>{};
  Future<void> _menu() async {
    PlPlayerController.instance?.controls = true;
    await Future.delayed(const Duration(milliseconds: 500));
    _menuSteps['opened'] = await SelfTest._tapTooltip('更多设置');
    // near the end of a long list: scrolled to, as a viewer would
    // (a lazy list may not have built it yet: the list's end first)
    final tile = SelfTest._findElement(SelfTest._isText('调试模式'));
    _menuSteps['found'] = tile != null;
    if (tile != null) {
      final position = Scrollable.maybeOf(tile)?.position;
      if (position != null) {
        position.jumpTo(position.maxScrollExtent);
        _menuSteps['scrolledTo'] = position.pixels.round();
      }
      await Future.delayed(const Duration(milliseconds: 300));
      if (tile.mounted) await Scrollable.ensureVisible(tile, alignment: 0.5);
      await Future.delayed(const Duration(milliseconds: 700));
    }
    _menuSteps['shot'] = await SelfTest._shot(
      'debug_overlay_menu',
      whole: true,
    );
    _menuSteps['tappedOff'] = await SelfTest._tapText('调试模式');
    _menuSteps['offAfter'] = !DebugOverlay.on;
    _menuSteps['storedOff'] = !Pref.debugMode;
    _menuSteps['tappedOn'] = await SelfTest._tapText('调试模式');
    _menuSteps['onAfter'] = DebugOverlay.on;
    _menuSteps['shotOn'] = await SelfTest._shot(
      'debug_overlay_menu_on',
      whole: true,
    );
    Get.back();
  }

  Future<Map<String, dynamic>> finish() async {
    _timer?.cancel();
    final shot = await SelfTest._shot('debug_overlay_end', whole: true);
    return {
      'pass':
          _inPlace.contains('selftest') &&
          _eventLines > 0 &&
          _maxLines <= DebugOverlay.model.maxLines &&
          _mpvNonErrors == 0 &&
          _menuSteps['offAfter'] == true &&
          _menuSteps['onAfter'] == true,
      'menu': _menuSteps,
      'updatedInPlace': _inPlace.toList(),
      'mostEventLines': _eventLines,
      'mostLines': _maxLines,
      'mpvNonErrorLines': _mpvNonErrors,
      'shots': [..._shots, shot],
      'samples': _samples,
    };
  }
}

/// The loading gate of a page as a probe sees it: when it went up, when it
/// offered 先播放视频, and when it came down, in ms from [start] — with a
/// screenshot of the app when the skip appears (see SelfTest._shot).
class _GateWatch {
  _GateWatch(
    RxBool pending,
    RxBool skippable,
    this.start, {
    required String shot,
    this.pageOpenedAt,
    this.pageSkippableAt,
  }) {
    if (pending.value) openedMs = _ms();
    if (skippable.value) skippableMs = _ms();
    _workers = [
      ever<bool>(pending, (up) {
        if (up) {
          openedMs ??= _ms();
        } else if (openedMs != null) {
          closedMs ??= _ms();
        }
      }),
      ever<bool>(skippable, (can) {
        if (!can || skippableMs != null) return;
        skippableMs = _ms();
        SelfTest._shot(shot).then((path) => shotPath = path);
      }),
    ];
  }

  final DateTime start;

  /// The page's own record of when its gate went up and offered the skip:
  /// exact, where the watch may attach after the gate is already up.
  final DateTime? Function()? pageOpenedAt;
  final DateTime? Function()? pageSkippableAt;
  late final List<Worker> _workers;
  int? openedMs;
  int? skippableMs;
  int? closedMs;
  String? shotPath;

  int _ms() => DateTime.now().difference(start).inMilliseconds;

  void dispose() {
    for (final w in _workers) {
      w.dispose();
    }
  }

  Map<String, Object?> toJson() => {
    'openedMs': openedMs,
    'skippableMs': skippableMs,
    'closedMs': closedMs,
    // the wait before 先播放视频 was offered: 5 s by design
    'skipAfterMs': skippableMs == null || openedMs == null
        ? null
        : skippableMs! - openedMs!,
    'pageSkipAfterMs': switch ((
      pageOpenedAt?.call(),
      pageSkippableAt?.call(),
    )) {
      (final DateTime a, final DateTime b) => b.difference(a).inMilliseconds,
      _ => null,
    },
    'shot': shotPath,
  };
}
