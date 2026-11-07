/// LibrePili: `--pref k:type=v`, the self-test's settings, written right
/// after storage opens and before anything reads them (feature-logs/
/// watch-page-shell/design.md §5 S0a): `uiScale` is read next in main(), and
/// a player reads several of its settings once, at its first use, so
/// writing them from a test once the app is up is too late.
///
/// `type` is `bool`, `int`, `double` or `string` and cannot be left out,
/// and it must be the type the app reads the key as ([settingTypes]): Hive
/// keeps a value as the type it was written in, and a reader expecting
/// another throws (`uiScale` written as an int crashes main()'s first read
/// of it) or quietly falls back to its default. An enum stored as its
/// index is an int (`fullScreenMode:int=1`), one stored by name a string.
///
/// The value is percent-decoded ([Uri.decodeComponent]): on Android the
/// arguments come through `am start --esa selftest_args a,b,c`, which
/// splits at every comma, so a comma in a value is written `%2C` (and a `%`
/// as `%25`), the same on every platform.
///
/// Refused, and the run ended before anything is written: a key not in
/// [SettingBoxKey], a value that does not read as its type, a type other
/// than the key's, and the keys of [refusedKeys] (not a single scalar, or
/// read before `--pref` takes effect). A setting silently left out would
/// make a test measure the defaults.
library;

import 'dart:io' show stderr;

import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/utils/self_test.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

abstract final class SelfTestPref {
  /// Writes every `--pref` in [args] to the setting box, or ends the run
  /// (report written, exit code 1) at the first one that is wrong.
  static Future<void> apply(List<String> args) async {
    final values = <String, Object>{};
    for (var i = 0; i < args.length; i++) {
      if (args[i] != '--pref') continue;
      final arg = i + 1 < args.length ? args[++i] : null;
      try {
        if (arg == null) throw const FormatException('no value');
        final (key, value) = parse(arg);
        values[key] = value;
      } on FormatException catch (e) {
        final message = '--pref ${arg ?? ''}: ${e.message}';
        stderr.writeln(message);
        SelfTest.abort(args, message);
      }
    }
    if (values.isNotEmpty) await GStorage.setting.putAll(values);
    // `--yt-list-delay <s>` (stage-2 plan §5 AC14): the download list read
    // later, so a panel's 「下载」 waits for it
    final i = args.indexOf('--yt-list-delay');
    if (i != -1 && i + 1 < args.length) {
      final seconds = num.tryParse(args[i + 1]);
      if (seconds == null || seconds < 0) {
        SelfTest.abort(
          args,
          '--yt-list-delay takes seconds, not "${args[i + 1]}"',
        );
      } else {
        DownloadService.selfTestListDelay = Duration(
          milliseconds: (seconds * 1000).round(),
        );
      }
    }
  }

  /// `k:type=v` as the key and the value in its type.
  static (String, Object) parse(String arg) {
    final eq = arg.indexOf('=');
    final colon = eq < 0 ? -1 : arg.lastIndexOf(':', eq);
    if (eq < 0 || colon <= 0) {
      throw const FormatException('not k:type=v');
    }
    final key = arg.substring(0, colon);
    final type = arg.substring(colon + 1, eq);
    final String text;
    try {
      text = Uri.decodeComponent(arg.substring(eq + 1));
    } on ArgumentError {
      throw const FormatException('bad %-escape in the value');
    }
    if (refusedKeys[key] case final reason?) {
      throw FormatException('$key is $reason');
    }
    final expected = settingTypes[key];
    if (expected == null) {
      throw FormatException('no setting named $key');
    }
    final Object value = switch (type) {
      'bool' => switch (text) {
        'true' => true,
        'false' => false,
        _ => throw FormatException('$text is not a bool'),
      },
      'int' =>
        int.tryParse(text) ?? (throw FormatException('$text is not an int')),
      'double' =>
        double.tryParse(text) ??
            (throw FormatException('$text is not a double')),
      'string' => text,
      _ => throw FormatException('type $type is not bool, int, double, string'),
    };
    if (value.runtimeType != expected) {
      throw FormatException('$key is read as $expected, not $type');
    }
    return (key, value);
  }

