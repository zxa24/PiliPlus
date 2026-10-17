import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every picture after a moment, counting how many are asked at
/// once.
class _Images implements HttpClientAdapter {
  final asked = <String>[];
  int running = 0;
  int peak = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    asked.add(options.uri.toString());
    running++;
    peak = math.max(peak, running);
    await Future.delayed(const Duration(milliseconds: 20));
    running--;
    return ResponseBody.fromBytes([1, 2, 3], 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final images = _Images();
  late Directory folder;

  setUpAll(() => Request.dio = Dio()..httpClientAdapter = images);

  setUp(() {
    images
      ..asked.clear()
      ..peak = 0;
    folder = Directory.systemTemp.createTempSync('comment_images');
  });

  tearDown(() => folder.deleteSync(recursive: true));

  String url(int i) => 'https://i0.hdslb.com/bfs/emote/$i.png';

  test('a few at a time, all of them saved, in the order asked', () async {
    final saving = CommentImages(folder.path);
    final paths = await Future.wait([
      for (var i = 0; i < 20; i++) saving.save(url(i)),
    ]);
    expect(images.peak, CommentImages.parallel);
    expect(images.asked, hasLength(20));
    expect(saving.saved, 20);
    for (final (i, p) in paths.indexed) {
      expect(p, isNotNull);
      expect(File('${folder.path}/$p').existsSync(), isTrue, reason: url(i));
    }
  });

  test('one picture asked twice at once: fetched once', () async {
    final saving = CommentImages(folder.path);
    final both = await Future.wait([saving.save(url(1)), saving.save(url(1))]);
    expect(both[0], both[1]);
    expect(images.asked, hasLength(1));
  });

  test('cancelled: the waiting ones are not fetched, and settled() is the '
      'end of the writing', () async {
    var cancelled = false;
    final saving = CommentImages(folder.path, cancelled: () => cancelled);
    final all = [for (var i = 0; i < 20; i++) saving.save(url(i))];
    cancelled = true;
    await saving.settled();
    expect(images.asked, hasLength(CommentImages.parallel));
    final paths = await Future.wait(all);
    expect(paths.whereType<String>(), hasLength(CommentImages.parallel));
    expect(
      folder.listSync(recursive: true).where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
  });
}
