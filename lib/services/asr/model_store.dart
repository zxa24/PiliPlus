/// LibrePili: fetching, verifying and keeping the on-device ASR models.
///
/// The models live in the app's **support** directory, not the cache: the OS
/// reclaims caches under pressure and re-downloading 240 MB because the phone
/// wanted 240 MB back is not acceptable. They are the user's data, they are
/// deleted only when the user says so.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

class AsrCancelled implements Exception {
  const AsrCancelled();
  @override
  String toString() => 'AsrCancelled';
}

class AsrModelException implements Exception {
  const AsrModelException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() =>
      cause == null ? 'AsrModelException: $message' : '$message ($cause)';
}

class AsrCancelToken {
  var _cancelled = false;
  final _onCancel = <VoidCallback>[];

  bool get isCancelled => _cancelled;

  /// Runs every registered teardown. A download blocked on a socket that has
  /// stopped delivering cannot notice a flag — the only way out is to close
  /// the connection under it.
  void cancel() {
    _cancelled = true;
    for (final callback in _onCancel) {
      try {
        callback();
      } catch (_) {}
    }
    _onCancel.clear();
  }

  void _register(VoidCallback callback) {
    if (_cancelled) {
      callback();
    } else {
      _onCancel.add(callback);
    }
  }

  void _unregister(VoidCallback callback) => _onCancel.remove(callback);

  void throwIfCancelled() {
    if (_cancelled) throw const AsrCancelled();
  }
}

/// Bytes so far against the whole job, measured in *unpacked* size so the bar
/// does not jump when a source switches between a raw file and a tarball.
typedef AsrProgress = ({
  String label,
  int received,
  int total,
  bool verifying,
});

class AsrModelStore {
  AsrModelStore({Directory? root}) : _rootOverride = root;

  /// Tests point this at a scratch directory; in the app it is null.
  final Directory? _rootOverride;

  static const _userAgent = 'LibrePili';

  /// A connection that delivers nothing for this long is treated as dead.
  ///
  /// Without it a stalled socket hangs the download for ever: a phone sat on
  /// "100%" for minutes on a 315 KB file that the other phone had already
  /// fetched, and cancelling did nothing either, because the flag is only
  /// read between chunks and no chunk was coming.
  static Duration _idleTimeout = const Duration(seconds: 30);

  /// Tests cannot wait 30 s for a stall.
  @visibleForTesting
  static set debugIdleTimeout(Duration value) => _idleTimeout = value;

  /// One retry of the same source before falling back to the next one —
  /// a stall is usually transient, and the partial file resumes.
  static const _attemptsPerSource = 2;

  Directory get root =>
      _rootOverride ?? Directory(path.join(appSupportDirPath, 'asr'));

  Directory dirOf(AsrModel model) =>
      Directory(path.join(root.path, model.id));

  File fileOf(AsrModel model, AsrModelFile file) =>
      File(path.join(dirOf(model).path, file.name));

  /// Installed = present and exactly the right length.
  ///
  /// The hash is checked when a file is installed, not on every launch: a
  /// 240 MB SHA-256 at startup would cost a second of CPU to catch something
  /// that does not happen on its own. A file that rots anyway fails at model
  /// load, and that path offers a re-download.
  bool isInstalled(AsrModel model) => model.files.every((file) {
    final stat = fileOf(model, file).statSync();
    return stat.type == FileSystemEntityType.file && stat.size == file.size;
  });

  bool get isReady => AsrModelCatalog.required.every(isInstalled);

  List<AsrModel> get missing =>
      [for (final m in AsrModelCatalog.required) if (!isInstalled(m)) m];

  /// What the user would free by deleting everything, including half-finished
  /// downloads.
  int installedBytes() {
    if (!root.existsSync()) return 0;
    return root
        .listSync(recursive: true)
        .whereType<File>()
        .fold(0, (sum, f) => sum + f.lengthSync());
  }

