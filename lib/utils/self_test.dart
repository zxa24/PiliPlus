import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart'
    show SubtitleType;
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/wbi_sign.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/member/contribute_type.dart';
import 'package:PiliPlus/models/common/subtitle_source.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/model_hot_video_item.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/member/search_archive/data.dart';
import 'package:PiliPlus/models_new/space/space_archive/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart'
    as bili_sub;
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
import 'package:PiliPlus/models/common/setting_type.dart';
import 'package:PiliPlus/services/platform_service.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_download.dart';
import 'package:PiliPlus/services/asr/audio_extract.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/services/asr/transcriber.dart';
import 'package:media_kit/media_kit.dart';
import 'package:PiliPlus/utils/font_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/models/common/asr_mode.dart';
import 'package:PiliPlus/models/common/translate_mode.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:PiliPlus/services/translate/translation_languages.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/settings_import.dart';
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
import 'package:flutter/services.dart'
    show
        KeyDownEvent,
        KeyMessage,
        KeyUpEvent,
        LogicalKeyboardKey,
        PhysicalKeyboardKey,
        ServicesBinding;
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart'
    show SmartDialog;
import 'package:material_ui/material_ui.dart'
    show AlertDialog, IconButton, PopupMenuButton, Tooltip, showDialog;
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:PiliPlus/common/widgets/scale_app.dart';
import 'package:window_manager/window_manager.dart';
import 'package:PiliPlus/utils/app_exit.dart';
import 'package:PiliPlus/services/translate/llama_engine.dart';
import 'package:PiliPlus/services/translate/translation_layout.dart';
import 'package:PiliPlus/services/translate/translation_models.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_track.dart';
import 'package:PiliPlus/services/translate/translation_engine.dart';

