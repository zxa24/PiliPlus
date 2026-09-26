/// LibrePili: the command-line reader ([CtlServer]) wired to the app — the
/// setting that starts and stops it, and what its endpoints read.
///
/// The video pages are found from the route stack ([Ctl.routes]) and the
/// controllers GetX already keeps under each page's tag, so no page has to
/// register itself.
library;

import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/pages/video/widgets/on_device_menu.dart';
import 'package:PiliPlus/pages/video/widgets/translate_entry.dart';
import 'package:PiliPlus/pages/youtube/video/controller.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/ctl/ctl_server.dart';
import 'package:PiliPlus/services/ctl/ctl_state.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/translate/comment_translator.dart';
import 'package:PiliPlus/services/translate/translation_languages.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/translate/translation_track.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

/// Keeps the root navigator's routes, bottom first, for `/status`.
class CtlRouteObserver extends NavigatorObserver {
  final stack = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : stack.indexOf(oldRoute);
    if (newRoute == null) {
      if (i >= 0) stack.removeAt(i);
    } else if (i >= 0) {
      stack[i] = newRoute;
    } else {
      stack.add(newRoute);
    }
  }
}

abstract final class Ctl {
  static final routes = CtlRouteObserver();

  static CtlServer? _server;
  static CtlServer? get server => _server;

  /// Starts and stops one after another: a switch flicked twice quickly
  /// must not leave two servers, or none with the setting on.
  static Future<void> _queue = Future.value();

  /// Serves while [on]; with it off, also removes a `ctl.json` a crashed
  /// run left behind.
  static Future<void> apply(bool on) =>
      _queue = _queue.then((_) => _apply(on)).catchError((Object e) {
        EventLog.add('ctl', 'command-line reader: $e');
      });

