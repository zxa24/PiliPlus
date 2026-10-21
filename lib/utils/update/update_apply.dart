/// LibrePili: putting a staged update in place on the next launch.
///
/// Windows and Linux before the UI starts ([applyBeforeUi]): the new files
/// are unpacked into the staging folder, a helper script written there is
/// started detached, and this process exits; the helper waits for it, copies
/// the files over the install folder, clears the staging and starts the app
/// again. Android after the UI ([offerStagedApk]): the APK goes to the
/// system installer, which always asks; cancelled, it is offered again on
/// the next launch. Each step, and each reason for not taking one, goes to
/// the [EventLog] (area `update`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/update/update_logic.dart';
import 'package:PiliPlus/utils/update/update_stage.dart';
import 'package:archive/archive_io.dart' show extractFileToDisk;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

abstract final class UpdateApply {
  /// UpdateInstaller in MainActivity's engine (UpdateInstaller.kt).
  static const channel = MethodChannel('librepili/update');

  /// `<app support>/update`.
  static String get stagingDir => p.join(appSupportDirPath, 'update');

  static const _extracted = 'extracted';
  static const _helperWindows = 'apply-update.ps1';
  static const _helperLinux = 'apply-update.sh';

  /// Whether updates are put in place in this run at all: never in a debug
  /// build (the build folder is the developer's) nor a self-test profile.
  static bool get enabled => !kDebugMode && !isSelfTestProfile;

  /// Why no update may be staged or applied now (UpdateLogic.blockFor).
  static UpdateBlock? get block => UpdateLogic.blockFor(
    versionCode: BuildConfig.versionCode,
    badCertificates: Pref.badCertificateCallback,
    autoUpdate: Pref.autoUpdate,
  );

  /// True when [block] holds a staged update back. 检查更新 off drops it, as
  /// the switch does; under 禁用 SSL 证书验证 it waits; a local build leaves
  /// it alone (it may be another copy's, in the shared folder).
  static Future<bool> _heldBack() async {
    final why = block;
    if (why == null) return false;
    final staged = UpdateStage.read(stagingDir);
    if (staged == null) return true;
    if (why == UpdateBlock.autoOff) {
      await UpdateStage.discard(stagingDir, 'not applied: ${why.reason}');
    } else {
      UpdateStage.log('${staged.tag} not applied: ${why.reason}');
    }
    return true;
  }

