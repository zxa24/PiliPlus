import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/piece_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The store of stream pieces on disk: what it keeps, what it lets go
/// first, and what survives a restart.
void main() {
  late Directory dir;
  final uri = Uri.parse(
    'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/1/2/3-1-100026.m4s',
  );
  final key = PieceStore.keyOf(uri);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('store');
  });

  tearDown(() async {
    await dir.delete(recursive: true).catchError((_) => dir);
  });

  Uint8List bytes(int n, int seed) =>
      Uint8List.fromList(List.generate(n, (i) => (i + seed) & 0xff));

  Future<PieceStore> open(int maxBytes) async {
    final store = PieceStore(dir, maxBytes: maxBytes);
    await store.open();
    return store;
  }

  test('the same file on another host is the same stream', () {
    expect(
      PieceStore.keyOf(
        Uri.parse(
          'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/1/2/3-1-100026.m4s?e=y',
        ),
      ),
      key,
    );
  });

  test('past the limit, the piece least lately used goes first', () async {
    final store = await open(3000);
    await store.sized(key, uri, 100000, 'video/mp4');
    await store.write(key, 0, bytes(1000, 0));
    await store.write(key, 1000, bytes(1000, 1));
    await store.write(key, 2000, bytes(1000, 2));
    // the first read again: the second is now the oldest
    expect(await store.read(key, 10, 5), bytes(1000, 0).sublist(10, 15));
    await store.write(key, 3000, bytes(1000, 3));
    expect(store.bytes, 3000);
    expect(await store.read(key, 1500, 1), isNull);
    expect(await store.read(key, 0, 1), isNotNull);
    expect(await store.read(key, 3999, 1), bytes(1000, 3).sublist(999));
  });

  test('a restart reads it all back, the order of use too', () async {
    final first = await open(1 << 20);
    await first.sized(key, uri, 100000, 'video/mp4');
    await first.write(key, 0, bytes(1000, 0));
    await first.write(key, 1000, bytes(1000, 1));
    // a moment, for the files' times to differ
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await first.read(key, 0, 1);

    final second = await open(1 << 20);
    expect(second.meta(key), (size: 100000, type: 'video/mp4'));
    expect(second.bytes, 2000);
    // lowered before anything is read: the piece used longest ago in the
    // first session (the second one) goes, the one read last stays
    second.maxBytes = 1000;
    await second.trim();
    expect(second.bytes, 1000);
    expect(await second.read(key, 1500, 1), isNull);
    expect(await second.read(key, 0, 1000), bytes(1000, 0));
  });

  test('a file gone from under it (the folder cleared) is forgotten', () async {
    final store = await open(1 << 20);
    await store.sized(key, uri, 100000, null);
    await store.write(key, 0, bytes(1000, 0));
    await File('${dir.path}/$key/0-1000').delete();
    expect(await store.read(key, 0, 10), isNull);
    expect(store.bytes, 0);
  });

  test('a limit of 0 keeps nothing', () async {
    final store = await open(0);
    await store.sized(key, uri, 100000, null);
    await store.write(key, 0, bytes(1000, 0));
    expect(store.bytes, 0);
    expect(await store.read(key, 0, 10), isNull);
  });

  test(
    'pieces that overlap: a byte is read from the one starting last',
    () async {
      final store = await open(1 << 20);
      await store.sized(key, uri, 100000, null);
      await store.write(key, 0, bytes(1000, 0));
      await store.write(key, 600, bytes(1000, 50));
      expect(await store.read(key, 700, 3), bytes(1000, 50).sublist(100, 103));
      expect(await store.read(key, 100, 3), bytes(1000, 0).sublist(100, 103));
      // only up to the end of the piece it is read from
      expect((await store.read(key, 500, 5000))!.length, 500);
    },
  );
}