  static Future<String?> _mirrorDir() async {
    // the app-specific external folder, which `adb shell` reads on a build
    // `run-as` refuses; only where no other app can read it (scoped storage)
    if (!Platform.isAndroid || DeviceUtils.sdkInt < 30) return null;
    try {
      return (await getExternalStorageDirectory())?.path;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _apply(bool on) async {
    if (!on) {
      final server = _server;
      _server = null;
      await server?.stop();
      CtlServer.removeStale(appSupportDirPath, mirrorDir: await _mirrorDir());
      if (server != null) EventLog.add('ctl', 'command-line reader stopped');
      return;
    }
    if (_server != null) return;
    final server = CtlServer(
      dir: appSupportDirPath,
      mirrorDir: await _mirrorDir(),
      identity: identity,
      endpoints: {
        '/status': (_) => status(),
        '/log': log,
        '/settings': (_) => ctlSettingsJson(GStorage.setting.get),
      },
    );
    await server.start();
    _server = server;
    // the port, never the token
    EventLog.add('ctl', 'command-line reader on 127.0.0.1:${server.port}');
  }

  static Map<String, Object?> get identity => {
    'app': 'LibrePili',
    'version': BuildConfig.versionName,
    'build': BuildConfig.versionCode,
    'profile': isSelfTestProfile ? selfTestProfileDir : null,
  };

  static Object? log(Uri uri) {
    final since = DateTime.tryParse(uri.queryParameters['since'] ?? '');
    final limit = int.tryParse(uri.queryParameters['limit'] ?? '');
    var entries = EventLog.entries(since: since);
    if (limit != null && limit >= 0 && entries.length > limit) {
      entries = entries.sublist(entries.length - limit);
    }
    return {
      'now': DateTime.now().toIso8601String(),
      'count': entries.length,
      'lines': [
        for (final (at, line) in entries)
          {'at': at.toIso8601String(), 'line': line},
      ],
    };
  }

  static T? _try<T>(T Function() read) {
    try {
      return read();
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?> status() {
    final stack = routes.stack.reversed.toList();
    final pages = <Map<String, Object?>>[];
    for (final route in stack) {
      final page = _try(() => _pageOf(route));
      if (page != null) pages.add({'onTop': pages.isEmpty, ...page});
    }
    final player = PlPlayerController.instance;
    return {
      'app': {
        ...identity,
        'commit': BuildConfig.commitHash,
        'buildTime': BuildConfig.buildTime == 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                BuildConfig.buildTime * 1000,
              ).toIso8601String(),
        'pid': pid,
        'platform': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'now': DateTime.now().toIso8601String(),
      },
      // top first
      'routes': [
        for (final route in stack)
          route.settings.name ?? route.runtimeType.toString(),
      ],
      // the video pages in the stack, top first; the one on top has the
      // player
      'pages': pages,
      'player': player == null
          ? null
          : {
              'status': player.playerStatus.value.name,
              'buffering': player.isBuffering.value,
              'position': player.position.value,
              'duration': player.duration.value,
              'buffered': player.buffered.value,
            },
      'commentTranslation': [
        for (final t in CommentTranslator.live) _commentsJson(t),
      ],
      'models': {
        'asr': _try(
          () => {
            'ready': AsrService.to.modelsReady,
            'models': {
              for (final m in AsrModelCatalog.required)
                m.id: AsrService.to.store.isInstalled(m),
            },
          },
        ),
        'translation': _try(
          () => {
            'supported': TranslationService.supported,
            'model': TranslationService.to.model.id,
            'ready': TranslationService.to.modelReady,
          },
        ),
      },
    };
  }

  static Map<String, Object?> _commentsJson(CommentTranslator t) => {
    'key': t.key,
    'enabled': t.enabled.value,
    'done': t.done.value,
    'total': t.total.value,
  };

  static Map<String, Object?>? _pageOf(Route<dynamic> route) {
    final name = route.settings.name ?? '';
    final args = route.settings.arguments;
    if (name.startsWith('/videoV')) {
      final tag = args is Map ? args['heroTag'] as String? : null;
      if (!Get.isRegistered<VideoDetailController>(tag: tag)) return null;
      return _biliPage(Get.find<VideoDetailController>(tag: tag));
    }
    if (name.startsWith('/ytVideo')) {
      final id =
          Uri.tryParse(name)?.queryParameters['id'] ??
          (args is String ? args : null);
      if (id == null || !Get.isRegistered<YtVideoController>(tag: id)) {
        return null;
      }
      return _ytPage(Get.find<YtVideoController>(tag: id));
    }
    return null;
  }

  static Map<String, Object?> _biliPage(VideoDetailController c) {
    final local = c.isFileSource;
    final tag = c.heroTag;
    String? title = _try<String?>(() => local ? c.entry.showTitle : null);
    title ??= _try<String?>(
      () => Get.isRegistered<UgcIntroController>(tag: tag)
          ? Get.find<UgcIntroController>(tag: tag).videoDetail.value.title
          : null,
    );
    title ??= _try<String?>(() => c.args['title'] as String?);
    final comments = _try(
      () => Get.isRegistered<VideoReplyController>(tag: tag)
          ? CommentTranslator.find(
              Get.find<VideoReplyController>(tag: tag).translatorKey,
            )
          : null,
    );
    return {
      'platform': local ? 'local' : 'bilibili',
      'heroTag': tag,
      'videoType': _try(() => c.videoType.name),
      'bvid': _try(() => c.bvid),
      'aid': _try(() => c.aid),
      'cid': _try(() => c.cid.value),
      'epId': c.epId,
      'seasonId': c.seasonId,
      'title': title,
      'ready': c.videoState.value,
      'quality': c.currentVideoQa.value?.desc,
      'audioQuality': c.currentAudioQa?.desc,
      'codec': _try(() => c.currentDecodeFormats.name),
      'videoHost': ctlHostOf(c.videoUrl),
      'audioHost': ctlHostOf(c.audioUrl),
      'subtitles': {
        // 0 is 关闭字幕; track n is tracks[n-1]
        'selected': c.vttSubtitlesIndex.value,
        'tracks': [
          for (final (i, s) in c.subtitles.indexed)
            {
              'index': i + 1,
              'label': s.displayName,
              'lan': s.lan,
              'source': s.source.name,
            },
        ],
      },
      ..._onDevice(
        canTranscribe: c.canTranscribe,
        canTranslateCaptions: _try(() => c.captionToTranslate != null) ?? false,
        picked: c.onDevicePicked,
        shown: c.onDeviceShown,
        busy: c.onDeviceBusy,
        status: c.onDeviceStatus,
        track: c.translation,
        pending: c.asrPending.value,
        transcription: ctlAsrJson(c.asrSession.value),
      ),
      'fillExport': ctlFillExportJson(c.pendingFillExport),
      'comments': comments == null ? null : _commentsJson(comments),
    };
  }

  static Map<String, Object?> _ytPage(YtVideoController c) {
    final streams = c.streams;
    final detail = c.detail.value;
    final comments = CommentTranslator.find('yt:${c.videoId}');
    return {
      'platform': 'youtube',
      'videoId': c.videoId,
      'title': detail?.title,
      'author': detail?.author,
      'stage': c.stage.value.name,
      'message': c.message.value.isEmpty ? null : c.message.value,
      'quality': streams?.video?.qualityLabel,
      'codec': streams?.video?.codec,
      'audioCodec': streams?.audio?.codec,
      'maxHeight': c.maxHeight.value,
      'source': streams?.sourceId,
      'videoHost': ctlHostOf(streams?.videoUrl),
      'audioHost': ctlHostOf(streams?.audioUrl),
      'subtitles': {
        // -1 is 关闭字幕; otherwise an index into tracks
        'selected': c.captionIndex.value,
        'tracks': [
          for (final (i, t) in c.captions.indexed)
            {
              'index': i,
              'label': t.displayName,
              'lan': t.languageCode,
              'source': t.source.name,
            },
        ],
      },
      ..._onDevice(
        canTranscribe: c.canTranscribe,
        canTranslateCaptions: _try(() => c.captionToTranslate != null) ?? false,
        picked: c.onDevicePicked,
        shown: c.onDeviceShown,
        busy: c.onDeviceBusy,
        status: c.onDeviceStatus,
        track: c.translation,
        pending: c.asrPending.value,
        transcription: ctlAsrJson(c.asrSession.value),
      ),
      'comments': comments == null ? null : _commentsJson(comments),
    };
  }

  /// The on-device part both pages share, with the menu rows built the way
  /// the pages build them (lib/plugin/pl_player/view/view.dart and
  /// lib/pages/youtube/video/view.dart).
  static Map<String, Object?> _onDevice({
    required bool canTranscribe,
    required bool canTranslateCaptions,
    required String? picked,
    required String? shown,
    required bool busy,
    required String? Function(String code) status,
    required TranslationTrack track,
    required bool pending,
    required Map<String, Object?>? transcription,
  }) {
    final canTranslate =
        TranslateEntry.available && (canTranscribe || canTranslateCaptions);
    final current = track.session.value == null ? picked : track.into;
    return {
      'onDevice': {
        'shown': shown,
        'picked': picked,
        'busy': busy,
        'canTranscribe': canTranscribe,
        'canTranslate': canTranslate,
        'appLanguage': AsrService.appLanguage,
        // what the subtitle menu reads, row by row
        'menu': [
          for (final row in ctlMenuJson(
            codes: [
              if (canTranscribe) 'asr',
              if (canTranslate) ...OnDeviceMenu.listed(current),
            ],
            label: (code) => onDeviceLabel(code == 'asr' ? null : code),
            status: status,
            picked: picked,
          ))
            {
              ...row,
              'text': OnDeviceMenu.itemLabel(
                row['label'] as String,
                row['status'] as String?,
              ),
            },
        ],
      },
      // the page held in loading for the subtitles
      'asrPending': pending,
      'transcription': transcription,
      'translation': ctlTranslationJson(track),
    };
  }

  /// What `ctl.json` holds while serving (port, token…), for the self-test.
  static Map<String, Object?>? get servedFile => _server?.fileContents;
}
