import 'dart:async';
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

  // a stream whose folder went (its last piece let go) was never found
  // gone: asked for again, it waited for ever
  test('a stream let go of entirely can be kept again', () async {
    final store = await open(1000);
    final other = Uri.parse(
      'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/9/9/9-1-100026.m4s',
    );
    final otherKey = PieceStore.keyOf(other);
    await store.sized(key, uri, 100000, null);
    await store.write(key, 0, bytes(1000, 0));
    await store.sized(otherKey, other, 100000, null);
    // past the limit: the first stream's only piece goes, and its folder
    await store.write(otherKey, 0, bytes(1000, 1));
    expect(store.meta(key), isNull);
    await store
        .sized(key, uri, 100000, null)
        .timeout(const Duration(seconds: 5));
    expect(store.meta(key)?.size, 100000);
  });

  // audit F25 (user 2026-10-19 14B): writes and re-sizes of one stream are
  // serialised
  group('a re-size during a piece being renamed into place', () {
    tearDown(() => PieceStore.debugBeforeRename = null);

    test('waits for it, and none of the old size is left', () async {
      final store = await open(1 << 20);
      await store.sized(key, uri, 100000, null);
      final renaming = Completer<void>();
      final release = Completer<void>();
      PieceStore.debugBeforeRename = () {
        renaming.complete();
        return release.future;
      };
      final write = store.write(key, 0, bytes(1000, 0));
      await renaming.future;
      // another encode of the same stream, while the old piece is renamed
      var resized = false;
      final resize = store
          .sized(key, uri, 200000, null)
          .then((_) => resized = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(resized, isFalse, reason: 'waits for the rename');
      release.complete();
      await write;
      await resize;
      PieceStore.debugBeforeRename = null;
      expect(store.meta(key)?.size, 200000);
      expect(await store.read(key, 0, 10), isNull);
      await store.write(key, 2000, bytes(1000, 2));
      // and after a restart: nothing of the old size taken for the new
      final again = await open(1 << 20);
      expect(again.meta(key)?.size, 200000);
      expect(await again.read(key, 0, 10), isNull);
      expect(await again.read(key, 2000, 5), bytes(1000, 2).sublist(0, 5));
      expect(again.bytes, 1000);
    });

    test('a write of the old size still on disk is not kept', () async {
      final store = await open(1 << 20);
      await store.sized(key, uri, 100000, null);
      // the re-size takes its turn while the piece is still being written
      // (on Windows its folder is not all deleted then, and nothing is kept
      // of the stream this time; elsewhere the new size is)
      final write = store.write(key, 0, bytes(1000, 0));
      final resize = store.sized(key, uri, 200000, null);
      await (write, resize).wait;
      expect(store.meta(key)?.size, isNot(100000));
      expect(await store.read(key, 0, 10), isNull);
      final again = await open(1 << 20);
      expect(again.meta(key)?.size, isNot(100000));
      expect(await again.read(key, 0, 10), isNull);
    });

    test('clear waits for it too', () async {
      final store = await open(1 << 20);
      await store.sized(key, uri, 100000, null);
      final renaming = Completer<void>();
      final release = Completer<void>();
      PieceStore.debugBeforeRename = () {
        renaming.complete();
        return release.future;
      };
      final write = store.write(key, 0, bytes(1000, 0));
      await renaming.future;
      final clear = store.clear();
      release.complete();
      await write;
      await clear;
      PieceStore.debugBeforeRename = null;
      final again = await open(1 << 20);
      expect(again.meta(key), isNull);
      expect(again.bytes, 0);
    });
  });
}
