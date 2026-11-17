// LibrePili: writeTextAtomic (YouTube extras review 1, c3/l4; used by both
// platforms' extras): the file is replaced whole, and a write that fails
// leaves the old file as it was and no `.part`.
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/atomic_text_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('atomic-'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  List<String> names() =>
      dir.listSync().map((e) => path.basename(e.path)).toList()..sort();

  test('writes, and replaces what is there', () async {
    final f = File(path.join(dir.path, 'a.srt'));
    await writeTextAtomic(f, 'one');
    await writeTextAtomic(f, 'two');
    expect(f.readAsStringSync(), 'two');
    expect(names(), ['a.srt']);
  });

  test('replace false: a file there is left as it is, no .part', () async {
    final f = File(path.join(dir.path, 'c.srt'))..writeAsStringSync('theirs');
    expect(await writeTextAtomic(f, 'ours', replace: false), isFalse);
    expect(f.readAsStringSync(), 'theirs');
    expect(names(), ['c.srt']);
    final g = File(path.join(dir.path, 'd.srt'));
    expect(await writeTextAtomic(g, 'ours', replace: false), isTrue);
    expect(g.readAsStringSync(), 'ours');
  });

  // review 4, P1: the name is reserved before the rename
  test('replace false: a file that appears before the name is reserved is '
      'kept, no .part, no reservation left', () async {
    final f = File(path.join(dir.path, 'e.srt'));
    final kept = await IOOverrides.runWithIOOverrides(
      () => writeTextAtomic(f, 'ours', replace: false),
      _AppearsAfterPart(f.path),
    );
    expect(kept, isFalse);
    expect(f.readAsStringSync(), 'theirs');
    expect(names(), ['e.srt']);
  });

  test('replace false: the name is held by an empty file of ours while the '
      'text is renamed over it', () async {
    final f = File(path.join(dir.path, 'g.srt'));
    var heldEmpty = false;
    await IOOverrides.runWithIOOverrides(
      () => writeTextAtomic(f, 'ours', replace: false),
      _AtRename(() => heldEmpty = File(f.path).lengthSync() == 0),
    );
    expect(heldEmpty, isTrue);
    expect(f.readAsStringSync(), 'ours');
  });

  test('a rename that cannot happen: an error, no .part left', () async {
    // a folder where the file would go: the rename is refused
    Directory(path.join(dir.path, 'b.json')).createSync();
    await expectLater(
      writeTextAtomic(File(path.join(dir.path, 'b.json')), '{}'),
      throwsA(isA<FileSystemException>()),
    );
    expect(names(), ['b.json']);
    expect(FileSystemEntity.isDirectorySync(path.join(dir.path, 'b.json')), isTrue);
  });
}

/// Another program creates [dest] once the `.part` beside it is written:
/// before the name is reserved.
final class _AppearsAfterPart extends IOOverrides {
  _AppearsAfterPart(this.dest);

  final String dest;

  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path == '$dest.part' ? _PartThen(real, dest) : real;
  }
}

class _PartThen implements File {
  _PartThen(this._real, this._dest);

  final File _real;
  final String _dest;

  @override
  String get path => _real.path;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await _real.writeAsString(contents, flush: flush);
    // a plain write, as another program's
    await File(_dest).writeAsString('theirs');
    return this;
  }

  @override
  bool existsSync() => _real.existsSync();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);

  @override
  Future<File> rename(String newPath) => _real.rename(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_PartThen.${invocation.memberName}');
}

/// [onRename] is called as the `.part` is renamed.
final class _AtRename extends IOOverrides {
  _AtRename(this.onRename);

  final void Function() onRename;

  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path.endsWith('.part') ? _RenameWatch(real, onRename) : real;
  }
}

class _RenameWatch implements File {
  _RenameWatch(this._real, this._onRename);

  final File _real;
  final void Function() _onRename;

  @override
  String get path => _real.path;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => _real.writeAsString(contents, flush: flush);

  @override
  bool existsSync() => _real.existsSync();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);

  @override
  Future<File> rename(String newPath) {
    _onRename();
    return _real.rename(newPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_RenameWatch.${invocation.memberName}');
}