  /// The type each key of [SettingBoxKey] is read as, taken from its
  /// readers (lib/utils/storage_pref.dart and the others: the getter's
  /// type, its `defaultValue`, an enum built from the stored index), spelt
  /// out: Dart has no reflection here. A key renamed or removed there no
  /// longer compiles here; one added there is refused until it is added
  /// here, with the type its reader expects.
  static const settingTypes = <String, Type>{
    SettingBoxKey.btmProgressBehavior: int,
    SettingBoxKey.defaultVideoQa: int,
    SettingBoxKey.defaultVideoQaCellular: int,
    SettingBoxKey.defaultAudioQa: int,
    SettingBoxKey.defaultAudioQaCellular: int,
    SettingBoxKey.autoPlayEnable: bool,
    SettingBoxKey.fullScreenMode: int,
    SettingBoxKey.defaultToastOp: double,
    SettingBoxKey.defaultPicQa: int,
    SettingBoxKey.enableHA: bool,
    SettingBoxKey.audioOutput: String,
    SettingBoxKey.bufferSize: double,
    SettingBoxKey.bufferSec: double,
    SettingBoxKey.backBufferSec: double,
    SettingBoxKey.hardwareDecoding: String,
    SettingBoxKey.videoSync: String,
    SettingBoxKey.autosync: String,
    SettingBoxKey.p1080: bool,
    SettingBoxKey.enableAutoEnter: bool,
    SettingBoxKey.enableAutoExit: bool,
    SettingBoxKey.enableOnlineTotal: bool,
    SettingBoxKey.superChatType: int,
    SettingBoxKey.fullScreenSCWidth: double,
    SettingBoxKey.keyboardControl: bool,
    SettingBoxKey.pauseOnMinimize: bool,
    SettingBoxKey.pgcSkipType: int,
    SettingBoxKey.audioPlayMode: int,
    SettingBoxKey.showBatteryLevel: bool,
    SettingBoxKey.playerVolume: double,
    SettingBoxKey.maxVolume: double,
    SettingBoxKey.enableVerticalExpand: bool,
    SettingBoxKey.feedBackEnable: bool,
    SettingBoxKey.enableLongShowControl: bool,
    SettingBoxKey.horizontalScreen: bool,
    SettingBoxKey.CDNService: String,
    SettingBoxKey.disableAudioCDN: bool,
    SettingBoxKey.parallelFetch: bool,
    SettingBoxKey.videoCacheMb: int,
    SettingBoxKey.autoPiP: bool,
    SettingBoxKey.enableAutoLongPressSpeed: bool,
    SettingBoxKey.useRelativeSlide: bool,
    SettingBoxKey.sliderDuration: int,
    SettingBoxKey.enableQuickDouble: bool,
    SettingBoxKey.fullScreenGestureReverse: bool,
    SettingBoxKey.enableBackgroundPlay: bool,
    SettingBoxKey.continuePlayInBackground: bool,
    SettingBoxKey.appRcmd: bool,
    SettingBoxKey.enableSaveLastData: bool,
    SettingBoxKey.minDurationForRcmd: int,
    SettingBoxKey.minPlayForRcmd: int,
    SettingBoxKey.minLikeRatioForRecommend: int,
    SettingBoxKey.exemptFilterForFollowed: bool,
    SettingBoxKey.banWordForRecommend: String,
    SettingBoxKey.applyFilterToRelatedVideos: bool,
    SettingBoxKey.autoUpdate: bool,
    SettingBoxKey.defaultShowComment: bool,
    SettingBoxKey.replySortType: int,
    SettingBoxKey.reply2SortType: int,
    SettingBoxKey.defaultDynamicType: int,
    SettingBoxKey.showDynInteraction: bool,
    SettingBoxKey.enableHotKey: bool,
    SettingBoxKey.enableSearchRcmd: bool,
    SettingBoxKey.enableQuickFav: bool,
    SettingBoxKey.enableWordRe: bool,
    SettingBoxKey.enableSearchWord: bool,
    SettingBoxKey.enableSystemProxy: bool,
    SettingBoxKey.enableAi: bool,
    SettingBoxKey.disableLikeMsg: bool,
    SettingBoxKey.defaultHomePage: int,
    SettingBoxKey.previewQuality: int,
    SettingBoxKey.checkDynamic: bool,
    SettingBoxKey.dynamicPeriod: int,
    SettingBoxKey.schemeVariant: int,
    SettingBoxKey.showViewPoints: bool,
    SettingBoxKey.showRelatedVideo: bool,
    SettingBoxKey.showVideoReply: bool,
    SettingBoxKey.hideInteraction: bool,
    SettingBoxKey.loginMode: bool,
    SettingBoxKey.dlSaveDanmakuXml: bool,
    SettingBoxKey.dlSaveDanmakuAss: bool,
    SettingBoxKey.dlSaveSubtitle: bool,
    SettingBoxKey.dlTranscribe: bool,
    SettingBoxKey.dlSaveComments: bool,
    SettingBoxKey.dlSaveCover: bool,
    SettingBoxKey.dlSavePreview: bool,
    SettingBoxKey.dlCommentCount: int,
    SettingBoxKey.dlReplyCount: int,
    SettingBoxKey.asrMode: int,
    SettingBoxKey.ytRegion: String,
    SettingBoxKey.ytLanguage: String,
    SettingBoxKey.ytSubIsolate: bool,
    SettingBoxKey.asrAsked: bool,
    SettingBoxKey.asrLanguage: String,
    SettingBoxKey.asrThreads: int,
    SettingBoxKey.asrEnglishModel: bool,
    SettingBoxKey.translateMode: int,
    SettingBoxKey.translateAsked: bool,
    SettingBoxKey.translateModel: String,
    SettingBoxKey.translateDual: bool,
    SettingBoxKey.commentTranslateDisplay: String,
    SettingBoxKey.modelBench: String,
    SettingBoxKey.subtitleChoice: String,
    SettingBoxKey.subtitleSource: String,
    SettingBoxKey.subtitleCacheLimit: int,
    SettingBoxKey.av1Hardware: bool,
    SettingBoxKey.av1Software: bool,
    SettingBoxKey.platformMode: int,
    SettingBoxKey.showBangumiReply: bool,
    SettingBoxKey.alwaysExpandIntroPanel: bool,
    SettingBoxKey.expandIntroPanelH: bool,
    SettingBoxKey.horizontalSeasonPanel: bool,
    SettingBoxKey.horizontalMemberPage: bool,
    SettingBoxKey.replyLengthLimit: int,
    SettingBoxKey.showArgueMsg: bool,
    SettingBoxKey.reverseFromFirst: bool,
    SettingBoxKey.badCertificateCallback: bool,
    SettingBoxKey.continuePlayingPart: bool,
    SettingBoxKey.cdnSpeedTest: bool,
    SettingBoxKey.horizontalPreview: bool,
    SettingBoxKey.banWordForReply: String,
    SettingBoxKey.banWordForZone: String,
    SettingBoxKey.savedRcmdTip: bool,
    SettingBoxKey.openInBrowser: bool,
    SettingBoxKey.refreshDisplacement: double,
    SettingBoxKey.showHotRcmd: bool,
    SettingBoxKey.audioNormalization: String,
    SettingBoxKey.fallbackNormalization: String,
    SettingBoxKey.superResolutionType: int,
    SettingBoxKey.preInitPlayer: bool,
    SettingBoxKey.mainTabBarView: bool,
    SettingBoxKey.searchSuggestion: bool,
    SettingBoxKey.showScanButton: bool,
    SettingBoxKey.scanExplained: bool,
    SettingBoxKey.ctlServer: bool,
    SettingBoxKey.ctlControl: bool,
    SettingBoxKey.debugMode: bool,
    SettingBoxKey.showDecorate: bool,
    SettingBoxKey.showMedal: bool,
    SettingBoxKey.enableLivePhoto: bool,
    SettingBoxKey.showSeekPreview: bool,
    SettingBoxKey.showDmChart: bool,
    SettingBoxKey.enableCommAntifraud: bool,
    SettingBoxKey.biliSendCommAntifraud: bool,
    SettingBoxKey.enableCreateDynAntifraud: bool,
    SettingBoxKey.coinWithLike: bool,
    SettingBoxKey.isPureBlackTheme: bool,
    SettingBoxKey.antiGoodsDyn: bool,
    SettingBoxKey.antiGoodsReply: bool,
    SettingBoxKey.expandDynLivePanel: bool,
    SettingBoxKey.enableHttp2: bool,
    SettingBoxKey.slideDismissReplyPage: bool,
    SettingBoxKey.showFSActionItem: bool,
    SettingBoxKey.enableShrinkVideoSize: bool,
    SettingBoxKey.showDynActionBar: bool,
    SettingBoxKey.darkVideoPage: bool,
    SettingBoxKey.enableSlideVolumeBrightness: bool,
    SettingBoxKey.enableSlideFS: bool,
    SettingBoxKey.retryCount: int,
    SettingBoxKey.retryDelay: int,
    SettingBoxKey.liveQuality: int,
    SettingBoxKey.liveQualityCellular: int,
    SettingBoxKey.fastForBackwardDuration: int,
    SettingBoxKey.recordSearchHistory: bool,
    SettingBoxKey.showPgcTimeline: bool,
    SettingBoxKey.pageTransition: int,
    SettingBoxKey.optTabletNav: bool,
    SettingBoxKey.banWordForDyn: String,
    SettingBoxKey.enableLog: bool,
    SettingBoxKey.memberTab: int,
    SettingBoxKey.directExitOnBack: bool,
    SettingBoxKey.quickFavId: int,
    SettingBoxKey.showFsScreenshotBtn: bool,
    SettingBoxKey.showFsLockBtn: bool,
    SettingBoxKey.silentDownImg: bool,
    SettingBoxKey.showMemberShop: bool,
    SettingBoxKey.enablePlayAll: bool,
    SettingBoxKey.enableTapDm: bool,
    SettingBoxKey.setSystemBrightness: bool,
    SettingBoxKey.downloadPath: String,
    SettingBoxKey.imageSavePath: String,
    SettingBoxKey.followOrderType: int,
    SettingBoxKey.enableImgMenu: bool,
    SettingBoxKey.showDynDispute: bool,
    SettingBoxKey.touchSlopH: double,
    SettingBoxKey.floatingNavBar: bool,
    SettingBoxKey.removeSafeArea: bool,
    SettingBoxKey.angleDegrees: int,
    SettingBoxKey.enableDocProvider: bool,
    SettingBoxKey.enableEmoteTooltip: bool,
    SettingBoxKey.minimizeOnExit: bool,
    SettingBoxKey.isWindowMaximized: bool,
    SettingBoxKey.showWindowTitleBar: bool,
    SettingBoxKey.desktopVolume: double,
    SettingBoxKey.showTrayIcon: bool,
    SettingBoxKey.uiScale: double,
    SettingBoxKey.subtitlePreferenceV2: int,
    SettingBoxKey.enableDragSubtitle: bool,
    SettingBoxKey.subtitlePaddingH: int,
    SettingBoxKey.subtitlePaddingB: int,
    SettingBoxKey.subtitleBgOpacity: double,
    SettingBoxKey.subtitleStrokeWidth: double,
    SettingBoxKey.subtitleFontScale: double,
    SettingBoxKey.subtitleFontScaleFS: double,
    SettingBoxKey.subtitleFontWeight: int,
    SettingBoxKey.cjkAutospace: bool,
    SettingBoxKey.webdavUri: String,
    SettingBoxKey.webdavUsername: String,
    SettingBoxKey.webdavPassword: String,
    SettingBoxKey.webdavDirectory: String,
    SettingBoxKey.enableSponsorBlock: bool,
    SettingBoxKey.blockLimit: double,
    SettingBoxKey.blockUserID: String,
    SettingBoxKey.blockToast: bool,
    SettingBoxKey.blockServer: String,
    SettingBoxKey.blockTrack: bool,
    SettingBoxKey.enableShowDanmaku: bool,
    SettingBoxKey.enableShowLiveDanmaku: bool,
    SettingBoxKey.pipNoDanmaku: bool,
    SettingBoxKey.showVipDanmaku: bool,
    SettingBoxKey.mergeDanmaku: bool,
    SettingBoxKey.danmakuWeight: int,
    SettingBoxKey.danmakuShowArea: double,
    SettingBoxKey.danmakuOpacity: double,
    SettingBoxKey.danmakuFontScale: double,
    SettingBoxKey.danmakuFontScaleFS: double,
    SettingBoxKey.danmakuDuration: double,
    SettingBoxKey.danmakuStaticDuration: double,
    SettingBoxKey.danmakuMassiveMode: bool,
    SettingBoxKey.danmakuFixedV: bool,
    SettingBoxKey.danmakuStatic2Scroll: bool,
    SettingBoxKey.danmakuLineHeight: double,
    SettingBoxKey.danmakuStrokeWidth: double,
    SettingBoxKey.danmakuFontWeight: int,
    SettingBoxKey.systemProxyHost: String,
    SettingBoxKey.systemProxyPort: String,
    SettingBoxKey.themeMode: int,
    SettingBoxKey.defaultTextScale: double,
    SettingBoxKey.appFontWeightV2: int,
    SettingBoxKey.dynamicColor: bool,
    SettingBoxKey.customColor: int,
    SettingBoxKey.displayMode: String,
    SettingBoxKey.smallCardWidth: double,
    SettingBoxKey.recommendCardWidth: double,
    SettingBoxKey.dynamicsWaterfallFlow: bool,
    SettingBoxKey.upPanelPosition: int,
    SettingBoxKey.dynamicsShowAllFollowedUp: bool,
    SettingBoxKey.useSideBar: bool,
    SettingBoxKey.enableMYBar: bool,
    SettingBoxKey.hideTopBar: bool,
    SettingBoxKey.hideBottomBar: bool,
    SettingBoxKey.barHideType: int,
    SettingBoxKey.dynamicBadgeMode: int,
    SettingBoxKey.msgBadgeMode: int,
    SettingBoxKey.navBarLocalAdded: bool,
    SettingBoxKey.tempPlayerConf: bool,
    SettingBoxKey.reduceLuxColor: int,
    SettingBoxKey.liveCdnUrl: String,
    SettingBoxKey.appFont: String,
    SettingBoxKey.localHistoryPaused: bool,
    SettingBoxKey.localHistoryMax: int,
  };

