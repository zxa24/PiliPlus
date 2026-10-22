import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/update/update_apply.dart';
import 'package:PiliPlus/utils/update/update_logic.dart';
import 'package:PiliPlus/utils/update/update_stage.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

abstract final class Update {
  /// At start-up (MainController): nothing goes to GitHub until the user
  /// has answered the one-time question (pass3-D2, user 2026-10-20: "ask on
  /// first launch"); then, when on, the check, which downloads a newer
  /// version to be put in place on the next launch. On Android a staged APK
  /// is offered to the installer first.
  static void startUp() {
    if (kDebugMode || isSelfTestProfile) return;
    // an update whose old files could not all be put back (UpdateApply)
    if (UpdateApply.takeNotice() case final notice?) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tell(notice));
    }
    final action = UpdateLogic.startUpFor(Pref.autoUpdate);
    if (action == UpdateStartUp.ask) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askOnce());
      return;
    }
    if (Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _offerApk());
    }
    if (action == UpdateStartUp.check) checkUpdate();
  }

  /// Android, a downloaded and verified update at launch: asked first
  /// (user 2026-10-21: 「下次启动先问有更新，是否现在安装，可跳过或不再问」)
  /// — 安装 opens the system installer, 跳过 asks again next launch,
  /// 不再提示此版本 drops it until a newer one (手动检查更新 still offers it).
  static Future<void> _offerApk() async {
    final staged = await UpdateApply.readyApk();
    if (staged == null) return;
    UpdateStage.log('${staged.tag}: offered at launch');
    SmartDialog.show(
      clickMaskDismiss: false,
      builder: (context) {
        void skip() {
          SmartDialog.dismiss();
          UpdateStage.log('${staged.tag}: skipped this launch');
        }

        return AlertDialog(
          title: const Text('有新版本'),
          content: Text(
            'LibrePili ${staged.tag} 已下载并校验，是否现在安装？\n\n'
            '「跳过」：下次启动时再问。\n'
            '「不再提示此版本」：删除已下载的安装包；有更新的版本时会再提示，'
            '也可在「关于」页手动检查更新。',
          ),
          actions: [
            TextButton(
              onPressed: () {
                SmartDialog.dismiss();
                UpdateApply.skipApk(staged);
              },
              child: const Text('不再提示此版本'),
            ),
            TextButton(onPressed: skip, child: const Text('跳过')),
            TextButton(
              onPressed: () {
                SmartDialog.dismiss();
                UpdateApply.installApk(staged);
              },
              child: const Text('安装'),
            ),
          ],
        );
      },
    );
  }

  static void _tell(String notice) {
    SmartDialog.show(
      builder: (context) => AlertDialog(
        title: const Text('更新失败'),
        content: SingleChildScrollView(child: SelectableText(notice)),
        actions: const [
          TextButton(
            onPressed: SmartDialog.dismiss,
            child: Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 自动检查并下载更新？是/否 — asked once; the answer is the 检查更新
  /// switch's own key. Closed without an answer, it is asked again next
  /// launch.
  static void _askOnce() {
    SmartDialog.show(
      clickMaskDismiss: false,
      backType: SmartBackType.block,
      builder: (context) {
        final colorScheme = ColorScheme.of(context);
        void answer(bool yes) {
          SmartDialog.dismiss();
          GStorage.setting.put(SettingBoxKey.autoUpdate, yes);
          UpdateStage.log('auto update ${yes ? 'on' : 'off'} (first launch)');
          if (yes) checkUpdate();
        }

        return AlertDialog(
          title: const Text('自动更新'),
          content: const Text(
            '自动检查并下载更新？\n\n'
            '选「是」：每次启动时连接 GitHub 检查新版本，有新版本时在后台下载并校验，'
            '下次启动时更新（Android 会先问是否现在安装）。\n'
            '选「否」：不会自动连接 GitHub；仍可在「关于」页手动检查更新。\n\n'
            '之后可在 设置 → 其它设置 →「检查更新」中更改。',
          ),
          actions: [
            TextButton(
              onPressed: () => answer(false),
              child: Text('否', style: TextStyle(color: colorScheme.outline)),
            ),
            TextButton(
              onPressed: () => answer(true),
              child: const Text('是'),
            ),
          ],
        );
      },
    );
  }

  /// The 检查更新 switch: off drops a downloaded update that has not been
  /// put in place (it would otherwise still apply on the next launch).
  static void onAutoChanged(bool on) {
    if (on) {
      checkUpdate(false);
    } else if (!kDebugMode && !isSelfTestProfile) {
      unawaited(
        UpdateStage.discard(UpdateApply.stagingDir, 'auto update turned off'),
      );
    }
  }

  // 检查更新
  static Future<void> checkUpdate([bool isAuto = true]) async {
    if (kDebugMode) return;
    SmartDialog.dismiss();
    try {
      final res = await Request().get(
        Api.latestApp,
        options: Options(
          headers: {'user-agent': BrowserUa.mob},
          extra: {'account': const NoAccount()},
        ),
      );
      if (res.data is Map || res.data.isEmpty) {
        if (!isAuto) {
          SmartDialog.showToast('检查更新失败，GitHub接口未返回数据，请检查网络');
        }
        return;
      }
      // LibrePili: the app's releases only (UpdateLogic.isAppRelease)
      final data = UpdateLogic.newestAppRelease(res.data);
      if (data == null) {
        if (!isAuto) SmartDialog.showToast('已是最新版本');
        return;
      }
      // newer by this platform's own file: another platform's may carry
      // another build number
      final host = await _host();
      final plan = UpdateLogic.planFor(host);
      if (!UpdateLogic.isNewer(
        data,
        versionCode: BuildConfig.versionCode,
        buildTime: BuildConfig.buildTime,
        os: host.os,
        abi: host.abi,
        kind: plan.kind,
      )) {
        if (!isAuto) {
          SmartDialog.showToast('已是最新版本');
        }
        return;
      }
      // the build the user said not to be asked about again (Android)
      if (isAuto && _skipped(data, host, plan)) {
        UpdateStage.log('${data['tag_name']}: skipped by the user');
        return;
      }
      if (isAuto && !isSelfTestProfile && await _stage(data, host, plan)) {
        return;
      }
      _showDialog(data, isAuto);
    } catch (e) {
      if (kDebugMode) debugPrint('failed to check update: $e');
    }
  }

  /// Whether [release]'s file for this platform is the build the user said
  /// not to be asked about again ([UpdateStage.skippedBuild]).
  static bool _skipped(Map release, UpdateHost host, UpdatePlan plan) {
    final kind = plan.kind;
    if (kind == null) return false;
    final skipped = UpdateStage.skippedBuild(UpdateApply.stagingDir);
    if (skipped == null) return false;
    final asset = UpdateLogic.assetFor(release['assets'], kind, abi: host.abi);
    return asset != null &&
        UpdateLogic.versionCodeOf('${asset['name']}') == skipped;
  }

  /// Starts downloading [release]'s file for this platform into the staging
  /// folder; true when it took the release over (downloading, or already
  /// staged). False — notify as before — where the app cannot put an update
  /// in place, while updates are held back ([UpdateApply.block]), for a
  /// file with no digest to check it by, or for the build that failed to go
  /// in place last time. A download that fails or does not match its digest
  /// notifies when it ends.
  static Future<bool> _stage(
    Map release,
    UpdateHost host,
    UpdatePlan plan,
  ) async {
    final tag = '${release['tag_name']}';
    // a local build, unchecked TLS, the switch off: notify only
    if (UpdateApply.block case final block?) {
      UpdateStage.log('$tag: notify only (${block.reason})');
      return false;
    }
    final kind = plan.kind;
    if (kind == null) {
      UpdateStage.log('$tag: notify only (${plan.fallback})');
      return false;
    }
    final asset = UpdateLogic.assetFor(
      release['assets'],
      kind,
      abi: host.abi,
    );
    if (asset == null) {
      UpdateStage.log('$tag: no ${kind.id} file');
      return false;
    }
    final name = '${asset['name']}';
    final sha = UpdateLogic.sha256Of(asset['digest']);
    final code = UpdateLogic.versionCodeOf(name);
    final url = asset['browser_download_url'];
    final size = asset['size'];
    if (sha == null) {
      UpdateStage.log('$tag: $name has no sha256 digest, not downloaded');
      return false;
    }
    if (code == null || url is! String || size is! int) {
      UpdateStage.log('$tag: $name lacks a build number, URL or size');
      return false;
    }
    if (code <= BuildConfig.versionCode) {
      UpdateStage.log('$tag: $name is build $code, not newer');
      return false;
    }
    if (UpdateStage.failedBuild(UpdateApply.stagingDir) == code) {
      UpdateStage.log('$tag: build $code failed to go in place before');
      return false;
    }
    final staged = UpdateStaged(
      tag: tag,
      versionCode: code,
      kind: kind,
      asset: name,
      size: size,
      sha256: sha,
      page: release['html_url'] is String ? release['html_url'] : null,
    );
    unawaited(
      UpdateStage.stage(
        UpdateApply.stagingDir,
        url,
        staged,
        stillWanted: () => UpdateApply.block == null,
      ).then((outcome) {
        switch (outcome) {
          case UpdateStageOutcome.staged:
            SmartDialog.showToast('新版本已下载，下次启动时更新');
          case UpdateStageOutcome.alreadyStaged:
          case UpdateStageOutcome.busy:
          case UpdateStageOutcome.dropped:
            break;
          case UpdateStageOutcome.mismatch:
          case UpdateStageOutcome.failed:
            _showDialog(release, true);
        }
      }),
    );
    return true;
  }

  static Future<UpdateHost> _host() async {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      return UpdateHost(
        os: 'android',
        abi: info.supportedAbis.firstOrNull,
        packageName: await UpdateApply.packageName(),
      );
    }
    final exe = Platform.resolvedExecutable;
    final appImage = Platform.isLinux ? Platform.environment['APPIMAGE'] : null;
    final folder = appImage != null && appImage.isNotEmpty
        ? p.dirname(appImage)
        : p.dirname(exe);
    return UpdateHost(
      os: Platform.operatingSystem,
      exePath: exe,
      appImage: appImage,
      installWritable:
          (Platform.isWindows || Platform.isLinux) &&
          UpdateApply.writable(folder),
    );
  }

  /// The staged update, if one waits for the next launch (the 关于 page).
  static UpdateStaged? get staged {
    if (kDebugMode || isSelfTestProfile || UpdateApply.block != null) {
      return null;
    }
    final staged = UpdateStage.read(UpdateApply.stagingDir);
    if (staged == null || staged.versionCode <= BuildConfig.versionCode) {
      return null;
    }
    return staged;
  }

  static void _showDialog(Map data, bool isAuto) {
    final staged = Update.staged;
    final isStaged = staged != null && staged.tag == '${data['tag_name']}';
    SmartDialog.show(
      animationType: SmartAnimationType.centerFade_otherSlide,
      builder: (context) {
        final colorScheme = ColorScheme.of(context);
        Widget downloadBtn(String text, {String? ext}) => TextButton(
          onPressed: () => onDownload(data, ext: ext),
          child: Text(text),
        );
        return AlertDialog(
          title: const Text('🎉 发现新版本 '),
          content: SizedBox(
            height: 280,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${data['tag_name']}',
                    style: const TextStyle(fontSize: 20),
                  ),
                  if (isStaged) ...[
                    const SizedBox(height: 4),
                    Text(
                      '已下载，下次启动时更新',
                      style: TextStyle(color: colorScheme.primary),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text('${data['body']}'),
                  TextButton(
                    onPressed: () => PageUtils.launchURL(
                      '${data['html_url'] ?? '${Constants.sourceCodeUrl}/releases'}',
                    ),
                    child: Text(
                      "点此查看这个版本的发布页",
                      style: TextStyle(color: colorScheme.primary),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (isAuto)
              TextButton(
                onPressed: () {
                  SmartDialog.dismiss();
                  GStorage.setting.put(SettingBoxKey.autoUpdate, false);
                  onAutoChanged(false);
                },
                child: Text(
                  '不再提醒',
                  style: TextStyle(color: colorScheme.outline),
                ),
              ),
            TextButton(
              onPressed: SmartDialog.dismiss,
              child: Text(
                '取消',
                style: TextStyle(color: colorScheme.outline),
              ),
            ),
            // Windows: only the portable zip is published (no installer)
            if (Platform.isWindows)
              downloadBtn('zip', ext: 'zip')
            else if (Platform.isLinux) ...[
              downloadBtn('rpm', ext: 'rpm'),
              downloadBtn('deb', ext: 'deb'),
              downloadBtn('targz', ext: 'tar.gz'),
            ] else
              downloadBtn('Github'),
          ],
        );
      },
    );
  }

  // 下载适用于当前系统的安装包
  static Future<void> onDownload(Map data, {String? ext}) async {
    SmartDialog.dismiss();
    try {
      void download(String plat) {
        if (data['assets'].isNotEmpty) {
          for (Map<String, dynamic> i in data['assets']) {
            final String name = i['name'];
            if (UpdateLogic.isDevAsset(name)) continue;
            if (name.contains(plat) &&
                (ext == null || ext.isEmpty ? true : name.endsWith(ext))) {
              PageUtils.launchURL(i['browser_download_url']);
              return;
            }
          }
          throw UnsupportedError('platform not found: $plat');
        }
      }

      if (Platform.isAndroid) {
        // 获取设备信息
        AndroidDeviceInfo androidInfo = await DeviceInfoPlugin().androidInfo;
        // [arm64-v8a]
        download(androidInfo.supportedAbis.first);
      } else {
        download(Platform.operatingSystem);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('download error: $e');
      // this release's page: GitHub's /releases/latest is the newest
      // release of any kind, which was the speech models' mirror
      // (asr-models, measured 2026-10-19)
      PageUtils.launchURL(
        '${data['html_url'] ?? '${Constants.sourceCodeUrl}/releases'}',
      );
    }
  }
}
