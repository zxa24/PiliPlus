// LibrePili: an `entry.json` read and saved again by the download service's
// own paths (design feature-logs/download-platforms/design.md, AC1 记录).
// The expected files under test/fixtures/download/expected were written by
// this code once, looked over, and are not to be regenerated: a change in
// the encoder, the file name or the tmp + rename shows up against them.
// Saving does not keep the input as it was: toJson orders the keys and
// drops fields this app does not know (the official client's entry).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'download_test_support.dart';

/// What the files made under it are asked to do, in order.
final class _FileLog extends IOOverrides {
  final events = <String>[];

  @override
  File createFile(String path) => _LoggedFile(super.createFile(path), events);
}

class _LoggedFile implements File {
  _LoggedFile(this._file, this._events);

  final File _file;
  final List<String> _events;

  String get _name => p.basename(_file.path);

  @override
  String get path => _file.path;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    _events.add('write $_name');
    await _file.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
    _events.add('written $_name');
    return this;
  }

  @override
  Future<File> rename(String newPath) async {
    final to = p.basename(newPath);
    _events.add('rename $_name -> $to');
    final renamed = await _file.rename(newPath);
    _events.add('renamed $_name -> $to');
    return _LoggedFile(renamed, _events);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not logged: ${invocation.memberName}');
}

void main() {
  late Directory storage;
  final h = DownloadHarness();

  setUpAll(() async => storage = await initDownloadStorage());
  tearDownAll(() => closeDownloadStorage(storage));
  tearDown(h.stop);

  const records = [recordUgc, recordPgc, recordOfficial];

  Future<void> start() => h.start(fixtures: recordFixtures, entries: records);

  test('read by the service and saved again: entry.json, no .tmp left, the '
      'expected bytes', () async {
    await start();
    expect(h.service.downloadList, hasLength(3));
    for (final record in records) {
      await h.service.saveEntryForTest(h.entry(record));
      final dir = Directory(p.join(h.root.path, record));
      expect(
        [
          for (final f in dir.listSync())
            if (p.basename(f.path).startsWith('entry')) p.basename(f.path),
        ],
        ['entry.json'],
        reason: record,
      );
      expect(
        File(p.join(dir.path, 'entry.json')).readAsBytesSync(),
        File(p.join(recordExpected, record, 'entry.json')).readAsBytesSync(),
        reason: record,
      );
    }
  });

  test('saved through entry.json.tmp and a rename, never written in '
      'place', () async {
    await start();
    final ugc = h.entry(recordUgc);
    final log = _FileLog();
    await IOOverrides.runWithIOOverrides(
      () => h.service.saveEntryForTest(ugc),
      log,
    );
    expect(log.events, [
      'write entry.json.tmp',
      'written entry.json.tmp',
      'rename entry.json.tmp -> entry.json',
      'renamed entry.json.tmp -> entry.json',
    ]);
  });

  test('two saves of one entry at once: one after the other, the newer '
      'state last', () async {
    await start();
    final ugc = h.entry(recordUgc);
    final log = _FileLog();
    await IOOverrides.runWithIOOverrides(() async {
      ugc.totalBytes = 1;
      final first = h.service.saveEntryForTest(ugc);
      ugc.totalBytes = 2;
      final second = h.service.saveEntryForTest(ugc);
      await Future.wait([first, second]);
    }, log);

    List<int> at(String event) => [
      for (final (i, e) in log.events.indexed)
        if (e == event) i,
    ];
    final writes = at('write entry.json.tmp');
    final renames = at('renamed entry.json.tmp -> entry.json');
    expect(writes, hasLength(2));
    expect(renames, hasLength(2));
    expect(writes[1], greaterThan(renames[0]));
    expect(readEntryJson(h.root.path, recordUgc)['total_bytes'], 2);
  });
}
