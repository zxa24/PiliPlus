import 'dart:async' show unawaited;
import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/back_detector.dart';
import 'package:PiliPlus/common/widgets/custom_toast.dart';
import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/common/widgets/scale_app.dart';
import 'package:PiliPlus/common/widgets/scroll_behavior.dart';
import 'package:PiliPlus/http/app_proxy.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/theme/theme_color_type.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/router/app_pages.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_guard.dart';
import 'package:PiliPlus/services/ctl/ctl_app.dart';
import 'package:PiliPlus/services/debug_overlay.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/local_player.dart';
import 'package:PiliPlus/pages/setting/models/youtube_settings.dart';
import 'package:PiliPlus/services/parallel_fetch.dart';
import 'package:PiliPlus/services/platform_service.dart';
import 'package:PiliPlus/services/power_events.dart';
import 'package:PiliPlus/services/logger.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/services/youtube/stream_relay.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart' show AndroidHelper;
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/codec_support.dart';
import 'package:PiliPlus/utils/calc_window_position.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/extension/core_palettes_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/font_utils.dart';
import 'package:PiliPlus/utils/json_file_handler.dart';
import 'package:PiliPlus/utils/max_screen_size.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/request_utils.dart';
import 'package:PiliPlus/utils/self_test.dart';
import 'package:PiliPlus/utils/self_test_window.dart';
import 'package:PiliPlus/utils/cjk_autospace.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:PiliPlus/utils/update/update_apply.dart';
import 'package:canvas_danmaku/utils/utils.dart' as danmaku;
import 'package:catcher_2/catcher_2.dart';
import 'package:collection/collection.dart';
import 'package:dynamic_color/dynamic_color.dart' show DynamicColorPlugin;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:win32/win32.dart'
    as win32
    show MB_ICONERROR, MessageBox, StringExtension;
import 'package:window_manager/window_manager.dart' hide calcWindowPosition;
import 'package:PiliPlus/utils/app_exit.dart';

WebViewEnvironment? webViewEnvironment;

EdgeInsets? tmpPadding;

Future<void> _initDownPath() async {
  if (isSelfTestProfile) {
    downloadPath = defDownloadPath;
    return;
  }
  if (PlatformUtils.isDesktop) {
    final customDownPath = Pref.downloadPath;
    if (customDownPath != null && customDownPath.isNotEmpty) {
      try {
        final dir = Directory(customDownPath);
        if (!dir.existsSync()) {
          await dir.create(recursive: true);
        }
        downloadPath = customDownPath;
      } catch (e) {
        downloadPath = defDownloadPath;
        await GStorage.setting.delete(SettingBoxKey.downloadPath);
        if (kDebugMode) {
          debugPrint('download path error: $e');
        }
      }
    } else {
      downloadPath = defDownloadPath;
    }
  } else if (Platform.isAndroid) {
    final externalStorageDirPath = (await getExternalStorageDirectory())?.path;
    downloadPath = externalStorageDirPath != null
        ? path.join(externalStorageDirPath, PathUtils.downloadDir)
        : defDownloadPath;
  } else {
    downloadPath = defDownloadPath;
  }
}

Future<void> _initTmpPath() async {
  tmpDirPath = (await appTempDirectory()).path;
}

/// When this process started (set first thing in [main]): scratch files
/// older than this are a previous process's (see [clearScratchFiles]).
late final DateTime appStartedAt;

