/// LibrePili: the update's staging folder — the download, its check against
/// the release's digest, and the record the next launch applies from.
///
/// App-private (`<app support>/update`): on Android the FileProvider hands
/// the APK from there to the installer (res/xml/update_paths.xml).
library;

import 'dart:io';
import 'dart:isolate';

import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/utils/update/update_logic.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// How staging a release went.
enum UpdateStageOutcome {
  staged,
  alreadyStaged,

  /// the file's hash is not the release's digest: removed, not staged
  mismatch,

  /// the download did not finish (kept, it resumes next time)
  failed,

  /// another staging is under way
  busy,

  /// verified, but no longer wanted when it finished (检查更新 turned off,
  /// 禁用 SSL 证书验证 turned on): removed, not staged
  dropped,
}

abstract final class UpdateStage {
  static const _userAgent = 'LibrePili';

  /// A stalled socket must not hold the download for ever.
  static const _idleTimeout = Duration(seconds: 30);

  static bool _running = false;

  static void log(String message) => EventLog.add('update', message);

  /// The staged record in [dir] whose file is there at its size; null
  /// otherwise.
  static UpdateStaged? read(String dir) {
    try {
      final manifest = File(p.join(dir, UpdateStaged.manifestName));
      if (!manifest.existsSync()) return null;
      final staged = UpdateStaged.decode(manifest.readAsStringSync());
      if (staged == null) return null;
      final file = File(p.join(dir, staged.asset));
      if (!file.existsSync() || file.lengthSync() != staged.size) return null;
      return staged;
    } catch (_) {
      return null;
    }
  }

  /// The staged file's path.
  static String fileOf(String dir, UpdateStaged staged) =>
      p.join(dir, staged.asset);

  /// What clearing the staging folder keeps: the helper's last word, the
  /// record of a build that failed to go in place or that the user skipped,
  /// and a backup the helper could not put back (the user's to deal with).
  static bool _kept(String path) {
    final name = p.basename(path);
    return name == UpdateStaged.resultName ||
        name == UpdateStaged.failedName ||
        name == UpdateStaged.skippedName ||
        name.startsWith(UpdateStaged.keptBackupPrefix);
  }

