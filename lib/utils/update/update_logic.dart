/// LibrePili: what the update check decides — which release, which of its
/// files, whether this copy can put it in place itself — kept apart from the
/// network and the platform so it can be tested.
///
/// The user's decision (pass3-D2, carried out 2026-10-20): "ask on first
/// launch; updates auto-download and are applied on the next launch".
/// Where a platform cannot take an update from the app (macOS, iOS, a
/// deb/rpm install, a folder it may not write), the app notifies as it
/// always did.
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

/// How a downloaded update is put in place on the next launch.
enum UpdateKind {
  /// handed to Android's installer, which always asks
  apk('apk'),

  /// the Windows portable zip, copied over the install folder by a helper
  windowsZip('windows_zip'),

  /// the AppImage file itself, replaced by a helper
  appImage('appimage'),

  /// the Linux tar.gz bundle, copied over the install folder by a helper
  linuxTarGz('linux_targz');

  const UpdateKind(this.id);

  /// As kept in the staged update's record.
  final String id;

  static UpdateKind? byId(Object? id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// Where this copy runs, as far as an update cares.
class UpdateHost {
  const UpdateHost({
    required this.os,
    this.abi,
    this.packageName,
    this.exePath,
    this.appImage,
    this.installWritable = false,
  });

  /// `Platform.operatingSystem`.
  final String os;

  /// Android: the device's first supported ABI.
  final String? abi;

  /// Android: this app's package; null when the app's update channel did
  /// not answer (then no APK can be handed over either).
  final String? packageName;

  /// Windows and Linux: `Platform.resolvedExecutable`.
  final String? exePath;

  /// Linux: the `APPIMAGE` environment variable, set when running as one.
  final String? appImage;

  /// Whether the folder an update replaces files in may be written.
  final bool installWritable;
}

/// What an update is applied by on a host, or why the app only notifies.
typedef UpdatePlan = ({UpdateKind? kind, String? fallback});

/// What start-up does about updates, by the 检查更新 key.
enum UpdateStartUp {
  /// not answered yet: ask, and send nothing to GitHub till then
  ask,

  /// on: check (and download a newer version)
  check,

  /// off: nothing
  nothing,
}

/// Why this copy may not download or put an update in place itself (it
/// notifies as before instead).
enum UpdateBlock {
  /// built without build.ps1's dart-defines (`pili.code` unset): not a
  /// release, so a release must not replace it, nor one staged by another
  /// copy sharing the app-support folder be applied over it
  localBuild('local build without pili.code'),

  /// 禁用 SSL 证书验证 on: the release list (and its digests) and the
  /// download are not checked against a certificate, so anyone on the path
  /// could serve both; a staged update waits until it is off again
  uncheckedTls('禁用 SSL 证书验证 is on'),

  /// 检查更新 off (or never answered)
  autoOff('检查更新 is off');

  const UpdateBlock(this.reason);

  final String reason;
}

abstract final class UpdateLogic {
  /// What BuildConfig.versionCode is when no `pili.code` was given — a
  /// local `flutter build` without `--dart-define-from-file`.
  static const unsetVersionCode = 1;

  /// Why updates may not be staged or applied now, or null when they may.
  static UpdateBlock? blockFor({
    required int versionCode,
    required bool badCertificates,
    required bool? autoUpdate,
  }) {
    if (versionCode <= unsetVersionCode) return UpdateBlock.localBuild;
    if (badCertificates) return UpdateBlock.uncheckedTls;
    if (autoUpdate != true) return UpdateBlock.autoOff;
    return null;
  }

  /// Null is "not asked" (Pref.autoUpdate): the question, never a request.
  static UpdateStartUp startUpFor(bool? autoUpdate) => switch (autoUpdate) {
    null => UpdateStartUp.ask,
    true => UpdateStartUp.check,
    false => UpdateStartUp.nothing,
  };

  /// The Android test build's file (`LibrePili_android_<v>_dev_<abi>.apk`).
  static bool isDevAsset(String name) => name.contains('_dev_');

  static bool onlyDev(Object? assets) =>
      assets is List &&
      assets.isNotEmpty &&
      assets.every((a) => a is Map && isDevAsset('${a['name']}'));

  static final _appTag = RegExp(r'^v?\d+\.\d+');

  /// The app's releases only — the repository also keeps non-app releases
  /// (the speech models' mirror, tag asr-models), which are not a new
  /// version of anything — nor one holding only the side-by-side test build
  /// (`_dev_`, its own app id): installed, it sits beside this one instead
  /// of updating it.
  static bool isAppRelease(Object? release) =>
      release is Map &&
      release['draft'] != true &&
      _appTag.hasMatch('${release['tag_name']}') &&
      !onlyDev(release['assets']);

  /// The newest app release in GitHub's list (newest first), if any.
  static Map? newestAppRelease(Object? releases) {
    if (releases is! List) return null;
    for (final r in releases) {
      if (isAppRelease(r)) return r as Map;
    }
    return null;
  }

  static final _code = RegExp(r'\+(\d+)(?=[_.])');

  /// The build number an asset's name carries — build.ps1's `pili.code`,
  /// the commit count: `LibrePili_windows_0.3.0+1234_x64_portable.zip` is
  /// 1234 — or null.
  static int? versionCodeOf(String name) =>
      int.tryParse(_code.firstMatch(name)?.group(1) ?? '');

  /// The highest build number among a release's app files.
  static int? releaseCode(Map release) {
    int? best;
    final assets = release['assets'];
    if (assets is! List) return null;
    for (final a in assets) {
      if (a is! Map) continue;
      final name = '${a['name']}';
      if (isDevAsset(name)) continue;
      final code = versionCodeOf(name);
      if (code != null && (best == null || code > best)) best = code;
    }
    return best;
  }

  /// When the release was made, in seconds.
  static int? createdAt(Map release) {
    final at = DateTime.tryParse('${release['created_at']}');
    return at == null ? null : at.millisecondsSinceEpoch ~/ 1000;
  }

  /// Whether [name] is one of this platform's files: for [kind] the file
  /// staging would take; without it, any file for [os] (on Android the
  /// first ABI's APK).
  static bool isPlatformAsset(
    String name, {
    required String os,
    String? abi,
    UpdateKind? kind,
  }) {
    if (isDevAsset(name)) return false;
    if (kind != null) return _matches(name, kind, abi);
    if (os == 'android') return abi != null && name.endsWith('_$abi.apk');
    return name.contains('_${os}_');
  }

  /// Whether [release] is newer than this build, for this platform. By the
  /// build number of this platform's file (the highest when several match):
  /// a release is made after its own build, so by time alone the version
  /// just installed is "newer" than itself — which, applied automatically,
  /// would update for ever — and a release's files for another platform may
  /// carry another number (a workflow dispatched on its own). By time only
  /// for files that carry no number (as the check always did); by the
  /// release's highest number when it has no file for this platform.
  static bool isNewer(
    Map release, {
    required int versionCode,
    required int buildTime,
    required String os,
    String? abi,
    UpdateKind? kind,
  }) {
    final assets = release['assets'];
    final mine = [
      if (assets is List)
        for (final a in assets)
          if (a is Map &&
              isPlatformAsset('${a['name']}', os: os, abi: abi, kind: kind))
            '${a['name']}',
    ];
    final int? code;
    if (mine.isNotEmpty) {
      code = mine
          .map(versionCodeOf)
          .nonNulls
          .fold<int?>(
            null,
            (best, c) => best == null || c > best ? c : best,
          );
    } else {
      code = releaseCode(release);
    }
    if (code != null) return code > versionCode;
    final at = createdAt(release);
    return at != null && at > buildTime;
  }

  /// deb and rpm both install to /opt/LibrePili (linux_x64.yml), owned by
  /// root and the package manager's to change.
  static bool isPackagedInstall(String exePath) {
    final dir = p.posix.dirname(exePath);
    return dir == '/opt/LibrePili' ||
        p.posix.isWithin('/opt/LibrePili', dir) ||
        p.posix.isWithin('/usr', dir);
  }

  static UpdatePlan _notify(String why) => (kind: null, fallback: why);

  /// How an update reaches this [host]: a kind the app puts in place, or
  /// the reason it notifies instead.
  static UpdatePlan planFor(UpdateHost host) {
    switch (host.os) {
      case 'android':
        final pkg = host.packageName;
        if (pkg == null) return _notify('no update channel');
        // the test build (its own app id): the release's APK would install
        // beside it, not update it
        if (pkg.endsWith('.dev')) return _notify('test build');
        if (host.abi == null || host.abi!.isEmpty) return _notify('no ABI');
        return (kind: UpdateKind.apk, fallback: null);
      case 'windows':
        if (!host.installWritable) {
          return _notify('install folder not writable');
        }
        return (kind: UpdateKind.windowsZip, fallback: null);
      case 'linux':
        final appImage = host.appImage;
        if (appImage != null && appImage.isNotEmpty) {
          if (!host.installWritable) {
            return _notify('AppImage folder not writable');
          }
          return (kind: UpdateKind.appImage, fallback: null);
        }
        final exe = host.exePath;
        if (exe == null || isPackagedInstall(exe)) {
          return _notify('deb/rpm install');
        }
        if (!host.installWritable) {
          return _notify('install folder not writable');
        }
        return (kind: UpdateKind.linuxTarGz, fallback: null);
      default:
        return _notify('${host.os}: no update from the app');
    }
  }

  static bool _matches(String name, UpdateKind kind, String? abi) =>
      switch (kind) {
        // `_x86_64.apk` must not pass for `x86`
        UpdateKind.apk => abi != null && name.endsWith('_$abi.apk'),
        UpdateKind.windowsZip =>
          name.contains('_windows_') && name.endsWith('.zip'),
        UpdateKind.appImage =>
          name.contains('_linux_') && name.endsWith('.AppImage'),
        UpdateKind.linuxTarGz =>
          name.contains('_linux_') && name.endsWith('.tar.gz'),
      };

  /// The release file for [kind] — on Android the one for the device's
  /// first ABI, as the dialog's choice always was — never the test build's.
  /// When several match (a workflow dispatched again on the same tag), the
  /// highest-numbered.
  static Map? assetFor(Object? assets, UpdateKind kind, {String? abi}) {
    if (assets is! List) return null;
    Map? best;
    var bestCode = -1;
    for (final a in assets) {
      if (a is! Map) continue;
      final name = '${a['name']}';
      if (isDevAsset(name) || !_matches(name, kind, abi)) continue;
      final code = versionCodeOf(name) ?? -1;
      if (best == null || code > bestCode) {
        best = a;
        bestCode = code;
      }
    }
    return best;
  }

  /// The helper's outcome line (`<build> <outcome>`, see the helper
  /// scripts): the build it was about, whether it failed, and whether the
  /// old files could not all be put back ([restoreFailed]: the app was not
  /// started, the backup is kept).
  static ({int? code, bool failed, bool restoreFailed}) parseResult(
    String text,
  ) {
    final m = RegExp(r'^(\d+) (.*)$').firstMatch(text.trim());
    final outcome = m?.group(2) ?? text.trim();
    return (
      code: int.tryParse(m?.group(1) ?? ''),
      failed: !outcome.startsWith('applied'),
      restoreFailed: outcome == restoreFailed,
    );
  }

  /// The helpers' outcome when a failed copy could not be undone.
  static const restoreFailed = 'restore-failed';

  static final _sha256 = RegExp(r'^sha256:([0-9a-fA-F]{64})$');

  /// GitHub's `digest` of a release file (`sha256:<hex>`) as lower-case hex;
  /// null when there is none or it is of another kind.
  static String? sha256Of(Object? digest) {
    if (digest is! String) return null;
    return _sha256.firstMatch(digest.trim())?.group(1)?.toLowerCase();
  }

  /// [text] in single quotes for PowerShell.
  static String psQuote(String text) => "'${text.replaceAll("'", "''")}'";

  /// [text] in single quotes for a POSIX shell.
  static String shQuote(String text) => "'${text.replaceAll("'", r"'\''")}'";

  /// The helper the app leaves behind on Windows: waits for the app
  /// ([pid]) to exit, backs up every file of the install folder ([target])
  /// the new version ([source]) replaces and notes the files it adds,
  /// copies the new version over it — on a failure removing the added files
  /// and restoring the backup, so no mix of old and new files is left —
  /// removes what was staged except the outcome ([UpdateStaged.resultName],
  /// `<build> <outcome>`, read on the next start) and the record of a failed
  /// build, and starts the app: the new one, or the old one put back. When
  /// the old files cannot all be put back ([restoreFailed]) the app is not
  /// started and the backup is kept ([UpdateStaged.keptBackupPrefix]); the
  /// next start tells the user. It touches nothing outside [target] and
  /// [staging].
  static String windowsHelperScript({
    required int pid,
    required int versionCode,
    required String source,
    required String target,
    required String staging,
    required String exeName,
  }) =>
      '''
# LibrePili update helper, written by the app (lib/utils/update/).
# Waits for the app to exit, backs up the files it replaces, copies the new
# version over its folder (restoring the backup if that fails), removes the
# downloaded update and starts the app again. Touches nothing else.
\$ErrorActionPreference = 'Continue'
\$appPid = $pid
\$build = $versionCode
\$source = ${psQuote(source)}
\$target = ${psQuote(target)}
\$staging = ${psQuote(staging)}
\$exe = ${psQuote(exeName)}
\$backup = [System.IO.Path]::Combine(\$staging, 'backup')
\$result = [System.IO.Path]::Combine(\$staging, '${UpdateStaged.resultName}')
\$robocopy = [System.IO.Path]::Combine(\$env:SystemRoot, 'System32', 'robocopy.exe')
\$outcome = 'failed: the app did not exit'
for (\$i = 0; \$i -lt 120; \$i++) {
  if (-not (Get-Process -Id \$appPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 500
}
if (-not (Get-Process -Id \$appPid -ErrorAction SilentlyContinue)) {
  \$backedUp = \$true
  \$added = New-Object System.Collections.Generic.List[string]
  try {
    # every file the new version replaces, kept to put back on a failure,
    # and every file it adds, removed again on a failure
    \$from = (Get-Item -LiteralPath \$source).FullName.TrimEnd('\\')
    foreach (\$f in Get-ChildItem -LiteralPath \$source -Recurse -File -Force) {
      \$rel = \$f.FullName.Substring(\$from.Length).TrimStart('\\')
      \$old = [System.IO.Path]::Combine(\$target, \$rel)
      if ([System.IO.File]::Exists(\$old)) {
        \$keep = [System.IO.Path]::Combine(\$backup, \$rel)
        [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName(\$keep)) | Out-Null
        [System.IO.File]::Copy(\$old, \$keep, \$true)
      } else {
        \$added.Add(\$old)
      }
    }
  } catch {
    \$backedUp = \$false
    \$outcome = 'failed: backup: ' + \$_.Exception.Message
  }
  if (\$backedUp) {
    # robocopy retries a file still locked; below 8 is success
    & \$robocopy \$source \$target /E /R:10 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
    \$copied = \$LASTEXITCODE
    if (\$copied -lt 8) {
      \$outcome = 'applied'
    } else {
      # the folder put back as it was: the files this version added removed,
      # the ones it replaced restored
      \$restored = \$true
      foreach (\$new in \$added) {
        try {
          if ([System.IO.File]::Exists(\$new)) { [System.IO.File]::Delete(\$new) }
        } catch {
          \$restored = \$false
        }
      }
      if ([System.IO.Directory]::Exists(\$backup)) {
        & \$robocopy \$backup \$target /E /R:10 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
        if (\$LASTEXITCODE -ge 8) { \$restored = \$false }
      }
      if (\$restored) {
        \$outcome = "failed: robocopy \$copied, restored"
      } else {
        \$outcome = '$restoreFailed'
      }
    }
  }
}
\$keepNames = @('${UpdateStaged.resultName}', '${UpdateStaged.failedName}')
if (\$outcome -eq '$restoreFailed') {
  # old and new files may be mixed: the backup is kept, under a name a later
  # update does not use, and the app is not started
  \$keepNames += 'backup'
  try {
    [System.IO.Directory]::Move(\$backup, [System.IO.Path]::Combine(\$staging, "${UpdateStaged.keptBackupPrefix}\$build"))
  } catch {}
}
Get-ChildItem -LiteralPath \$staging -Force |
  Where-Object { \$keepNames -notcontains \$_.Name -and -not \$_.Name.StartsWith('${UpdateStaged.keptBackupPrefix}') } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath \$result -Value "\$build \$outcome" -Encoding UTF8
if (\$outcome -eq '$restoreFailed') { exit 1 }
# started only with a whole folder: the new version, or the old one put back
if (\$outcome -ne 'failed: the app did not exit') {
  # not Start-Process: it reads [ and ] in a path as wildcards
  \$start = New-Object System.Diagnostics.ProcessStartInfo
  \$start.FileName = [System.IO.Path]::Combine(\$target, \$exe)
  \$start.WorkingDirectory = \$target
  \$start.UseShellExecute = \$false
  [System.Diagnostics.Process]::Start(\$start) | Out-Null
}
''';

  /// The helper the app leaves behind on Linux, as [windowsHelperScript]:
  /// for an AppImage ([appImage] set) it replaces that one file through a
  /// fully written `.new` beside it, renamed over it (a failure leaves the
  /// old file); for the tar.gz bundle it backs up the files it replaces,
  /// notes the files it adds, copies [source] over [target] and on a failure
  /// removes the added files and restores the backup. When that cannot be
  /// done whole ([restoreFailed]) the app is not started and the backup is
  /// kept, as on Windows.
  static String linuxHelperScript({
    required int pid,
    required int versionCode,
    required String staging,
    String? appImage,
    String? source,
    String? target,
    String? exeName,
    String? newAppImage,
  }) {
    assert(
      (appImage != null && newAppImage != null) ||
          (source != null && target != null && exeName != null),
    );
    const result = '"\$staging/${UpdateStaged.resultName}"';
    const clear =
        'find "\$staging" -mindepth 1 -maxdepth 1 '
        "! -name '${UpdateStaged.resultName}' "
        "! -name '${UpdateStaged.failedName}' "
        "! -name '${UpdateStaged.keptBackupPrefix}*' -exec rm -rf {} +";
    final String copy;
    final String start;
    if (appImage != null) {
      copy =
          '''
app_image=${shQuote(appImage)}
new_image=${shQuote(newAppImage!)}
if cp -f "\$new_image" "\$app_image.new" && chmod +x "\$app_image.new" && mv -f "\$app_image.new" "\$app_image"; then
  outcome='applied'
else
  rm -f "\$app_image.new"
  outcome='failed: could not replace the AppImage'
fi''';
      start = r'nohup "$app_image" >/dev/null 2>&1 &';
    } else {
      copy =
          '''
source=${shQuote(source!)}
target=${shQuote(target!)}
backup="\$staging/backup"
added="\$staging/added.txt"
mkdir -p "\$backup"
: > "\$added"
# every file the new version replaces, kept to put back on a failure, and
# every file it adds, removed again on a failure
if (cd "\$source" && find . \\( -type f -o -type l \\) -print) | while IFS= read -r f; do
  if [ -e "\$target/\$f" ] || [ -L "\$target/\$f" ]; then
    mkdir -p "\$backup/\$(dirname "\$f")" && cp -Pp "\$target/\$f" "\$backup/\$f" || exit 1
  else
    printf '%s\\n' "\$f" >> "\$added" || exit 1
  fi
done; then
  if cp -Rf "\$source"/. "\$target"/; then
    outcome='applied'
  else
    # the folder put back as it was: the files this version added removed,
    # the ones it replaced restored
    restored=1
    while IFS= read -r f; do
      if [ -e "\$target/\$f" ] || [ -L "\$target/\$f" ]; then
        rm -f "\$target/\$f" || restored=0
      fi
    done < "\$added"
    cp -Rf "\$backup"/. "\$target"/ || restored=0
    if [ "\$restored" = 1 ]; then
      outcome='failed: could not copy the new version, restored'
    else
      outcome='$restoreFailed'
    fi
  fi
else
  outcome='failed: backup'
fi''';
      start = 'nohup "\$target"/${shQuote(exeName!)} >/dev/null 2>&1 &';
    }
    return '''
#!/bin/sh
# LibrePili update helper, written by the app (lib/utils/update/).
# Waits for the app to exit, puts the new version in place (the old files
# back if that fails), removes the downloaded update and starts the app
# again. Touches nothing else.
app_pid=$pid
build=$versionCode
staging=${shQuote(staging)}
i=0
while kill -0 "\$app_pid" 2>/dev/null; do
  i=\$((i + 1))
  if [ "\$i" -ge 120 ]; then
    $clear
    echo "\$build failed: the app did not exit" > $result
    exit 1
  fi
  sleep 0.5
done
$copy
if [ "\$outcome" = '$restoreFailed' ]; then
  # old and new files may be mixed: the backup is kept, under a name a later
  # update does not use, and the app is not started
  kept='${UpdateStaged.keptBackupPrefix}'"\$build"
  mv "\$staging/backup" "\$staging/\$kept" 2>/dev/null || kept=backup
  find "\$staging" -mindepth 1 -maxdepth 1 ! -name '${UpdateStaged.resultName}' ! -name '${UpdateStaged.failedName}' ! -name '${UpdateStaged.keptBackupPrefix}*' ! -name "\$kept" -exec rm -rf {} +
  echo "\$build $restoreFailed" > $result
  exit 1
fi
$clear
echo "\$build \$outcome" > $result
# started only with a whole folder: the new version, or the old one put back
$start
''';
  }
}

/// A downloaded, verified update waiting for the next launch: the record
/// kept beside the file in the staging folder.
class UpdateStaged {
  const UpdateStaged({
    required this.tag,
    required this.versionCode,
    required this.kind,
    required this.asset,
    required this.size,
    required this.sha256,
    this.page,
  });

  /// The record's file in the staging folder.
  static const manifestName = 'staged.json';

  /// What the helper left about how applying went, read on the next start.
  static const resultName = 'result.txt';

  /// The build that failed to go in place (its helper said so): not
  /// downloaded again by itself; a newer one is, and 手动检查更新 still
  /// offers it. Kept when the staging folder is cleared.
  static const failedName = 'failed-build.txt';

  /// A backup the helper could not put back whole, kept (with the build
  /// after it) for the user; never cleared by the app.
  static const keptBackupPrefix = 'backup-failed-';

  final String tag;

  /// The build number of the file ([UpdateLogic.versionCodeOf]): at or
  /// below this build's, the update is in place (or was installed by hand).
  final int versionCode;
  final UpdateKind kind;

  /// The file's name, as published and as kept in the staging folder.
  final String asset;
  final int size;

  /// Lower-case hex.
  final String sha256;

  /// The release's page, for the notice when it cannot be applied.
  final String? page;

  Map<String, Object?> toJson() => {
    'tag': tag,
    'versionCode': versionCode,
    'kind': kind.id,
    'asset': asset,
    'size': size,
    'sha256': sha256,
    'page': page,
  };

  String encode() => jsonEncode(toJson());

  /// Null for a record that is not whole.
  static UpdateStaged? decode(String text) {
    try {
      final json = jsonDecode(text);
      if (json is! Map) return null;
      final kind = UpdateKind.byId(json['kind']);
      final tag = json['tag'];
      final code = json['versionCode'];
      final asset = json['asset'];
      final size = json['size'];
      final sha = json['sha256'];
      if (kind == null ||
          tag is! String ||
          code is! int ||
          asset is! String ||
          size is! int ||
          sha is! String ||
          // only ever a plain name inside the staging folder
          asset.isEmpty ||
          asset != p.basename(asset) ||
          asset.contains('/') ||
          asset.contains(r'\') ||
          asset == '..') {
        return null;
      }
      final page = json['page'];
      return UpdateStaged(
        tag: tag,
        versionCode: code,
        kind: kind,
        asset: asset,
        size: size,
        sha256: sha,
        page: page is String ? page : null,
      );
    } catch (_) {
      return null;
    }
  }
}