/// The scratch files of transcription runs (tmpDirPath/asr) and of YouTube
/// downloads (tmpDirPath/ytdl), each named after its video. A run or a
/// download deletes its own, but a process ended mid-way (the window
/// closed, Android stopping the app) leaves them behind. With [before],
/// only what was last changed before it: a run or download this process
/// has begun since keeps its files. A file still held open stays. Best
/// effort.
Future<void> clearScratchFiles({DateTime? before}) async {
  bool keep(FileSystemEntity e) =>
      before != null && e.statSync().modified.isAfter(before);
  for (final name in const ['asr', 'ytdl']) {
    final dir = Directory(path.join(tmpDirPath, name));
    try {
      if (!dir.existsSync()) continue;
      final dirs = <Directory>[];
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        try {
          if (e is Directory) {
            if (!keep(e)) dirs.add(e);
          } else if (!keep(e)) {
            await e.delete();
          }
        } catch (_) {}
      }
      // emptied folders, deepest first; one still holding a file stays
      for (final d in dirs.reversed) {
        try {
          await d.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}

Future<void> _initAppPath() async {
  var dir = (await getApplicationSupportDirectory()).path;
  if (isSelfTestProfile) {
    dir = path.join(dir, selfTestProfileDir);
    await Directory(dir).create(recursive: true);
  }
  appSupportDirPath = dir;
}

void main(List<String> args) async {
  appStartedAt = DateTime.now();
  ScaledWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  isSelfTestProfile = SelfTest.isRequested(args);
  if (isSelfTestProfile) selfTestProfileDir = SelfTest.profileDir(args);
  if (isSelfTestProfile) selfTestSound = args.contains('--sound');
  // a long-press release to try by ear, outside a self test too (user
  // 2026-10-01: listen to ao-reload): `--longpress-release aoreload`
  if (args.indexOf('--longpress-release') case final i
      when i >= 0 && i + 1 < args.length) {
    PlPlayerController.debugLongPressRelease = args[i + 1];
  }
  // before anything that can fail: `--out` is read from the args alone, and
  // a caller must not see "no report + exit 0" as a pass
  if (isSelfTestProfile) SelfTest.markStarted(args);
  await _initAppPath();
  try {
    await GStorage.init();
  } catch (e) {
    // shown, not put on the clipboard (which overwrote whatever the user
    // had there): most often a second copy started on the same profile
    final message = '无法打开数据目录（可能已有一个 LibrePili 在使用它）\n\n$e';
    stderr.writeln(message);
    if (Platform.isWindows && !isSelfTestProfile) {
      win32.MessageBox(
        null,
        message.toPcwstr(),
        'LibrePili'.toPcwstr(),
        win32.MB_ICONERROR,
      );
    }
    if (kDebugMode) debugPrint('GStorage init error: $e');
    if (isSelfTestProfile) SelfTest.abort(args, e);
    appExit();
  }
  // LibrePili: a downloaded, verified update put in place before the UI
  // (Windows, Linux; user 2026-10-20: "applied on the next launch"): the
  // helper started waits for this process to end, so it ends here. Past
  // GStorage.init, no other copy runs on this profile.
  if (await UpdateApply.applyBeforeUi()) {
    await GStorage.close();
    appExit();
  }
  ScaledWidgetsFlutterBinding.instance.scaleFactor = Pref.uiScale;
  // LibrePili: danmaku spaced as subtitles and comments are (中英文间距),
  // the setting read as each one is drawn
  danmaku.DmUtils.gapsOf = (text) =>
      Pref.cjkAutospace ? CjkAutospace.gaps(text) : const [];
  danmaku.DmUtils.gapEm = CjkAutospace.em;
  // LibrePili: downloads read through the player's parallel fetch (the
  // pieces kept on disk first)
  DownloadManager.fetch = PlPlayerController.fetchForDownload;
  // LibrePili: the region/language asked of YouTube, from settings
  applyYtLocale();
  await Future.wait([
    _initDownPath(),
    _initTmpPath(),
    CacheManager.ensureInitialized(),
    ?FontUtils.init(),
  ]);
  // LibrePili: the subtitle cache back within its limit (a limit lowered,
  // entries left by a run that ended mid-write); nothing waits on it
  unawaited(SubtitleCache.instance.evict());
  // LibrePili: transcription and YouTube download scratch a killed run left
  // (named after the video); only one process gets past GStorage.init on a
  // profile, and the temp folder is per profile
  unawaited(clearScratchFiles(before: appStartedAt));
  Get
    ..lazyPut(AccountService.new)
    ..lazyPut(DownloadService.new)
    ..lazyPut(AsrService.new)
    ..lazyPut(TranslationService.new)
    ..put(PlatformService());
  // LibrePili: the background transcription of finished downloads carries
  // on after a restart, and a transcript made while watching is written
  // beside the download, without waiting for a download page to create the
  // service (it reads the download list only: nothing is downloaded or
  // requested until a download page or action uses it)
  unawaited(Future(DownloadService.startInBackground));
  // stop on-device inference on memory pressure, or when the app is sent to
  // the background with nothing playing — before Android stops the app
  OnDeviceModelGuard.install();
  // which codec a stream is chosen in (see CodecSupport); nothing waits on it
  unawaited(CodecSupport.check());
  // the player lets go of its decoder before the computer sleeps
  PowerEvents.init();
  // the command-line reader (设置 → 其它设置 → 允许命令行读取状态); off, it
  // only clears a ctl.json a crashed run left
  unawaited(Ctl.apply(Pref.ctlServer));
  // 调试模式 (设置 → 其它设置): the player's overlay of decisions
  DebugOverlay.setEnabled(Pref.debugMode);
  HttpOverrides.global = _CustomHttpOverrides();
  // the 设置代理 setting for the parallel fetch's own client too (it sets
  // its findProxy itself)
  ParallelFetch.proxyFor = AppProxy.findProxy;
  // and for the relay of Invidious streams (and the YouTube downloader)
  YtStreamRelay.proxyFor = AppProxy.findProxy;

  if (PlatformUtils.isMobile) {
    if (Platform.isAndroid) {
      MaxScreenSize.init();
      // the documents provider as the setting says: PackageManager keeps the
      // component's state, and a reset or import (重启生效) changes the key
      // without touching it
      AndroidHelper.updateDocProvider(Pref.enableDocProvider);
    }
    await Future.wait([
      if (Pref.horizontalScreen) ?fullMode() else ?portraitUpMode(),
      setupServiceLocator(),
    ]);
    // the 设置代理 setting for the in-app web pages (user 2026-10-20), set
    // again on each change (extra_settings.dart)
    unawaited(AppProxy.applyToWebViews(start: true));
  } else if (Platform.isWindows) {
    if (await WebViewEnvironment.getAvailableVersion() != null) {
      webViewEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: path.join(appSupportDirPath, 'flutter_inappwebview'),
          // the 设置代理 setting for the in-app web pages (user 2026-10-20):
          // WebView2 reads it here only, so a change takes a restart
          additionalBrowserArguments: AppProxy.webView2ArgsFor(),
        ),
      );
    }
  } else if (Platform.isMacOS) {
    await setupServiceLocator();
  }

  Request();
  Request.setCookie();
  RequestUtils.syncHistoryStatus();

  SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);

  if (PlatformUtils.isMobile) {
    SystemChrome.setEnabledSystemUIMode(.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        statusBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
    );
    if (Platform.isAndroid) {
      FlutterDisplayMode.supported.then((mode) {
        final String? storageDisplay = GStorage.setting.get(
          SettingBoxKey.displayMode,
        );
        DisplayMode? displayMode;
        if (storageDisplay != null) {
          displayMode = mode.firstWhereOrNull(
            (e) => e.toString() == storageDisplay,
          );
        }
        FlutterDisplayMode.setPreferredMode(displayMode ?? DisplayMode.auto);
      });
    } else {
      ScreenBrightnessPlatform.instance.setAutoReset(false);
    }
  } else if (PlatformUtils.isDesktop) {
    FocusManager.instance.addEarlyKeyEventHandler(_onKeyEvent);

    await windowManager.ensureInitialized();

    final windowOptions = WindowOptions(
      minimumSize: const Size(400, 720),
      skipTaskbar: false,
      titleBarStyle: Pref.showWindowTitleBar
          ? TitleBarStyle.normal
          : TitleBarStyle.hidden,
      title: Constants.appName,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      // shown by the runner, at the bottom and not focused
      if (isSelfTestProfile && SelfTestWindow.quiet) return;
      final windowSize = Pref.windowSize;
      await windowManager.setBounds(
        await calcWindowPosition(windowSize) & windowSize,
      );
      if (Pref.isWindowMaximized) await windowManager.maximize();
      await windowManager.show();
      await windowManager.focus();
    });
  }

  if (Pref.dynamicColor) {
    await MyApp.initPlatformState();
  }

  if (Pref.enableLog) {
    // 异常捕获 logo记录
    final customParameters = {
      'Build Time': DateFormatUtils.format(
        BuildConfig.buildTime,
        format: DateFormatUtils.longFormatDs,
      ),
      'Commit Hash': BuildConfig.commitHash,
      'MPV Api Version':
          '${NativePlayer.apiVersion >> 16}.${NativePlayer.apiVersion & 0xFFFF}',
    };
    final fileHandler = await JsonFileHandler.init();

    Catcher2(
      [?fileHandler, const ConsoleHandler()],
      const MyApp(),
      logger: logger,
      customParameters: customParameters,
    );
  } else {
    runApp(const MyApp());
  }

  if (SelfTest.isRequested(args)) {
    SelfTest.schedule(args);
  } else if (args.where((a) => !a.startsWith('-')).firstOrNull
      case final target?) {
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      // LibrePili: launched with a video file / folder ("Open with")
      PiliScheme.launchFile = target;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => LocalPlayer.open(target),
      );
    } else if (target.contains('://') || target.contains('.')) {
      // LibrePili: launched with a link — bilibili or YouTube, the scheme
      // handler decides which page it belongs to
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => PiliScheme.routePushFromUrl(target),
      );
    }
  }
}

