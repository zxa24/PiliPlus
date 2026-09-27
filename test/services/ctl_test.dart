import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/asr/asr_schedule.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/ctl/ctl_server.dart';
import 'package:PiliPlus/services/ctl/ctl_state.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

Future<(int, Map<String, dynamic>)> _get(
  int port,
  String route, {
  String? token,
  String method = 'GET',
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$route'),
    );
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (response.statusCode, jsonDecode(body) as Map<String, dynamic>);
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('token check', () {
    const token = 'ab12cd34';
    test('only the exact token, as a Bearer header, passes', () {
      expect(CtlServer.tokenMatches('Bearer ab12cd34', token), isTrue);
      expect(CtlServer.tokenMatches(null, token), isFalse);
      expect(CtlServer.tokenMatches('', token), isFalse);
      expect(CtlServer.tokenMatches('ab12cd34', token), isFalse);
      expect(CtlServer.tokenMatches('Basic ab12cd34', token), isFalse);
      expect(CtlServer.tokenMatches('Bearer ab12cd3', token), isFalse);
      expect(CtlServer.tokenMatches('Bearer ab12cd345', token), isFalse);
      expect(CtlServer.tokenMatches('Bearer ', token), isFalse);
      expect(CtlServer.tokenMatches('Bearer xb12cd34', token), isFalse);
    });

    test('a new token is 32 random bytes in hex, never the same twice', () {
      final a = CtlServer.newToken();
      expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(CtlServer.newToken(), isNot(a));
    });
  });

  group('server and ctl.json', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ctl_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    CtlServer make() => CtlServer(
      dir: dir.path,
      identity: {'app': 'LibrePili', 'version': 'test', 'profile': null},
      endpoints: {
        '/status': (_) => {'hello': 'world'},
        '/log': (uri) => {'since': uri.queryParameters['since']},
        '/boom': (_) => throw StateError('broken'),
      },
    );

    test('lives while serving: written on start, gone on stop', () async {
      final server = make();
      final file = File(path.join(dir.path, 'ctl.json'));
      expect(file.existsSync(), isFalse);
      await server.start();
      expect(CtlServer.current, same(server));
      final info = jsonDecode(file.readAsStringSync()) as Map;
      expect(info['port'], server.port);
      expect(info['token'], server.token);
      expect(info['pid'], pid);
      expect(info['version'], 'test');
      expect(DateTime.tryParse(info['startedAt'] as String), isNotNull);
      // no half-written file left beside it
      expect(File('${file.path}.part').existsSync(), isFalse);
      final port = server.port!;
      await server.stop();
      expect(file.existsSync(), isFalse);
      expect(CtlServer.current, isNull);
      await expectLater(_get(port, '/health'), throwsA(isA<SocketException>()));
    });

    test('a file left by a crashed run is removed', () {
      final file = File(path.join(dir.path, 'ctl.json'))
        ..writeAsStringSync('{"port": 1, "token": "old", "pid": 1}');
      CtlServer.removeStale(dir.path);
      expect(file.existsSync(), isFalse);
      // nothing there: no error
      CtlServer.removeStale(dir.path);
    });

    test('the sync removal on the way out', () async {
      final server = make();
      await server.start();
      server.removeFileSync();
      expect(File(server.filePath).existsSync(), isFalse);
      await server.stop();
    });

    test('every endpoint but /health needs the token', () async {
      final server = make();
      await server.start();
      final port = server.port!;
      try {
        final (noToken, body) = await _get(port, '/status');
        expect(noToken, HttpStatus.unauthorized);
        expect(body.containsKey('hello'), isFalse);
        expect((await _get(port, '/status', token: 'wrong')).$1, 401);
        expect((await _get(port, '/nope')).$1, 401);

        final (ok, status) = await _get(port, '/status', token: server.token);
        expect(ok, 200);
        expect(status, {'hello': 'world'});
        final (_, log) = await _get(
          port,
          '/log?since=2026-09-26T10:00:00',
          token: server.token,
        );
        expect(log['since'], '2026-09-26T10:00:00');

        final (health, alive) = await _get(port, '/health');
        expect(health, 200);
        expect(alive, {
          'ok': true,
          'app': 'LibrePili',
          'version': 'test',
          'profile': null,
        });
        expect(alive.containsKey('token'), isFalse);

        expect((await _get(port, '/nope', token: server.token)).$1, 404);
        final (failed, error) = await _get(port, '/boom', token: server.token);
        expect(failed, 500);
        expect(error['error'], contains('broken'));
      } finally {
        await server.stop();
      }
    });

    test('read-only, and never from a browser page', () async {
      final server = make();
      await server.start();
      final port = server.port!;
      try {
        expect(
          (await _get(port, '/status', token: server.token, method: 'POST')).$1,
          HttpStatus.methodNotAllowed,
        );
        expect(
          (await _get(
            port,
            '/status',
            token: server.token,
            headers: {'origin': 'https://example.com'},
          )).$1,
          HttpStatus.forbidden,
        );
      } finally {
        await server.stop();
      }
    });
  });

  group('settings whitelist', () {
    final stored = <String, Object?>{
      SettingBoxKey.subtitleChoice: 'zh',
      SettingBoxKey.translateModel: 'hy-mt',
      SettingBoxKey.translatePinnedLanguages: ['en', 'ja'],
      SettingBoxKey.autoPlayEnable: true,
      // a URL with credentials in a whitelisted key: the host only
      SettingBoxKey.CDNService: 'https://user:pass@cdn.example.com/x?key=s3',
      SettingBoxKey.ytRegion: 'x' * 500,
      // secrets and personal data that must never come out
      'cookie': 'SESSDATA=abc',
      'accessKey': 'ak-123',
      'refresh_token': 'rt',
      SettingBoxKey.systemProxyHost: 'user:pw@10.0.0.1',
      SettingBoxKey.systemProxyPort: '8080',
      'userInfo': {'mid': 1},
      'mid': 42,
    };

    test('only whitelisted keys, and values reduced to plain ones', () {
      final out = ctlSettingsJson(stored.read);
      expect(out.keys, unorderedEquals(ctlSettingKeys));
      expect(out[SettingBoxKey.subtitleChoice], 'zh');
      expect(out[SettingBoxKey.translatePinnedLanguages], ['en', 'ja']);
      expect(out[SettingBoxKey.CDNService], 'cdn.example.com');
      expect(out[SettingBoxKey.ytRegion], '(500 chars)');
      // never set: null, its default
      expect(out[SettingBoxKey.asrThreads], isNull);
      final text = jsonEncode(out);
      for (final secret in [
        'SESSDATA',
        'ak-123',
        'pass',
        '10.0.0.1',
        's3',
        '8080',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
    });

    test('a secret-looking key is refused even when listed', () {
      final out = ctlSettingsJson(
        stored.read,
        keys: [
          'cookie',
          'accessKey',
          'refresh_token',
          SettingBoxKey.systemProxyHost,
          SettingBoxKey.systemProxyPort,
          'userInfo',
          'mid',
          'appKey',
          'authHeader',
          'loginMode',
          SettingBoxKey.subtitleChoice,
        ],
      );
      expect(out.keys, [SettingBoxKey.subtitleChoice]);
    });

    test('no whitelisted key trips the secret filter by accident', () {
      final out = ctlSettingsJson((_) => null);
      expect(out.length, ctlSettingKeys.length);
    });
  });

  group('status serialization', () {
    test('a transcription as the page holds it', () {
      final session = AsrSession.debugFor('cid1')
        ..power = AsrPower.battery
        ..debugPowerFixed = true
        ..debugSet(
          const AsrState(
            stage: AsrStage.transcribing,
            language: 'zh',
            message: '识别中',
            progress: 0.25,
          ),
        );
      final run = session.transcript.startRun(0);
      session.transcript.advance(run, 45.24);
      final json = ctlAsrJson(session)!;
      expect(json['stage'], 'transcribing');
      expect(json['label'], '识别中');
      expect(json['language'], 'zh');
      expect(json['progress'], 0.25);
      expect(json['covered'], [
        [0.0, 45.2],
      ]);
      expect(json['coveredSeconds'], 45.2);
      expect(json['runCount'], 0);
      expect(json['hasEnded'], isFalse);
      expect(json['suspended'], isFalse);
      expect(json['fullCoverageRequested'], isFalse);
      expect((json['leadWindow'] as Map)['pauses'], isTrue);
      // no upper bound (power unlimited): null, as JSON has no infinity
      session.power = AsrPower.unlimited;
      final unbounded = ctlAsrJson(session)!['leadWindow'] as Map;
      expect(unbounded['high'], isNull);
      expect(unbounded['pauses'], isFalse);
      // all of it is plain JSON
      expect(() => jsonEncode(json), returnsNormally);
      expect(ctlAsrJson(null), isNull);
    });

    test('a translation asked for and not started yet', () {
      expect(ctlTranslationFields(active: true, into: 'en'), {
        'active': true,
        'into': 'en',
        'starting': true,
        'stage': null,
        'message': null,
        'unitsDone': null,
        'unitsTotal': null,
      });
      expect(ctlTranslationFields(active: false)['starting'], isFalse);
    });

    test('stream URLs come out as their host alone', () {
      expect(
        ctlHostOf(
          'https://upos-sz-mirrorcos.bilivideo.com/a.m4s?deadline=1&e=k',
        ),
        'upos-sz-mirrorcos.bilivideo.com',
      );
      expect(ctlHostOf(r'C:\videos\a.mp4'), isNull);
      expect(ctlHostOf('/sdcard/a.mp4'), isNull);
      expect(ctlHostOf('edl://%10%https://x'), isNull);
      expect(ctlHostOf(null), isNull);
    });
  });
}

extension on Map<String, Object?> {
  Object? read(String key) => this[key];
}