  Future<void> remove(AsrModel model) async {
    final dir = dirOf(model);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  Future<void> removeAll() async {
    if (root.existsSync()) await root.delete(recursive: true);
  }

  /// Installs everything [AsrModelCatalog.required] lists and is not already
  /// here. Safe to call when everything is present: it does nothing.
  Future<void> ensureAll({
    ValueChanged<AsrProgress>? onProgress,
    AsrCancelToken? token,
  }) async {
    final pending = missing;
    if (pending.isEmpty) return;
    final total = pending.fold(0, (sum, m) => sum + m.totalSize);
    var done = 0;
    for (final model in pending) {
      await ensure(
        model,
        token: token,
        onProgress: onProgress == null
            ? null
            : (p) => onProgress((
                label: p.label,
                received: done + p.received,
                total: total,
                verifying: p.verifying,
              )),
      );
      done += model.totalSize;
    }
  }

  Future<void> ensure(
    AsrModel model, {
    ValueChanged<AsrProgress>? onProgress,
    AsrCancelToken? token,
  }) async {
    final pending = [
      for (final file in model.files)
        if (!_fileInstalled(model, file)) file,
    ];
    if (pending.isEmpty) return;
    await dirOf(model).create(recursive: true);

    final total = pending.fold(0, (sum, f) => sum + f.size);
    var done = 0;
    void report(AsrModelFile file, int received, {bool verifying = false}) {
      onProgress?.call((
        label: '${model.label} · ${file.name}',
        received: done + received,
        total: total,
        verifying: verifying,
      ));
    }

    while (pending.isNotEmpty) {
      token?.throwIfCancelled();
      final file = pending.first;
      Object? lastError;
      var installed = <AsrModelFile>[];
      outer:
      for (final source in file.sources) {
        for (var attempt = 0; attempt < _attemptsPerSource; attempt++) {
          try {
            installed = source.archive == AsrArchive.none
                ? [await _installDirect(model, file, source, report, token)]
                : await _installFromArchive(
                    model,
                    source,
                    pending,
                    report,
                    token,
                  );
            break outer;
          } on AsrCancelled {
            rethrow;
          } catch (e) {
            lastError = e;
            if (kDebugMode) {
              debugPrint('asr: ${source.url} failed (try $attempt): $e');
            }
          }
        }
      }
      if (installed.isEmpty) {
        throw AsrModelException('${file.name} 下载失败', lastError);
      }
      for (final got in installed) {
        pending.remove(got);
        done += got.size;
      }
    }
  }

  bool _fileInstalled(AsrModel model, AsrModelFile file) {
    final stat = fileOf(model, file).statSync();
    return stat.type == FileSystemEntityType.file && stat.size == file.size;
  }

  /// Installs a file the user downloaded by hand. Same hash gate as a
  /// download: a wrong file is rejected rather than half-working later.
  Future<AsrModelFile> importFile(
    File source, {
    List<AsrModel> models = AsrModelCatalog.required,
  }) async {
    for (final model in models) {
      for (final file in model.files) {
        if (path.basename(source.path) != file.name) continue;
        if (await source.length() != file.size) continue;
        final hash = await _hashFile(source.path);
        if (hash != file.sha256) continue;
        await dirOf(model).create(recursive: true);
        await source.copy(fileOf(model, file).path);
        return file;
      }
    }
    throw const AsrModelException('这个文件不是需要的模型文件（名称、大小或校验值不符）');
  }

  Future<AsrModelFile> _installDirect(
    AsrModel model,
    AsrModelFile file,
    AsrSource source,
    void Function(AsrModelFile, int, {bool verifying}) report,
    AsrCancelToken? token,
  ) async {
    final target = fileOf(model, file);
    final part = File('${target.path}.part');
    await _download(source.url, part, file.size, (received) {
      report(file, received);
    }, token);
    await _verifyAndPlace(part, target, file, report);
    return file;
  }

  /// Upstream publishes some files only inside a tarball. Extract every
  /// pending file that shares this archive in one pass — downloading 163 MB
  /// once per file would be absurd.
  Future<List<AsrModelFile>> _installFromArchive(
    AsrModel model,
    AsrSource source,
    List<AsrModelFile> pending,
    void Function(AsrModelFile, int, {bool verifying}) report,
    AsrCancelToken? token,
  ) async {
    final wanted = <String, AsrModelFile>{};
    for (final file in pending) {
      for (final candidate in file.sources) {
        if (candidate.url == source.url &&
            candidate.archive == source.archive &&
            candidate.entry != null) {
          wanted[candidate.entry!] = file;
        }
      }
    }
    if (wanted.isEmpty) return const [];

    final tmp = Directory(path.join(dirOf(model).path, '.tmp'));
    await tmp.create(recursive: true);
    final first = wanted.values.first;
    try {
      final archive = File(path.join(tmp.path, 'download'));
      await _download(source.url, archive, source.archiveSize, (received) {
        report(first, received.clamp(0, first.size));
      }, token);

      token?.throwIfCancelled();
      final tar = File(path.join(tmp.path, 'archive.tar'));
      report(first, first.size, verifying: true);
      await Isolate.run(() => _bunzip2(archive.path, tar.path));

      token?.throwIfCancelled();
      final input = InputFileStream(tar.path);
      final got = <AsrModelFile>[];
      try {
        // storeData keeps each entry's content as a slice of the file-backed
        // input stream, not in memory: the 239 MB member is never held whole
        final entries = TarDecoder().decodeStream(input);
        for (final entry in entries.files) {
          final file = wanted[entry.name];
          if (file == null || !entry.isFile) continue;
          final part = File(path.join(tmp.path, '${file.name}.part'));
          final out = OutputFileStream(part.path);
          try {
            entry.writeContent(out);
          } finally {
            await out.close();
          }
          await _verifyAndPlace(part, fileOf(model, file), file, report);
          got.add(file);
        }
      } finally {
        await input.close();
      }
      if (got.length != wanted.length) {
        throw AsrModelException(
          '压缩包里缺少需要的文件：'
          '${wanted.keys.where((e) => !got.any((f) => wanted[e] == f)).join(', ')}',
        );
      }
      return got;
    } finally {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    }
  }

  Future<void> _verifyAndPlace(
    File part,
    File target,
    AsrModelFile file,
    void Function(AsrModelFile, int, {bool verifying}) report,
  ) async {
    final size = await part.length();
    if (size != file.size) {
      await part.delete();
      throw AsrModelException('${file.name} 大小不符（$size ≠ ${file.size}）');
    }
    report(file, file.size, verifying: true);
    final hash = await _hashFile(part.path);
    if (hash != file.sha256) {
      await part.delete();
      throw AsrModelException('${file.name} 校验值不符');
    }
    if (target.existsSync()) await target.delete();
    await part.rename(target.path);
  }

  /// Plain HTTPS with resume. Deliberately its own client: these are GitHub
  /// URLs and must carry none of the app's cookies, account headers or
  /// Bilibili-shaped UA.
  Future<void> _download(
    String url,
    File target,
    int? expected,
    ValueChanged<int> onReceived,
    AsrCancelToken? token,
  ) async {
    var have = target.existsSync() ? await target.length() : 0;
    if (expected != null && have >= expected) {
      // a complete .part from an interrupted verify: let the caller check it
      onReceived(have);
      return;
    }

    final client = HttpClient()
      ..userAgent = _userAgent
      ..connectionTimeout = const Duration(seconds: 30);
    void abort() => client.close(force: true);
    token?._register(abort);
    try {
      final request = await client.getUrl(Uri.parse(url));
      if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
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
          throw const AsrModelException('续传范围无效，请重试');
        default:
          throw AsrModelException('HTTP ${response.statusCode}');
      }

      final sink = target.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      var received = have;
      try {
        await for (final chunk in response.timeout(_idleTimeout)) {
          if (token?.isCancelled ?? false) throw const AsrCancelled();
          sink.add(chunk);
          received += chunk.length;
          onReceived(received);
        }
      } finally {
        await sink.close();
      }
      if (expected != null && received != expected) {
        throw AsrModelException('下载不完整（$received / $expected）');
      }
    } finally {
      token?._unregister(abort);
      client.close(force: true);
    }
  }

  /// Hashing 240 MB blocks for about a second; keep it off the UI isolate.
  static Future<String> _hashFile(String filePath) =>
      Isolate.run(() => _hashFileSync(filePath));

  static Future<String> _hashFileSync(String filePath) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in File(filePath).openRead()) {
      input.add(chunk);
    }
    input.close();
    return sink.value.toString();
  }

  static void _bunzip2(String from, String to) {
    final input = InputFileStream(from);
    final output = OutputFileStream(to);
    try {
      if (!BZip2Decoder().decodeStream(input, output)) {
        throw const AsrModelException('压缩包解压失败');
      }
    } finally {
      input.closeSync();
      output.closeSync();
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