KeyEventResult _onKeyEvent(KeyEvent event) {
  if (event.logicalKey == .escape && event is KeyDownEvent) {
    _onBack();
    return .handled;
  }
  return .ignored;
}

void _onBack() {
  if (SmartDialog.checkExist()) {
    SmartDialog.dismiss();
    return;
  }

  final route = Get.routing.route;
  if (route is GetPageRoute) {
    if (route.popDisposition == .doNotPop) {
      route.onPopInvokedWithResult(false, null);
      return;
    }
  }

  final navigator = Get.key.currentState!;
  if (navigator.canPop()) {
    navigator.pop();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static ColorScheme? _light, _dark;

  static (ThemeData, ThemeData) getAllTheme() {
    final dynamicColor = _light != null && _dark != null && Pref.dynamicColor;
    late final brandColor = colorThemeTypes[Pref.customColor].color;
    late final variant = Pref.schemeVariant;
    return (
      ThemeUtils.lightTheme = ThemeUtils.getThemeData(
        colorScheme: dynamicColor
            ? _light!
            : brandColor.asColorSchemeSeed(variant, .light),
        isDynamic: dynamicColor,
      ),
      ThemeUtils.darkTheme = ThemeUtils.getThemeData(
        isDark: true,
        colorScheme: dynamicColor
            ? _dark!
            : brandColor.asColorSchemeSeed(variant, .dark),
        isDynamic: dynamicColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (light, dark) = getAllTheme();
    return GetMaterialApp(
      title: Constants.appName,
      theme: light,
      darkTheme: dark,
      themeMode: ThemeUtils.themeMode = Pref.themeMode,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      locale: const Locale("zh", "CN"),
      fallbackLocale: const Locale("zh", "CN"),
      supportedLocales: const [Locale("zh", "CN"), Locale("en", "US")],
      initialRoute: '/',
      getPages: Routes.getPages,
      defaultTransition: Pref.pageTransition,
      builder: FlutterSmartDialog.init(
        toastBuilder: CustomToast.new,
        loadingBuilder: LoadingWidget.new,
        notifyStyle: const FlutterSmartNotifyStyle(
          warningBuilder: NotifyWarning.new,
        ),
        builder: _builder,
      ),
      navigatorObservers: [
        routeObserver,
        Ctl.routes,
        FlutterSmartDialog.observer,
      ],
      scrollBehavior: PlatformUtils.isDesktop
          ? const CustomScrollBehavior()
          : null,
    );
  }

  static Widget _builder(BuildContext context, Widget? child) {
    final uiScale = Pref.uiScale;
    final mediaQuery = MediaQuery.of(context);
    final textScaler = TextScaler.linear(Pref.defaultTextScale);
    if (uiScale != 1.0) {
      child = MediaQuery(
        data: mediaQuery.copyWith(
          textScaler: textScaler,
          size: mediaQuery.size / uiScale,
          padding: tmpPadding ?? mediaQuery.padding / uiScale,
          viewInsets: mediaQuery.viewInsets / uiScale,
          viewPadding: tmpPadding ?? mediaQuery.viewPadding / uiScale,
          devicePixelRatio: mediaQuery.devicePixelRatio * uiScale,
        ),
        child: child!,
      );
    } else {
      child = MediaQuery(
        data: mediaQuery.copyWith(
          textScaler: textScaler,
          padding: tmpPadding,
          viewPadding: tmpPadding,
        ),
        child: child!,
      );
    }
    if (PlatformUtils.isDesktop) {
      return BackDetector(
        onBack: _onBack,
        child: child,
      );
    }
    return child;
  }

  /// from [DynamicColorBuilderState.initPlatformState]
  static Future<bool> initPlatformState() async {
    if (_light != null || _dark != null) return true;
    // Platform messages may fail, so we use a try/catch PlatformException.
    try {
      final colors = await DynamicColorPlugin.channel.invokeMethod(
        DynamicColorPlugin.methodName,
      );

      if (colors != null) {
        final corePalettes = CorePalettesExt.fromList(colors.toList());
        if (kDebugMode) {
          debugPrint('dynamic_color: Core palette detected.');
        }
        _light = corePalettes.toColorScheme();
        _dark = corePalettes.toColorScheme(brightness: Brightness.dark);
        return true;
      }
    } on PlatformException {
      if (kDebugMode) {
        debugPrint('dynamic_color: Failed to obtain core palette.');
      }
    }

    try {
      final Color? accentColor = await DynamicColorPlugin.getAccentColor();

      if (accentColor != null) {
        if (kDebugMode) {
          debugPrint('dynamic_color: Accent color detected.');
        }
        final variant = Pref.schemeVariant;
        _light = accentColor.asColorSchemeSeed(variant, .light);
        _dark = accentColor.asColorSchemeSeed(variant, .dark);
        return true;
      }
    } on PlatformException {
      if (kDebugMode) {
        debugPrint('dynamic_color: Failed to obtain accent color.');
      }
    }
    if (kDebugMode) {
      debugPrint('dynamic_color: Dynamic color not detected on this device.');
    }
    GStorage.setting.put(SettingBoxKey.dynamicColor, false);
    return false;
  }
}

class _CustomHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // ..maxConnectionsPerHost = 32
    /// The default value is 15 seconds.
    //   ..idleTimeout = const Duration(seconds: 15);
    // the setting only: a debug build (the self-test instances are) checks
    // certificates as a release one does
    if (Pref.badCertificateCallback) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    // the 设置代理 setting for every client the app opens — YouTube,
    // Invidious, model downloads, WebDAV, images, the CDN probes — not the
    // bilibili requests alone (user 2026-10-19); the loopback directly
    client.findProxy = AppProxy.findProxy;
    return client;
  }
}