/// Command-line self test (LibrePili), for scripted checks of a real build:
///
///   LibrePili.exe --selftest [--download BVxxx] [--qn 80] [--local]
///                 [--keep] [--out result.json]
///
/// Runs after the app has started normally, writes a JSON report and exits
/// with 0 when every check passed, 1 otherwise.
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

  /// Inverse text normalisation for probe runs; see [AsrJob.itn].
  static bool _itn = true;

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
      await windowManager.setSize(Size(width, before.height));
      await Future.delayed(hold);
      // what the app actually laid out at, so a resize that silently did
      // nothing cannot read as "no overflow at phone width"
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      narrowLogicalWidth = view.physicalSize.width / view.devicePixelRatio;
      return uiErrors.sublist(seen).toList();
    } finally {
      uiErrors.removeRange(seen, uiErrors.length);
      await windowManager.setSize(before);
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
    if (_arg(args, '--translate-page') case final video?) {
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
    if (_arg(args, '--caption-compare') case final video?) {
      await scenario('captionCompare', () => _captionCompare(video));
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
        if (autoplay) SettingBoxKey.autoPlayEnable: true,
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
    if (args.contains('--settings-reachable')) {
      await scenario('settingsReachable', _settingsReachable);
    }
    if (args.contains('--metrics')) {
      await scenario('metrics', _uiMetrics);
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
    if (_arg(args, '--asr-start-probe') case final source?) {
      await scenario(
        'asrStartProbe',
        () => _asrStartProbe(
          source,
          at: [
            for (final a in (_arg(args, '--at') ?? '0,120,300').split(','))
              double.parse(a),
          ],
          window: double.tryParse(_arg(args, '--window') ?? '') ?? 40,
          dir: _arg(args, '--dir') ?? path.join(tmpDirPath, 'asr_probe'),
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

    report
      ..['pass'] = ok
      ..['finishedAt'] = DateTime.now().toIso8601String();
    await File(out).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    appExit(ok ? 0 : 1);
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
      'translatedUnits': current?.results.values.where((t) => t != null).length,
      'failedUnits': current?.results.values.where((t) => t == null).length,
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
    await _setAutoTranslation(auto);
    final videoId = tryParseYouTubeVideoId(input) ?? input;
    final started = DateTime.now();
    unawaited(Get.toNamed('/ytVideo', parameters: {'id': videoId}));
    await Future.delayed(const Duration(seconds: 2));
    final controller = Get.find<YtVideoController>(tag: videoId);
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
    if (!auto) await controller.showTranslation(language);
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
    final session = controller.translation.session.value;
    final translated = session?.results.values.whereType<String>().toList();
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
    await _setAutoTranslation(auto);
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
    // the menu's path: picking the language shows it, making it first
    if (!auto) await page.showTranslation(language);

    int? translatedTrackMs;
    int? selectedMs;
    for (var i = 0; i < holdSeconds; i++) {
      await Future.delayed(const Duration(seconds: 1));
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
    final session = page.translation.session.value;
    final translated = session?.results.values.whereType<String>().toList();
    final result = {
      'pass':
          translatedTrackMs != null &&
          selectedMs != null &&
          (translated?.isNotEmpty ?? false),
      'mode': auto ? 'auto' : 'menu',
      'local': local,
      'videoOwnSubtitles': ownSubtitles,
      // the video's own subtitles when foreign ones exist, else a transcript
      'translated': page.asrSession.value == null ? 'captions' : 'transcript',
      'asrLanguage': page.asrSession.value?.state.value.language,
      'asrStage': page.asrSession.value?.state.value.stage.name,
      'translationStage': session?.state.value.stage.name,
      'gateOpenedMs': gateOpenedMs,
      'gateClosedMs': gateClosedMs,
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
      'sample': translated?.take(4).toList(),
    };
    await page.stopAsr();
    Get.back();
    return result;
  }

  /// Automatic transcription and translation on or off, in the self-test
  /// profile's own settings (the profile has its own storage; the user's
  /// are not touched). Always set, both ways: the profile keeps them, and a
  /// menu run after an automatic one was found starting by itself.
  static Future<void> _setAutoTranslation(bool on) => GStorage.setting.putAll({
    SettingBoxKey.asrAsked: true,
    SettingBoxKey.asrMode: (on ? AsrMode.foreign : AsrMode.manual).index,
    SettingBoxKey.translateAsked: true,
    SettingBoxKey.translateMode:
        (on ? TranslateMode.auto : TranslateMode.manual).index,
  });

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

  /// `--focus-probe`: see [_focusProbe]; also presses keys (see
  /// [_keyProbe]).
  static bool debugFocusProbe = false;

  /// Presses [logical] the way a keyboard does: the key message goes to the
  /// focus system (the handler the engine calls), from the focused node up.
  static Future<void> _press(
    LogicalKeyboardKey logical,
    PhysicalKeyboardKey physical,
  ) async {
    final handler = ServicesBinding.instance.keyEventManager.keyMessageHandler;
    if (handler == null) return;
    final at = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);
    handler(
      KeyMessage([
        KeyDownEvent(physicalKey: physical, logicalKey: logical, timeStamp: at),
      ], null),
    );
    await Future.delayed(const Duration(milliseconds: 80));
    handler(
      KeyMessage([
        KeyUpEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: at + const Duration(milliseconds: 80),
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
    return {
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
    final keys = debugFocusProbe ? await _keyProbe(player) : null;

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
      'captionShown': captionOk,
      'via': controller.streams?.sourceId,
      'stoppedOnLeave': stopped,
      'positionAfterBack': afterBack?.inMilliseconds,
      'positionAfterBack2': afterBack2?.inMilliseconds,
      'keys': ?keys,
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
  static Future<Map<String, dynamic>> _asrDownload(String dir) async {
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
        ):
          segments.add((start: start, duration: duration));
          if (rawTokens.length < 60) rawTokens.addAll(tokens);
          segmentDump.add({
            'start': start,
            'duration': duration,
            'text': tokens.join(),
            'tokens': tokens,
            'times': times,
          });
        case AsrLanguageEvent(language: final lang):
          language = lang;
          if (languageEvents.isEmpty || languageEvents.last != lang) {
            languageEvents.add(lang);
          }
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
