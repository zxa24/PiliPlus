import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/update/update_apply.dart';
import 'package:PiliPlus/utils/update/update_logic.dart';
import 'package:PiliPlus/utils/update/update_stage.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

Map<String, Object?> _asset(String name, {String? digest, int size = 3}) => {
  'name': name,
  'digest': digest,
  'size': size,
  'browser_download_url': 'https://example.invalid/$name',
};

Map<String, Object?> _release(
  String tag,
  List<Map<String, Object?>> assets, {
  bool draft = false,
  String createdAt = '2026-10-20T00:00:00Z',
}) => {
  'tag_name': tag,
  'draft': draft,
  'created_at': createdAt,
  'assets': assets,
};

const _v = '0.3.0+1234';
final _all = [
  _asset('LibrePili_android_0.3.0-abcdef123+1234_arm64-v8a.apk'),
  _asset('LibrePili_android_0.3.0-abcdef123+1234_armeabi-v7a.apk'),
  _asset('LibrePili_android_0.3.0-abcdef123+1234_x86_64.apk'),
  _asset('LibrePili_android_0.3.0-abcdef123+1234_dev_arm64-v8a.apk'),
  _asset('LibrePili_windows_${_v}_x64_portable.zip'),
  _asset('LibrePili_linux_${_v}_amd64.tar.gz'),
  _asset('LibrePili_linux_${_v}_amd64.deb'),
  _asset('LibrePili_linux_${_v}_amd64.rpm'),
  _asset('LibrePili_linux_${_v}_amd64.AppImage'),
  _asset('LibrePili_macos_$_v.dmg'),
];

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  group('release choice', () {
    test('the newest app release, skipping non-app, draft and dev-only', () {
      final releases = [
        _release('asr-models', [_asset('model.tar.bz2')]),
        _release('v0.4.0', _all, draft: true),
        _release('v0.3.9', [
          _asset('LibrePili_android_0.3.9-x+1300_dev_arm64-v8a.apk'),
        ]),
        _release('v0.3.0', _all),
        _release('v0.2.0', _all),
      ];
      expect(UpdateLogic.newestAppRelease(releases)?['tag_name'], 'v0.3.0');
      expect(UpdateLogic.newestAppRelease(<Object>[]), isNull);
      expect(UpdateLogic.newestAppRelease({'message': 'rate limited'}), isNull);
    });

    test('build number from the file names, the test build ignored', () {
      expect(
        UpdateLogic.versionCodeOf('LibrePili_windows_${_v}_x64_portable.zip'),
        1234,
      );
      expect(
        UpdateLogic.versionCodeOf(
          'LibrePili_android_0.3.0-abcdef123+77_arm64-v8a.apk',
        ),
        77,
      );
      expect(UpdateLogic.versionCodeOf('LibrePili_macos_0.3.0.dmg'), isNull);
      final release = _release('v0.3.0', [
        _asset('LibrePili_android_0.3.0-x+9999_dev_arm64-v8a.apk'),
        _asset('LibrePili_windows_0.3.0+1234_x64_portable.zip'),
      ]);
      expect(UpdateLogic.releaseCode(release), 1234);
    });

    test('newer by build number, not by when the release was made', () {
      final release = _release('v0.3.0', _all);
      // made after this very build: by time it would look newer
      expect(
        UpdateLogic.isNewer(
          release,
          versionCode: 1234,
          buildTime: 0,
          os: 'windows',
          kind: UpdateKind.windowsZip,
        ),
        isFalse,
      );
      expect(
        UpdateLogic.isNewer(
          release,
          versionCode: 1233,
          buildTime: 1 << 40,
          os: 'windows',
          kind: UpdateKind.windowsZip,
        ),
        isTrue,
      );
      // no number in the names: by time, as before
      final bare = _release('v0.3.0', [_asset('LibrePili_macos_0.3.0.dmg')]);
      final at = UpdateLogic.createdAt(bare)!;
      expect(
        UpdateLogic.isNewer(
          bare,
          versionCode: 2,
          buildTime: at - 1,
          os: 'macos',
        ),
        isTrue,
      );
      expect(
        UpdateLogic.isNewer(bare, versionCode: 2, buildTime: at, os: 'macos'),
        isFalse,
      );
    });

    test('newer by this platform\'s own file, the highest of several', () {
      // Windows zip at this build, the Android files higher (a workflow
      // dispatched on its own): not newer on Windows, newer on Android
      final mixed = _release('v0.3.1', [
        _asset('LibrePili_android_0.3.1-x+1300_arm64-v8a.apk'),
        _asset('LibrePili_windows_0.3.0+1234_x64_portable.zip'),
      ]);
      expect(
        UpdateLogic.isNewer(
          mixed,
          versionCode: 1234,
          buildTime: 0,
          os: 'windows',
          kind: UpdateKind.windowsZip,
        ),
        isFalse,
      );
      expect(
        UpdateLogic.isNewer(
          mixed,
          versionCode: 1234,
          buildTime: 0,
          os: 'windows',
        ),
        isFalse,
      );
      expect(
        UpdateLogic.isNewer(
          mixed,
          versionCode: 1234,
          buildTime: 0,
          os: 'android',
          abi: 'arm64-v8a',
          kind: UpdateKind.apk,
        ),
        isTrue,
      );
      // two Windows zips: the higher-numbered is chosen and decides
      final twice = _release('v0.3.1', [
        _asset('LibrePili_windows_0.3.0+1234_x64_portable.zip'),
        _asset('LibrePili_windows_0.3.1+1240_x64_portable.zip'),
      ]);
      expect(
        UpdateLogic.assetFor(twice['assets'], UpdateKind.windowsZip)?['name'],
        'LibrePili_windows_0.3.1+1240_x64_portable.zip',
      );
      expect(
        UpdateLogic.isNewer(
          twice,
          versionCode: 1234,
          buildTime: 0,
          os: 'windows',
          kind: UpdateKind.windowsZip,
        ),
        isTrue,
      );
      // no file for this platform: the release's highest number, as before
      expect(
        UpdateLogic.isNewer(mixed, versionCode: 1234, buildTime: 0, os: 'ios'),
        isTrue,
      );
    });
  });

  group('when updates are held back', () {
    test('a local build (pili.code unset) never stages nor applies', () {
      expect(
        UpdateLogic.blockFor(
          versionCode: UpdateLogic.unsetVersionCode,
          badCertificates: false,
          autoUpdate: true,
        ),
        UpdateBlock.localBuild,
      );
    });

    test('禁用 SSL 证书验证 on: notify only', () {
      expect(
        UpdateLogic.blockFor(
          versionCode: 1234,
          badCertificates: true,
          autoUpdate: true,
        ),
        UpdateBlock.uncheckedTls,
      );
    });

    test('检查更新 must be on, not merely unanswered', () {
      for (final auto in [false, null]) {
        expect(
          UpdateLogic.blockFor(
            versionCode: 1234,
            badCertificates: false,
            autoUpdate: auto,
          ),
          UpdateBlock.autoOff,
        );
      }
      expect(
        UpdateLogic.blockFor(
          versionCode: 1234,
          badCertificates: false,
          autoUpdate: true,
        ),
        isNull,
      );
    });
  });

  group('asset choice per platform', () {
    String? name(UpdateKind kind, {String? abi}) =>
        UpdateLogic.assetFor(_all, kind, abi: abi)?['name'] as String?;

    test('Android: the first ABI exactly, never the test build', () {
      expect(
        name(UpdateKind.apk, abi: 'arm64-v8a'),
        endsWith('+1234_arm64-v8a.apk'),
      );
      expect(name(UpdateKind.apk, abi: 'arm64-v8a'), isNot(contains('_dev_')));
      expect(name(UpdateKind.apk, abi: 'x86_64'), endsWith('_x86_64.apk'));
      // x86 must not take the x86_64 file
      expect(name(UpdateKind.apk, abi: 'x86'), isNull);
      expect(name(UpdateKind.apk), isNull);
    });

    test('Windows zip, Linux AppImage and tar.gz', () {
      expect(
        name(UpdateKind.windowsZip),
        'LibrePili_windows_${_v}_x64_portable.zip',
      );
      expect(name(UpdateKind.appImage), 'LibrePili_linux_${_v}_amd64.AppImage');
      expect(name(UpdateKind.linuxTarGz), 'LibrePili_linux_${_v}_amd64.tar.gz');
    });

    test('plan per host', () {
      UpdateKind? kind(UpdateHost h) => UpdateLogic.planFor(h).kind;
      const android = UpdateHost(
        os: 'android',
        abi: 'arm64-v8a',
        packageName: 'com.zxa24.librepili',
      );
      expect(kind(android), UpdateKind.apk);
      expect(
        kind(const UpdateHost(os: 'android', abi: 'arm64-v8a')),
        isNull,
        reason: 'no update channel',
      );
      expect(
        kind(
          const UpdateHost(
            os: 'android',
            abi: 'arm64-v8a',
            packageName: 'com.zxa24.librepili.dev',
          ),
        ),
        isNull,
        reason: 'the test build',
      );
      expect(
        kind(
          const UpdateHost(
            os: 'windows',
            exePath: r'C:\Apps\LibrePili-Win\LibrePili.exe',
            installWritable: true,
          ),
        ),
        UpdateKind.windowsZip,
      );
      expect(
        UpdateLogic.planFor(
          const UpdateHost(
            os: 'windows',
            exePath: r'C:\Program Files\LibrePili\LibrePili.exe',
          ),
        ).fallback,
        'install folder not writable',
      );
      expect(
        kind(
          const UpdateHost(
            os: 'linux',
            exePath: '/tmp/.mount_x/usr/bin/librepili',
            appImage: '/home/u/Apps/LibrePili.AppImage',
            installWritable: true,
          ),
        ),
        UpdateKind.appImage,
      );
      expect(
        kind(
          const UpdateHost(
            os: 'linux',
            exePath: '/home/u/librepili/librepili',
            installWritable: true,
          ),
        ),
        UpdateKind.linuxTarGz,
      );
      // deb/rpm: /opt/LibrePili, notify even if it could be written
      expect(
        UpdateLogic.planFor(
          const UpdateHost(
            os: 'linux',
            exePath: '/opt/LibrePili/librepili',
            installWritable: true,
          ),
        ).fallback,
        'deb/rpm install',
      );
      expect(kind(const UpdateHost(os: 'macos')), isNull);
      expect(kind(const UpdateHost(os: 'ios')), isNull);
    });
  });

  group('digest', () {
    test('sha256:<hex> only', () {
      final hex = 'A' * 64;
      expect(UpdateLogic.sha256Of('sha256:$hex'), 'a' * 64);
      expect(UpdateLogic.sha256Of(null), isNull);
      expect(UpdateLogic.sha256Of(''), isNull);
      expect(UpdateLogic.sha256Of('sha512:$hex'), isNull);
      expect(UpdateLogic.sha256Of('sha256:abc'), isNull);
    });

    group('staging a download', () {
      late Directory tmp;
      late HttpServer server;
      final body = List<int>.generate(100000, (i) => i * 7 % 251);
      final ranges = <String?>[];

      setUp(() async {
        tmp = await Directory.systemTemp.createTemp('update_test');
        ranges.clear();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
          ..listen((req) async {
            final range = req.headers.value(HttpHeaders.rangeHeader);
            ranges.add(range);
            final from = range == null
                ? 0
                : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
            req.response.statusCode = range == null
                ? HttpStatus.ok
                : HttpStatus.partialContent;
            req.response.add(body.sublist(from));
            await req.response.close();
          });
      });

      tearDown(() async {
        await server.close(force: true);
        await tmp.delete(recursive: true);
      });

      String url() => 'http://127.0.0.1:${server.port}/file.zip';

      UpdateStaged staged(String sha) => UpdateStaged(
        tag: 'v0.3.0',
        versionCode: 1234,
        kind: UpdateKind.windowsZip,
        asset: 'LibrePili_windows_${_v}_x64_portable.zip',
        size: body.length,
        sha256: sha,
      );

      test('a matching file is staged, and found again', () async {
        final s = staged(_sha(body));
        expect(
          await UpdateStage.stage(tmp.path, url(), s),
          UpdateStageOutcome.staged,
        );
        final read = UpdateStage.read(tmp.path);
        expect(read?.tag, 'v0.3.0');
        expect(read?.sha256, _sha(body));
        expect(
          await File(UpdateStage.fileOf(tmp.path, read!)).readAsBytes(),
          body,
        );
        expect(
          await UpdateStage.stage(tmp.path, url(), s),
          UpdateStageOutcome.alreadyStaged,
        );
      });

      test('a mismatch is not staged and leaves nothing behind', () async {
        final s = staged('0' * 64);
        expect(
          await UpdateStage.stage(tmp.path, url(), s),
          UpdateStageOutcome.mismatch,
        );
        expect(UpdateStage.read(tmp.path), isNull);
        expect(tmp.listSync(), isEmpty);
      });

      test(
        'no longer wanted when it finished: dropped, nothing staged',
        () async {
          final s = staged(_sha(body));
          expect(
            await UpdateStage.stage(
              tmp.path,
              url(),
              s,
              stillWanted: () => false,
            ),
            UpdateStageOutcome.dropped,
          );
          expect(UpdateStage.read(tmp.path), isNull);
          expect(tmp.listSync(), isEmpty);
        },
      );

      test('an interrupted download resumes where it stopped', () async {
        final s = staged(_sha(body));
        final part = File(
          p.join(tmp.path, '${s.sha256.substring(0, 16)}.part'),
        );
        await part.writeAsBytes(body.sublist(0, 40000));
        expect(
          await UpdateStage.stage(tmp.path, url(), s),
          UpdateStageOutcome.staged,
        );
        expect(ranges, ['bytes=40000-']);
        expect(
          await UpdateStage.verify(UpdateStage.fileOf(tmp.path, s), s.sha256),
          isTrue,
        );
      });
    });
  });

  group('first launch', () {
    late Directory tmp;

    setUpAll(() async {
      tmp = await Directory.systemTemp.createTemp('update_pref_test');
      Hive.init(tmp.path);
      GStorage.setting = await Hive.openBox('setting');
    });

    tearDownAll(() async {
      await Hive.close();
      await tmp.delete(recursive: true);
    });

    setUp(() => GStorage.setting.clear());

    test('not asked yet: the question, no check', () {
      expect(Pref.autoUpdate, isNull);
      expect(UpdateLogic.startUpFor(Pref.autoUpdate), UpdateStartUp.ask);
    });

    test('a value an install already has is kept', () async {
      await GStorage.setting.put(SettingBoxKey.autoUpdate, true);
      expect(UpdateLogic.startUpFor(Pref.autoUpdate), UpdateStartUp.check);
      await GStorage.setting.put(SettingBoxKey.autoUpdate, false);
      expect(UpdateLogic.startUpFor(Pref.autoUpdate), UpdateStartUp.nothing);
    });
  });

  group('staged update on disk', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('staged'));
    tearDown(() => tmp.delete(recursive: true));

    const s = UpdateStaged(
      tag: 'v0.3.0',
      versionCode: 1234,
      kind: UpdateKind.apk,
      asset: 'LibrePili_android_0.3.0-x+1234_arm64-v8a.apk',
      size: 3,
      sha256: 'abc',
    );

    void write(String manifest, {int size = 3}) {
      File(p.join(tmp.path, UpdateStaged.manifestName))
          .writeAsStringSync(manifest);
      File(p.join(tmp.path, s.asset)).writeAsBytesSync(List.filled(size, 1));
    }

    test('found when the record and its file agree', () {
      write(s.encode());
      final read = UpdateStage.read(tmp.path);
      expect(read?.kind, UpdateKind.apk);
      expect(read?.versionCode, 1234);
    });

    test('not found: wrong size, no record, a broken or escaping record', () {
      expect(UpdateStage.read(tmp.path), isNull);
      write(s.encode(), size: 2);
      expect(UpdateStage.read(tmp.path), isNull);
      write('{"tag": 1}');
      expect(UpdateStage.read(tmp.path), isNull);
      final escaping = s.toJson()..['asset'] = '../outside.apk';
      expect(UpdateStaged.decode(jsonEncode(escaping)), isNull);
      expect(
        UpdateStaged.decode(
          s.encode().replaceAll(s.asset, r'..\\outside.apk'),
        ),
        isNull,
      );
    });

    test(
      'the helper result is read once; discard empties the folder',
      () async {
        File(p.join(tmp.path, UpdateStaged.resultName))
            .writeAsStringSync('applied\n');
        expect(UpdateStage.takeResult(tmp.path), 'applied');
        expect(UpdateStage.takeResult(tmp.path), isNull);
        write(s.encode());
        await UpdateStage.discard(tmp.path, 'test');
        expect(tmp.existsSync(), isTrue);
        expect(tmp.listSync(), isEmpty);
      },
    );

    test('a failed build is remembered and kept when clearing', () async {
      expect(UpdateStage.failedBuild(tmp.path), isNull);
      UpdateStage.recordFailed(tmp.path, 1240);
      write(s.encode());
      await UpdateStage.discard(tmp.path, 'test');
      expect(UpdateStage.failedBuild(tmp.path), 1240);
      expect(tmp.listSync().map((e) => p.basename(e.path)), [
        UpdateStaged.failedName,
      ]);
    });

    test('a backup the helper could not put back is never cleared', () async {
      Directory(
        p.join(tmp.path, '${UpdateStaged.keptBackupPrefix}1240', 'data'),
      ).createSync(recursive: true);
      Directory(p.join(tmp.path, 'backup')).createSync();
      write(s.encode());
      await UpdateStage.discard(tmp.path, 'test');
      expect(tmp.listSync().map((e) => p.basename(e.path)), [
        '${UpdateStaged.keptBackupPrefix}1240',
      ]);
    });

    test('the helper\'s result line: build and outcome', () {
      expect(UpdateLogic.parseResult('1240 applied\n'), (
        code: 1240,
        failed: false,
        restoreFailed: false,
      ));
      expect(UpdateLogic.parseResult('1240 failed: robocopy 9, restored'), (
        code: 1240,
        failed: true,
        restoreFailed: false,
      ));
      expect(UpdateLogic.parseResult('failed: the app did not exit'), (
        code: null,
        failed: true,
        restoreFailed: false,
      ));
      expect(UpdateLogic.parseResult('1240 restore-failed'), (
        code: 1240,
        failed: true,
        restoreFailed: true,
      ));
    });

    test('the unpacked bundle: at the top, or in its one folder', () {
      final top = Directory(p.join(tmp.path, 'a'))..createSync();
      File(p.join(top.path, 'librepili')).writeAsStringSync('');
      expect(UpdateApply.findBundleRoot(top.path, 'librepili'), top.path);
      final zip = Directory(p.join(tmp.path, 'b', 'LibrePili-Win'))
        ..createSync(recursive: true);
      File(p.join(zip.path, 'LibrePili.exe')).writeAsStringSync('');
      expect(
        UpdateApply.findBundleRoot(p.join(tmp.path, 'b'), 'LibrePili.exe'),
        zip.path,
      );
      expect(UpdateApply.findBundleRoot(top.path, 'LibrePili.exe'), isNull);
    });
  });

  group('helper scripts (text only, never run)', () {
    test('Windows: waits, copies within the two folders, restarts', () {
      final script = UpdateLogic.windowsHelperScript(
        pid: 4242,
        versionCode: 1240,
        source: r"C:\Users\O'Neil\AppData\update\extracted\LibrePili-Win",
        target: r'C:\Apps\LibrePili-Win',
        staging: r"C:\Users\O'Neil\AppData\update",
        exeName: 'LibrePili.exe',
      );
      expect(script, contains(r'$appPid = 4242'));
      expect(
        script,
        contains(
          r"$source = 'C:\Users\O''Neil\AppData\update\extracted\LibrePili-Win'",
        ),
      );
      expect(script, contains(r"$target = 'C:\Apps\LibrePili-Win'"));
      expect(script, contains(r"$staging = 'C:\Users\O''Neil\AppData\update'"));
      expect(script, contains(r'Get-Process -Id $appPid'));
      expect(script, contains(r'& $robocopy $source $target /E'));
      expect(
        script,
        contains(r"$keepNames = @('result.txt', 'failed-build.txt')"),
      );
      expect(
        script,
        contains(
          r"Where-Object { $keepNames -notcontains $_.Name -and -not $_.Name.StartsWith('backup-failed-') }",
        ),
      );
      expect(script, contains(r'$build = 1240'));
      expect(
        script,
        contains(r'Set-Content -LiteralPath $result -Value "$build $outcome"'),
      );
      // nothing deleted but the staging's contents
      expect(RegExp('Remove-Item').allMatches(script).length, 1);
      expect(script, isNot(contains('/MIR')));
      expect(script, isNot(contains('/PURGE')));
    });

    test('Windows: backs up what it replaces, restores it on a failure', () {
      final script = UpdateLogic.windowsHelperScript(
        pid: 1,
        versionCode: 1240,
        source: r'C:\Users\u\update\extracted\LibrePili-Win',
        target: r'C:\Apps\a [b]\LibrePili-Win',
        staging: r'C:\Users\u\update',
        exeName: 'LibrePili.exe',
      );
      final backup = script.indexOf(
        r'[System.IO.File]::Copy($old, $keep, $true)',
      );
      final copy = script.indexOf(r'& $robocopy $source $target');
      final restore = script.indexOf(r'& $robocopy $backup $target');
      expect(backup, greaterThan(0));
      expect(copy, greaterThan(backup), reason: 'backed up before copying');
      expect(restore, greaterThan(copy), reason: 'restored after a failure');
      expect(
        script,
        contains(r"$backup = [System.IO.Path]::Combine($staging, 'backup')"),
      );
      expect(script, contains(r'if ($copied -lt 8)'));
      expect(script, contains(r'"failed: robocopy $copied, restored"'));
      // the copy only runs once the backup is whole
      expect(script, contains(r'if ($backedUp) {'));
      expect(script, contains(r"$target = 'C:\Apps\a [b]\LibrePili-Win'"));
    });

    test('Windows: a failed copy removes what it added; a failed restore '
        'keeps the backup and does not start the app', () {
      final script = UpdateLogic.windowsHelperScript(
        pid: 1,
        versionCode: 1240,
        source: r'C:\Users\u\update\extracted\LibrePili-Win',
        target: r'C:\Apps\LibrePili-Win',
        staging: r'C:\Users\u\update',
        exeName: 'LibrePili.exe',
      );
      // noted while backing up, before the copy
      final noted = script.indexOf(r'$added.Add($old)');
      final copy = script.indexOf(r'& $robocopy $source $target');
      final removed = script.indexOf(r'[System.IO.File]::Delete($new)');
      final restore = script.indexOf(r'& $robocopy $backup $target');
      expect(noted, greaterThan(0));
      expect(copy, greaterThan(noted));
      expect(removed, greaterThan(copy), reason: 'only after a failed copy');
      expect(restore, greaterThan(removed));
      expect(
        script,
        contains(r'if ($LASTEXITCODE -ge 8) { $restored = $false }'),
      );
      expect(script, contains(r"$outcome = 'restore-failed'"));
      // the backup kept under its own name, the result written, no start
      expect(
        script,
        contains(
          r'[System.IO.Directory]::Move($backup, [System.IO.Path]::Combine($staging, "backup-failed-$build"))',
        ),
      );
      expect(script, contains(r"$keepNames += 'backup'"));
      final written = script.indexOf(
        r'Set-Content -LiteralPath $result -Value "$build $outcome"',
      );
      final exit = script.indexOf(
        r"if ($outcome -eq 'restore-failed') { exit 1 }",
      );
      final start = script.indexOf(r'[System.Diagnostics.Process]::Start(');
      expect(exit, greaterThan(written), reason: 'the result is written first');
      expect(start, greaterThan(exit), reason: 'never reached after it');
    });

    test('Windows: starts the app without wildcards ([ and ] in the path)', () {
      final script = UpdateLogic.windowsHelperScript(
        pid: 1,
        versionCode: 1240,
        source: 's',
        target: r'C:\Apps\a [b]',
        staging: 'st',
        exeName: 'LibrePili.exe',
      );
      expect(script, isNot(contains('Start-Process -FilePath')));
      expect(
        script,
        contains('New-Object System.Diagnostics.ProcessStartInfo'),
      );
      expect(
        script,
        contains(r'$start.FileName = [System.IO.Path]::Combine($target, $exe)'),
      );
      expect(script, contains(r'$start.WorkingDirectory = $target'));
      expect(
        script,
        contains(r'[System.Diagnostics.Process]::Start($start) | Out-Null'),
      );
      // the old app after a failure too, but not when it never exited
      expect(
        script,
        contains(r"if ($outcome -ne 'failed: the app did not exit') {"),
      );
    });

    test('Linux AppImage: replaced through a .new beside it', () {
      final script = UpdateLogic.linuxHelperScript(
        pid: 77,
        versionCode: 1240,
        staging: "/home/u/.local/share/x/it's/update",
        appImage: '/home/u/Apps/LibrePili.AppImage',
        newAppImage: '/home/u/.local/share/x/update/LibrePili.AppImage',
      );
      expect(script, startsWith('#!/bin/sh\n'));
      expect(script, contains('app_pid=77'));
      expect(
        script,
        contains(r"""staging='/home/u/.local/share/x/it'\''s/update'"""),
      );
      expect(script, contains(r'kill -0 "$app_pid"'));
      expect(script, contains(r'chmod +x "$app_image.new"'));
      expect(script, contains(r'mv -f "$app_image.new" "$app_image"'));
      expect(script, contains(r'nohup "$app_image"'));
      expect(script, contains("! -name 'result.txt'"));
      expect(script, contains("! -name 'failed-build.txt'"));
      expect(script, contains('build=1240'));
      expect(script, contains(r'echo "$build $outcome"'));
      // the .new is removed on a failure: the old file stays as it was
      expect(script, contains(r'rm -f "$app_image.new"'));
    });

    test('Linux tar.gz: copied over the bundle folder', () {
      final script = UpdateLogic.linuxHelperScript(
        pid: 77,
        versionCode: 1240,
        staging: '/home/u/.local/share/x/update',
        source: '/home/u/.local/share/x/update/extracted',
        target: '/home/u/librepili',
        exeName: 'librepili',
      );
      final backup = script.indexOf(
        r'cp -Pp "$target/$f" "$backup/$f" || exit 1',
      );
      final copy = script.indexOf(r'if cp -Rf "$source"/. "$target"/; then');
      final noted = script.indexOf(
        r"printf '%s\n' "
        r'"$f" >> "$added" || exit 1',
      );
      final removed = script.indexOf(r'rm -f "$target/$f" || restored=0');
      final restore = script.indexOf(
        r'cp -Rf "$backup"/. "$target"/ || restored=0',
      );
      expect(backup, greaterThan(0));
      expect(noted, greaterThan(0));
      expect(copy, greaterThan(backup), reason: 'backed up before copying');
      expect(copy, greaterThan(noted), reason: 'added files noted first');
      expect(removed, greaterThan(copy), reason: 'only after a failed copy');
      expect(restore, greaterThan(removed));
      expect(script, contains(r'done < "$added"'));
      expect(script, contains("outcome='failed: backup'"));
      expect(script, contains("outcome='restore-failed'"));
      // a failed restore: the backup kept, the result written, no start
      final kept = script.indexOf(
        r'mv "$staging/backup" "$staging/$kept" 2>/dev/null || kept=backup',
      );
      final written = script.indexOf(r'echo "$build restore-failed" >');
      final exit = script.indexOf('exit 1\nfi\nfind "\$staging"');
      final start = script.indexOf(
        r'nohup "$target"/'
        "'librepili'",
      );
      expect(kept, greaterThan(restore));
      expect(written, greaterThan(kept));
      expect(exit, greaterThan(written));
      expect(start, greaterThan(exit));
      expect(
        script,
        contains(
          "kept='backup-failed-'"
          r'"$build"',
        ),
      );
      expect(
        script,
        contains(
          r"! -name 'backup-failed-*' ! -name "
          r'"$kept"',
        ),
      );
      expect(script, contains("target='/home/u/librepili'"));
      expect(script, contains(r"""nohup "$target"/'librepili'"""));
      expect(script, isNot(contains('app_image')));
    });
  });
}
