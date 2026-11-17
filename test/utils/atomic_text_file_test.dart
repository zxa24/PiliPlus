// LibrePili: writeTextAtomic (YouTube extras review 1, c3/l4; used by both
// platforms' extras): the file is replaced whole, and a write that fails
// leaves the old file as it was and no `.part`.
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