  /// Whether a file can be made in [dir] (tried, then removed).
  static bool writable(String dir) {
    final probe = File(p.join(dir, '.librepili-write-test-$pid'));
    try {
      probe
        ..writeAsStringSync('')
        ..deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// What the user must be told about the last apply, for the UI to show
  /// once it is up (Update.startUp); taken once.
  static String? _notice;

  static String? takeNotice() {
    final notice = _notice;
    _notice = null;
    return notice;
  }

  /// The helper's outcome from the last start, read once: logged, and a
  /// failed build recorded. When its old files could not all be put back
  /// the install folder may be mixed: the user is told where it is and
  /// where the kept backup is.
  static void _settleResult() {
    final dir = stagingDir;
    final result = UpdateStage.takeResult(dir);
    if (result == null) return;
    UpdateStage.log('last apply: $result');
    final outcome = UpdateLogic.parseResult(result);
    final code = outcome.code;
    if (outcome.failed && code != null) UpdateStage.recordFailed(dir, code);
    if (outcome.restoreFailed) {
      final install = p.dirname(Platform.resolvedExecutable);
      var backup = p.join(dir, '${UpdateStaged.keptBackupPrefix}$code');
      if (!Directory(backup).existsSync()) backup = p.join(dir, 'backup');
      UpdateStage.log(
        'build $code: the old files could not all be put back; install '
        'folder $install may be mixed, backup kept at $backup',
      );
      _notice =
          '自动更新失败：新版本（构建 $code）未能装入，原来的文件也未能全部恢复，'
          '安装目录中的文件可能新旧混杂。\n\n'
          '若应用工作不正常，请从发布页重新下载压缩包，解压后覆盖到安装目录：\n'
          '$install\n\n'
          '被替换前的原文件备份在：\n$backup';
    }
  }

  /// The staged update still waiting, after what earlier launches left is
  /// settled: the helper's outcome is logged, and an update at or below
  /// this build (applied, or installed by hand) is cleared.
  static Future<UpdateStaged?> pending() async {
    final dir = stagingDir;
    _settleResult();
    final staged = UpdateStage.read(dir);
    if (staged == null) return null;
    if (staged.versionCode <= BuildConfig.versionCode) {
      await UpdateStage.discard(
        dir,
        '${staged.tag} is in place (build ${BuildConfig.versionCode})',
      );
      return null;
    }
    return staged;
  }

  /// Windows and Linux: when a verified update is staged, starts the helper
  /// that puts it in place and returns true — the caller then exits. False
  /// when there is nothing to apply or it cannot be (logged; the update is
  /// cleared and the next check notifies instead).
  static Future<bool> applyBeforeUi() async {
    if (!enabled || !(Platform.isWindows || Platform.isLinux)) return false;
    try {
      // first, whatever holds the update back: a failed restore is told
      _settleResult();
      if (await _heldBack()) return false;
      final staged = await pending();
      if (staged == null) return false;
      final dir = stagingDir;
      final file = UpdateStage.fileOf(dir, staged);
      if (!await UpdateStage.verify(file, staged.sha256)) {
        await UpdateStage.discard(dir, '${staged.asset} no longer verifies');
        return false;
      }
      UpdateStage.log('${staged.asset} verified again before applying');
      final why = switch (staged.kind) {
        UpdateKind.windowsZip when Platform.isWindows => await _startBundle(
          dir,
          staged,
          windows: true,
        ),
        UpdateKind.linuxTarGz when Platform.isLinux => await _startBundle(
          dir,
          staged,
          windows: false,
        ),
        UpdateKind.appImage when Platform.isLinux => await _startAppImage(
          dir,
          staged,
        ),
        _ => '${staged.kind.id} does not apply on ${Platform.operatingSystem}',
      };
      if (why == null) return true;
      UpdateStage.recordFailed(dir, staged.versionCode);
      await UpdateStage.discard(dir, 'not applied: $why');
      return false;
    } catch (e) {
      UpdateStage.log('apply failed: $e');
      if (UpdateStage.read(stagingDir) case final staged?) {
        UpdateStage.recordFailed(stagingDir, staged.versionCode);
      }
      await UpdateStage.discard(stagingDir, 'apply failed');
      return false;
    }
  }

  /// The Windows zip or the Linux tar.gz: unpacked, then copied over the
  /// exe's folder by the helper. Null when the helper started, the reason
  /// otherwise.
  static Future<String?> _startBundle(
    String dir,
    UpdateStaged staged, {
    required bool windows,
  }) async {
    final exe = Platform.resolvedExecutable;
    final target = p.dirname(exe);
    final exeName = p.basename(exe);
    if (!windows && UpdateLogic.isPackagedInstall(exe)) {
      return 'deb/rpm install';
    }
    if (!writable(target)) return 'install folder not writable';
    final out = Directory(p.join(dir, _extracted));
    if (out.existsSync()) await out.delete(recursive: true);
    await out.create(recursive: true);
    final archive = UpdateStage.fileOf(dir, staged);
    if (windows) {
      // archive's own check keeps every entry inside [out]
      await extractFileToDisk(archive, out.path);
    } else {
      // tar keeps the files' modes (the executable bit)
      final r = await Process.run('tar', ['-xzf', archive, '-C', out.path]);
      if (r.exitCode != 0) return 'tar failed: ${r.stderr}'.trim();
    }
    final source = findBundleRoot(out.path, exeName);
    if (source == null) return '$exeName not found in ${staged.asset}';
    UpdateStage.log('${staged.asset} unpacked; starting the helper');
    if (windows) {
      final script = File(p.join(dir, _helperWindows));
      // PowerShell 5 reads a file without a BOM as the ANSI code page
      await script.writeAsBytes([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(
          UpdateLogic.windowsHelperScript(
            pid: pid,
            versionCode: staged.versionCode,
            source: source,
            target: target,
            staging: dir,
            exeName: exeName,
          ),
        ),
      ], flush: true);
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      await Process.start(
        p.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          script.path,
        ],
        mode: ProcessStartMode.detached,
      );
    } else {
      final script = File(p.join(dir, _helperLinux));
      await script.writeAsString(
        UpdateLogic.linuxHelperScript(
          pid: pid,
          versionCode: staged.versionCode,
          staging: dir,
          source: source,
          target: target,
          exeName: exeName,
        ),
        flush: true,
      );
      await Process.start(
        '/bin/sh',
        [script.path],
        mode: ProcessStartMode.detached,
      );
    }
    return null;
  }

  /// The AppImage: the file at `APPIMAGE` replaced by the helper.
  static Future<String?> _startAppImage(String dir, UpdateStaged staged) async {
    final appImage = Platform.environment['APPIMAGE'];
    if (appImage == null || appImage.isEmpty) return 'not an AppImage now';
    if (!writable(p.dirname(appImage))) return 'AppImage folder not writable';
    final script = File(p.join(dir, _helperLinux));
    await script.writeAsString(
      UpdateLogic.linuxHelperScript(
        pid: pid,
        versionCode: staged.versionCode,
        staging: dir,
        appImage: appImage,
        newAppImage: UpdateStage.fileOf(dir, staged),
      ),
      flush: true,
    );
    UpdateStage.log('starting the helper for ${staged.asset}');
    await Process.start(
      '/bin/sh',
      [script.path],
      mode: ProcessStartMode.detached,
    );
    return null;
  }

  /// The folder in [extracted] holding [exeName]: the top, or its one
  /// folder (the Windows zip holds `LibrePili-Win/`).
  static String? findBundleRoot(String extracted, String exeName) {
    if (File(p.join(extracted, exeName)).existsSync()) return extracted;
    final dirs = Directory(
      extracted,
    ).listSync(followLinks: false).whereType<Directory>().toList();
    if (dirs.length == 1 &&
        File(p.join(dirs.single.path, exeName)).existsSync()) {
      return dirs.single.path;
    }
    return null;
  }

  /// This app's package, from UpdateInstaller.kt; null without it.
  static Future<String?> packageName() async {
    try {
      return await channel.invokeMethod<String>('packageName');
    } catch (_) {
      return null;
    }
  }

  /// Android: a verified staged APK handed to the system installer (it asks
  /// the user). Kept until this build is at its version, so a cancelled
  /// install is offered again on the next launch.
  static Future<void> offerStagedApk() async {
    if (!enabled || !Platform.isAndroid) return;
    try {
      if (await _heldBack()) return;
      final staged = await pending();
      if (staged == null) return;
      final dir = stagingDir;
      if (staged.kind != UpdateKind.apk) {
        await UpdateStage.discard(dir, '${staged.kind.id} on Android');
        return;
      }
      final file = UpdateStage.fileOf(dir, staged);
      if (!await UpdateStage.verify(file, staged.sha256)) {
        await UpdateStage.discard(dir, '${staged.asset} no longer verifies');
        return;
      }
      final why = await channel.invokeMethod<String>('installApk', {
        'path': file,
      });
      if (why == null) {
        UpdateStage.log('installer opened for ${staged.asset}');
      } else {
        UpdateStage.log('installer not opened for ${staged.asset}: $why');
      }
    } catch (e) {
      UpdateStage.log('installer not opened: $e');
    }
  }
}