  /// Removes everything in [dir] but [_kept] (the folder stays). [why] goes
  /// to the log.
  static Future<void> discard(String dir, String why) async {
    try {
      final folder = Directory(dir);
      if (!folder.existsSync()) return;
      var any = false;
      await for (final e in folder.list(followLinks: false)) {
        if (_kept(e.path)) continue;
        any = true;
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
      if (any) log('staging cleared: $why');
    } catch (e) {
      log('staging not cleared ($why): $e');
    }
  }

  /// The helper's word on the last apply ([UpdateStaged.resultName]), read
  /// once and removed.
  static String? takeResult(String dir) {
    try {
      final file = File(p.join(dir, UpdateStaged.resultName));
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync().trim();
      file.deleteSync();
      return text;
    } catch (_) {
      return null;
    }
  }

  /// The build that last failed to go in place ([UpdateStaged.failedName]).
  static int? failedBuild(String dir) {
    try {
      final file = File(p.join(dir, UpdateStaged.failedName));
      if (!file.existsSync()) return null;
      return int.tryParse(file.readAsStringSync().trim());
    } catch (_) {
      return null;
    }
  }

  /// Remembers [code] as a build that failed to go in place.
  static void recordFailed(String dir, int code) {
    try {
      Directory(dir).createSync(recursive: true);
      File(p.join(dir, UpdateStaged.failedName)).writeAsStringSync('$code');
      log('build $code failed to go in place: not downloaded again by itself');
    } catch (_) {}
  }

  /// The build the user skipped ([UpdateStaged.skippedName]).
  static int? skippedBuild(String dir) {
    try {
      final file = File(p.join(dir, UpdateStaged.skippedName));
      if (!file.existsSync()) return null;
      return int.tryParse(file.readAsStringSync().trim());
    } catch (_) {
      return null;
    }
  }

  /// Remembers [code] as the build the user said not to be asked about.
  static void recordSkipped(String dir, int code) {
    try {
      Directory(dir).createSync(recursive: true);
      File(p.join(dir, UpdateStaged.skippedName)).writeAsStringSync('$code');
      log('build $code skipped by the user: not downloaded again by itself');
    } catch (_) {}
  }

  /// Lower-case hex SHA-256 of [filePath], off the UI isolate (a 100 MB zip
  /// takes a while).
  static Future<String> hashFile(String filePath) =>
      Isolate.run(() => hashFileSync(filePath));

  static Future<String> hashFileSync(String filePath) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in File(filePath).openRead()) {
      input.add(chunk);
    }
    input.close();
    return sink.value.toString();
  }

  /// Whether [filePath] hashes to [expected] (lower-case hex).
  static Future<bool> verify(String filePath, String expected) async {
    try {
      return await hashFile(filePath) == expected.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  /// Downloads [url] into [dir] as [staged] describes, resuming what an
  /// earlier start left, checks it against [UpdateStaged.sha256] and writes
  /// the record. Through a plain [HttpClient]: the app's [HttpOverrides]
  /// give it the 设置代理 setting as every other connection has; a GitHub
  /// URL carries none of the app's cookies or account headers.
  ///
  /// [stillWanted] is asked once more right before the record is written:
  /// the download may take minutes, and a setting changed meanwhile wins.
  static Future<UpdateStageOutcome> stage(
    String dir,
    String url,
    UpdateStaged staged, {
    bool Function()? stillWanted,
  }) async {
    if (_running) return UpdateStageOutcome.busy;
    _running = true;
    try {
      final already = read(dir);
      if (already != null &&
          already.sha256 == staged.sha256 &&
          already.asset == staged.asset) {
        return UpdateStageOutcome.alreadyStaged;
      }
      await Directory(dir).create(recursive: true);
      if (already != null) await discard(dir, 'replaced by ${staged.tag}');
      // a partial download is named by the hash it must reach: another
      // release's goes
      final partName = '${staged.sha256.substring(0, 16)}.part';
      await for (final e in Directory(dir).list(followLinks: false)) {
        final name = p.basename(e.path);
        if (name != partName && !_kept(e.path)) {
          try {
            await e.delete(recursive: true);
          } catch (_) {}
        }
      }
      final part = File(p.join(dir, partName));
      log(
        'downloading ${staged.asset} (${staged.tag})'
        '${part.existsSync() ? ', resuming at ${part.lengthSync()}' : ''}',
      );
      try {
        await _download(url, part, staged.size);
      } catch (e) {
        log('download of ${staged.asset} stopped: $e');
        return UpdateStageOutcome.failed;
      }
      if (!await verify(part.path, staged.sha256)) {
        log('${staged.asset} does not match the release digest: not staged');
        try {
          await part.delete();
        } catch (_) {}
        return UpdateStageOutcome.mismatch;
      }
      log('${staged.asset} verified (sha256 ${staged.sha256})');
      if (stillWanted != null && !stillWanted()) {
        log('${staged.asset} no longer wanted: not staged');
        try {
          await part.delete();
        } catch (_) {}
        return UpdateStageOutcome.dropped;
      }
      await part.rename(p.join(dir, staged.asset));
      final manifest = File(p.join(dir, UpdateStaged.manifestName));
      final tmp = File('${manifest.path}.tmp');
      await tmp.writeAsString(staged.encode(), flush: true);
      await tmp.rename(manifest.path);
      log('staged ${staged.tag} (${staged.kind.id})');
      return UpdateStageOutcome.staged;
    } finally {
      _running = false;
    }
  }

  static Future<void> _download(String url, File target, int expected) async {
    var have = target.existsSync() ? await target.length() : 0;
    if (expected > 0 && have > expected) {
      await target.delete();
      have = 0;
    }
    if (expected > 0 && have == expected) return;

    final client = HttpClient()
      ..userAgent = _userAgent
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(Uri.parse(url));
      if (have > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      }
      final response = await request.close();
      var append = false;
      switch (response.statusCode) {
        case HttpStatus.partialContent:
          append = true;
        case HttpStatus.ok:
          // the server ignored the range: start over rather than splice
          have = 0;
        case HttpStatus.requestedRangeNotSatisfiable:
          await target.delete();
          throw const HttpException('range not satisfiable');
        default:
          throw HttpException('HTTP ${response.statusCode}');
      }
      final sink = target.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      var received = have;
      try {
        await for (final chunk in response.timeout(_idleTimeout)) {
          sink.add(chunk);
          received += chunk.length;
        }
      } finally {
        await sink.close();
      }
      if (expected > 0 && received != expected) {
        throw HttpException('incomplete ($received / $expected)');
      }
    } finally {
      client.close(force: true);
    }
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