  /// Keys of [SettingBoxKey] `--pref` does not write, and why; with
  /// [settingTypes] they are every key.
  static const refusedKeys = <String, String>{
    SettingBoxKey.preferCodecs: 'stored as a list: not settable by --pref',
    SettingBoxKey.preferCodecsCellular:
        'stored as a list: not settable by --pref',
    SettingBoxKey.maxCacheSize:
        'read as num (an int or a double alike): not settable by --pref',
    SettingBoxKey.translatePinnedLanguages:
        'stored as a list: not settable by --pref',
    SettingBoxKey.hardwareDecoders: 'stored as a map: not settable by --pref',
    SettingBoxKey.springDescription: 'stored as a list: not settable by --pref',
    SettingBoxKey.dynamicDetailRatio:
        'stored as a list: not settable by --pref',
    SettingBoxKey.liveStream: 'stored as a list: not settable by --pref',
    SettingBoxKey.windowSize: 'stored as a list: not settable by --pref',
    SettingBoxKey.windowPosition: 'stored as a list: not settable by --pref',
    SettingBoxKey.blockSettings: 'stored as a list: not settable by --pref',
    SettingBoxKey.blockColor: 'stored as a list: not settable by --pref',
    SettingBoxKey.danmakuBlockType: 'stored as a set: not settable by --pref',
    SettingBoxKey.tabBarSort: 'stored as a list: not settable by --pref',
    SettingBoxKey.msgUnReadTypeV2: 'stored as a list: not settable by --pref',
    SettingBoxKey.navBarSort: 'stored as a list: not settable by --pref',
    SettingBoxKey.saveReply:
        'read by GStorage.init, before --pref takes effect',
  };
}
