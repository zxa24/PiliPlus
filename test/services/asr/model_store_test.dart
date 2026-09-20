import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// A local stand-in for the release host: serves fixed bodies, honours
/// `Range` unless told not to, and counts what it actually sent so a test can
/// prove a resume did not re-download the whole file.
class _Host {
  _Host(this.server);

  final HttpServer server;
  final Map<String, List<int>> bodies = {};
  final Set<String> missing = {};

  /// Sends the headers and a first chunk, then never anything again — the
  /// shape of the stall that hung a phone on a 315 KB file.
  final Set<String> stalling = {};
  var supportsRange = true;
  var bytesSent = 0;
  var requests = 0;

  static Future<_Host> start() async {
    final host = _Host(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    host.server.listen(host._handle);
    return host;
  }

  String url(String name) =>
      'http://127.0.0.1:${server.port}/$name';

  Future<void> _handle(HttpRequest request) async {
    requests++;
    final name = request.uri.path.substring(1);
    final body = bodies[name];
    if (body == null || missing.contains(name)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    var from = 0;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null && supportsRange) {
      from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (from >= body.length) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await request.response.close();
        return;
      }
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $from-${body.length - 1}/${body.length}',
        );
    }
    final slice = body.sublist(from);
    if (stalling.contains(name)) {
      request.response.add(slice.take(1).toList());
      await request.response.flush();
      // deliberately never closed
      return;
    }
    bytesSent += slice.length;
    request.response.add(slice);
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

AsrModelFile _file(String name, List<int> body, List<AsrSource> sources) =>
    AsrModelFile(
      name: name,
      size: body.length,
      sha256: _sha(body),
      sources: sources,
    );

void main() {
  late Directory root;
  late _Host host;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('asr_store_test');
    host = await _Host.start();
  });

  tearDown(() async {
    await host.close();
    if (root.existsSync()) await root.delete(recursive: true);
  });

  AsrModelStore store() => AsrModelStore(root: root);

  final modelBody = utf8.encode('the model weights' * 100);
  final tokensBody = utf8.encode('token list' * 10);

  AsrModel directModel() => AsrModel(
    id: 'test-model',
    label: 'Test',
    languages: const ['zh'],
    files: [
      _file('model.onnx', modelBody, [AsrSource(url: host.url('model.onnx'))]),
    ],
  );

  test('downloads, verifies and installs a file', () async {
    host.bodies['model.onnx'] = modelBody;
    final model = directModel();
    final progress = <AsrProgress>[];
    await store().ensure(model, onProgress: progress.add);

    final installed = store().fileOf(model, model.files.first);
    expect(installed.existsSync(), isTrue);
    expect(installed.readAsBytesSync(), modelBody);
    expect(store().isInstalled(model), isTrue);
    // no .part survives a success
    expect(File('${installed.path}.part').existsSync(), isFalse);
    expect(progress, isNotEmpty);
    expect(progress.last.received, modelBody.length);
    expect(progress.any((p) => p.verifying), isTrue);
  });

  test('a second ensure() does nothing', () async {
    host.bodies['model.onnx'] = modelBody;
    final model = directModel();
    await store().ensure(model);
    final before = host.requests;
    await store().ensure(model);
    expect(host.requests, before);
  });

  test('rejects a file whose hash does not match and installs nothing',
      () async {
    host.bodies['model.onnx'] = modelBody;
    final model = AsrModel(
      id: 'test-model',
      label: 'Test',
      languages: const [],
      files: [
        AsrModelFile(
          name: 'model.onnx',
          size: modelBody.length,
          sha256: 'f' * 64,
          sources: [AsrSource(url: host.url('model.onnx'))],
        ),
      ],
    );
    await expectLater(
      store().ensure(model),
      throwsA(isA<AsrModelException>()),
    );
    final target = store().fileOf(model, model.files.first);
    expect(target.existsSync(), isFalse);
    expect(File('${target.path}.part').existsSync(), isFalse);
  });

  test('resumes from a partial download instead of restarting', () async {
    host.bodies['model.onnx'] = modelBody;
    final model = directModel();
    final target = store().fileOf(model, model.files.first);
    await target.parent.create(recursive: true);
    final half = modelBody.length ~/ 2;
    await File('${target.path}.part').writeAsBytes(modelBody.sublist(0, half));

    await store().ensure(model);
    expect(target.readAsBytesSync(), modelBody);
    expect(host.bytesSent, modelBody.length - half);
  });

  test('starts over when the server ignores the range', () async {
    host
      ..bodies['model.onnx'] = modelBody
      ..supportsRange = false;
    final model = directModel();
    final target = store().fileOf(model, model.files.first);
    await target.parent.create(recursive: true);
    await File('${target.path}.part')
        .writeAsBytes(modelBody.sublist(0, modelBody.length ~/ 2));

    await store().ensure(model);
    expect(target.readAsBytesSync(), modelBody);
  });

  test('falls back to the next source when the first is gone', () async {
    host.bodies['mirror.onnx'] = modelBody;
    host.bodies['upstream.onnx'] = modelBody;
    host.missing.add('mirror.onnx');
    final model = AsrModel(
      id: 'test-model',
      label: 'Test',
      languages: const [],
      files: [
        _file('model.onnx', modelBody, [
          AsrSource(url: host.url('mirror.onnx')),
          AsrSource(url: host.url('upstream.onnx')),
        ]),
      ],
    );
    await store().ensure(model);
    expect(
      store().fileOf(model, model.files.first).readAsBytesSync(),
      modelBody,
    );
  });

  test('extracts every wanted file from one tarball, downloaded once',
      () async {
    final tar = TarEncoder().encodeBytes(
      Archive()
        ..add(ArchiveFile.bytes('bundle/model.onnx', modelBody))
        ..add(ArchiveFile.bytes('bundle/tokens.txt', tokensBody))
        ..add(ArchiveFile.bytes('bundle/README', utf8.encode('ignored'))),
    );
    final packed = BZip2Encoder().encodeBytes(tar);
    host.bodies['bundle.tar.bz2'] = packed;

    AsrSource archiveSource(String entry) => AsrSource(
      url: host.url('bundle.tar.bz2'),
      archive: AsrArchive.tarBz2,
      entry: entry,
      archiveSize: packed.length,
    );
    final model = AsrModel(
      id: 'test-model',
      label: 'Test',
      languages: const [],
      files: [
        _file('model.onnx', modelBody, [archiveSource('bundle/model.onnx')]),
        _file('tokens.txt', tokensBody, [archiveSource('bundle/tokens.txt')]),
      ],
    );

    await store().ensure(model);
    expect(
      store().fileOf(model, model.files[0]).readAsBytesSync(),
      modelBody,
    );
    expect(
      store().fileOf(model, model.files[1]).readAsBytesSync(),
      tokensBody,
    );
    // one download for both files, and the 163 MB-shaped temp is gone
    expect(host.requests, 1);
    expect(
      Directory(path.join(store().dirOf(model).path, '.tmp')).existsSync(),
      isFalse,
    );
  });

  test('a truncated body is rejected on size before it is hashed', () async {
    host.bodies['model.onnx'] = modelBody.sublist(0, modelBody.length - 5);
    final model = directModel();
    await expectLater(
      store().ensure(model),
      throwsA(isA<AsrModelException>()),
    );
    expect(store().isInstalled(model), isFalse);
  });

  test('cancelling stops the download and leaves no installed file', () async {
    host.bodies['model.onnx'] = modelBody;
    final model = directModel();
    final token = AsrCancelToken()..cancel();
    await expectLater(
      store().ensure(model, token: token),
      throwsA(isA<AsrCancelled>()),
    );
    expect(store().isInstalled(model), isFalse);
  });

  test('isInstalled is false when the file is the wrong length', () async {
    final model = directModel();
    final target = store().fileOf(model, model.files.first);
    await target.parent.create(recursive: true);
    await target.writeAsBytes(modelBody.sublist(0, 10));
    expect(store().isInstalled(model), isFalse);
  });

  group('manual import', () {
    late File source;

    setUp(() async {
      source = File(path.join(root.path, 'model.onnx'));
      await source.writeAsBytes(modelBody);
    });

    test('accepts the right file', () async {
      final model = directModel();
      final got = await store().importFile(source, models: [model]);
      expect(got.name, 'model.onnx');
      expect(store().isInstalled(model), isTrue);
    });

    test('rejects a file with the right name but wrong content', () async {
      final model = directModel();
      await source.writeAsBytes(Uint8List(modelBody.length));
      await expectLater(
        store().importFile(source, models: [model]),
        throwsA(isA<AsrModelException>()),
      );
      expect(store().isInstalled(model), isFalse);
    });

    test('rejects an unrelated file', () async {
      final other = File(path.join(root.path, 'holiday.jpg'));
      await other.writeAsBytes(modelBody);
      await expectLater(
        store().importFile(other, models: [directModel()]),
        throwsA(isA<AsrModelException>()),
      );
    });
  });

  group('catalogue', () {
    test('every pin is a full SHA-256 and every file has a source', () {
      for (final model in AsrModelCatalog.required) {
        expect(model.files, isNotEmpty, reason: model.id);
        for (final file in model.files) {
          expect(
            file.sha256,
            matches(RegExp(r'^[0-9a-f]{64}$')),
            reason: '${model.id}/${file.name}',
          );
          expect(file.size, greaterThan(0));
          expect(file.sources, isNotEmpty);
          for (final source in file.sources) {
            expect(Uri.parse(source.url).scheme, 'https');
            if (source.archive != AsrArchive.none) {
              expect(source.entry, isNotNull);
            }
          }
        }
      }
    });

    test('ids and filenames are unique', () {
      final ids = AsrModelCatalog.required.map((m) => m.id).toSet();
      expect(ids, hasLength(AsrModelCatalog.required.length));
      for (final model in AsrModelCatalog.required) {
        final names = model.files.map((f) => f.name).toSet();
        expect(names, hasLength(model.files.length), reason: model.id);
      }
    });

    test('pins the 2024-07-17 SenseVoice, not the yue-pinned 2025 build', () {
      for (final file in AsrModelCatalog.senseVoice.files) {
        for (final source in file.sources) {
          expect(source.url, contains('2024-07-17'));
          expect(source.url, isNot(contains('2025')));
        }
      }
    });

    test('byId round-trips and is null for anything else', () {
      expect(AsrModelCatalog.byId('silero-vad'), AsrModelCatalog.vad);
      expect(AsrModelCatalog.byId('nope'), isNull);
    });
  });

  group('a stalled connection', () {
    setUp(() {
      AsrModelStore.debugIdleTimeout = const Duration(milliseconds: 300);
    });
    tearDown(() {
      AsrModelStore.debugIdleTimeout = const Duration(seconds: 30);
    });

    test('times out instead of hanging, and falls back to the next source',
        () async {
      host.bodies['stall.onnx'] = modelBody;
      host.bodies['good.onnx'] = modelBody;
      host.stalling.add('stall.onnx');
      final model = AsrModel(
        id: 'test-model',
        label: 'Test',
        languages: const [],
        files: [
          _file('model.onnx', modelBody, [
            AsrSource(url: host.url('stall.onnx')),
            AsrSource(url: host.url('good.onnx')),
          ]),
        ],
      );

      await store()
          .ensure(model)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail('the download hung instead of timing out'),
          );
      expect(
        store().fileOf(model, model.files.first).readAsBytesSync(),
        modelBody,
      );
    });

    test('a stall on every source fails rather than hanging', () async {
      host.bodies['stall.onnx'] = modelBody;
      host.stalling.add('stall.onnx');
      final model = AsrModel(
        id: 'test-model',
        label: 'Test',
        languages: const [],
        files: [
          _file('model.onnx', modelBody, [
            AsrSource(url: host.url('stall.onnx')),
          ]),
        ],
      );
      await expectLater(
        store().ensure(model).timeout(const Duration(seconds: 10)),
        throwsA(isA<AsrModelException>()),
      );
    });

    test('cancelling a stalled download returns instead of waiting', () async {
      host.bodies['stall.onnx'] = modelBody;
      host.stalling.add('stall.onnx');
      final model = AsrModel(
        id: 'test-model',
        label: 'Test',
        languages: const [],
        files: [
          _file('model.onnx', modelBody, [
            AsrSource(url: host.url('stall.onnx')),
          ]),
        ],
      );
      // long enough that only the cancel can end this
      AsrModelStore.debugIdleTimeout = const Duration(seconds: 30);
      final token = AsrCancelToken();
      final job = store().ensure(model, token: token);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      token.cancel();
      await expectLater(
        job.timeout(const Duration(seconds: 5)),
        throwsA(anyOf(isA<AsrCancelled>(), isA<AsrModelException>())),
      );
    });
  });
}
