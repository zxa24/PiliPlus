// LibrePili (review of 2b/2c): a YouTube record the list read from its
// `.tmp` — a lone `entry.librepili.json.tmp` (a save cut before its
// rename), or a valid `.tmp` beside a record that does not read — is the
// only readable copy. The next save must not truncate it: the save makes it
// the record first, so a save cut at its write still leaves a readable
// record. The orphan check counts the `.tmp` as a record (hasRecord), and a
// record's `stream_tag` is kept only when it is a stream folder's name
// (it is joined into a path deleted recursively).
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/download/download_platform.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'yt_download_test_support.dart';

/// Every `entry.librepili.json.tmp` made in its zone is cut at its write:
/// truncated, then the write fails (a crash or a full disk at that point).
final class _CutWrites extends IOOverrides {
  @override
  File createFile(String file) {
    final made = super.createFile(file);
    return file.endsWith('${YtDownloadEntry.recordFile}.tmp')
        ? _CutTmp(made)
        : made;
  }
}

class _CutTmp implements File {
  _CutTmp(this._file);

  final File _file;

  @override
  String get path => _file.path;

  @override
  bool existsSync() => _file.existsSync();

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _file.writeAsStringSync('');
    return Future.error(const FileSystemException('cut at the write'));
  }

  @override
  Future<File> rename(String newPath) => _file.rename(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoHost extends Fake implements DownloadHost {}

void main() {
  late Directory root;
  late YtDownloadPlatform platform;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yt-recovery-');
    platform = YtDownloadPlatform(_NoHost());
  });
  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  File recordOf(YtDownloadEntry e) =>
      File(path.join(e.entryDirPath, YtDownloadEntry.recordFile));
  File tmpOf(YtDownloadEntry e) => File('${recordOf(e).path}.tmp');

  /// A record as the list would take it from [dir]: the record, else the
  /// `.tmp` (as the service reads).
  YtDownloadEntry? listed(YtDownloadEntry e) {
    for (final f in [recordOf(e), tmpOf(e)]) {
      try {
        return YtDownloadEntry.fromJson(
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    return null;
  }

  Future<void> cutSave(YtDownloadEntry e) => IOOverrides.runWithIOOverrides(
    () async {
      await expectLater(platform.save(e), throwsA(isA<FileSystemException>()));
    },
    _CutWrites(),
  );

  test(
    'a lone .tmp: a save cut at its write leaves a readable record',
    () async {
      final e = ytEntry(root);
      writeYtRecord(root, e, tmpOnly: true);
      expect(listed(e)?.videoId, ytId);
      await cutSave(e..downloadedBytes = 5);
      expect(listed(e)?.videoId, ytId);
      expect(recordOf(e).existsSync(), isTrue);
    },
  );

  test('a record that does not read and a valid .tmp: the same', () async {
    final e = ytEntry(root);
    writeYtRecord(root, e, tmpOnly: true);
    recordOf(e).writeAsStringSync('{"format": ');
    await cutSave(e);
    expect(listed(e)?.videoId, ytId);
  });

  test('a readable record: a cut save leaves it as it was', () async {
    final e = ytEntry(root);
    writeYtRecord(root, e);
    final before = recordOf(e).readAsStringSync();
    await cutSave(e..downloadedBytes = 5);
    expect(recordOf(e).readAsStringSync(), before);
  });

  test('a save that is not cut: the record, no .tmp left', () async {
    final e = ytEntry(root);
    writeYtRecord(root, e, tmpOnly: true);
    await platform.save(e..downloadedBytes = 7);
    expect(tmpOf(e).existsSync(), isFalse);
    expect(
      (jsonDecode(recordOf(e).readAsStringSync()) as Map)['downloaded_bytes'],
      7,
    );
  });

  test('hasRecord: the record or its .tmp; neither: none', () {
    final e = ytEntry(root);
    Directory(e.entryDirPath).createSync(recursive: true);
    expect(platform.hasRecord(e), isFalse);
    writeYtRecord(root, e, tmpOnly: true);
    expect(platform.hasRecord(e), isTrue);
    tmpOf(e).renameSync(recordOf(e).path);
    expect(platform.hasRecord(e), isTrue);
  });

  test('stream_tag: kept only when it is a stream folder\'s name', () {
    final good = ytEntry(root).toJson();
    for (final (tag, kept) in [
      ('137-140', true),
      ('137-140.3809de5ce6c5', true),
      ('137-140.3809de5ce6c5.drc', true),
      ('137-140.drc', true),
      ('', false),
      ('0', false),
      ('..', false),
      ('../137-140', false),
      (r'C:\Windows', false),
      ('/tmp/x', false),
      ('137-140/..', false),
      ('137-140.3809DE5CE6C5', false),
    ]) {
      final e = YtDownloadEntry.fromJson({...good, 'stream_tag': tag});
      expect(e.streamTag, kept ? tag : isNull, reason: tag);
      expect(e.streamTypeTag, kept ? tag : '0', reason: tag);
    }
    expect(
      YtDownloadEntry.fromJson({...good, 'stream_tag': 7}).streamTag,
      isNull,
    );
  });

  test('a folder name with an itag no int holds: no pin, no match', () {
    const huge = '99999999999999999999999-140';
    expect(YtStreamTag.pinOf(huge), isNull);
    final f = YtFormat({
      'itag': 140,
      'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
      'url': 'https://example.invalid/140',
    });
    expect(YtStreamTag.matches(huge, f, f), isFalse);
  });
}
