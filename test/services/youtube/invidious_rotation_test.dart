import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/youtube/invidious_instances.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

/// Several instances behind one source: which is asked, which set aside,
/// and Anubis — from pages recorded 2026-10-12, through a scripted
/// transport. No network.
void main() {
  String fixture(String name) =>
      File('test/fixtures/youtube/invidious/$name').readAsStringSync();

  final watch = fixture('watch_dQw4w9WgXcQ.html');
  final dash = fixture('dash_dQw4w9WgXcQ.mpd');
  final relayedDash = fixture('dash_dQw4w9WgXcQ_relayed.mpd');
  // where the recorded page's manifest is: the relayed streams' host
  final companion = Uri.parse(
    parseInvidiousWatch(watch, 'dQw4w9WgXcQ')!.relayedDashUrl!,
  ).host;
  final captionList = fixture('captions_dQw4w9WgXcQ.json');

  group('Anubis', () {
    test("tiekoetter's recorded challenge, solved as webread solves it", () {
      final c = Anubis.parse(fixture('anubis_tiekoetter.html'))!;
      expect(c.algorithm, 'fast');
      expect(c.difficulty, 4);
      expect(c.id, '01a130ee-0ca4-70d3-8a48-50d0c18c56f5');
      expect(c.basePrefix, '');
      expect(c.solvable, isTrue);
      // python hashlib, the same rule: 123443 / 0000cf8e…
      final s = Anubis.solve(c.randomData, c.difficulty)!;
      expect(s.nonce, 123443);
      expect(s.hash, startsWith('0000cf8ec168ac6a'));
    });

    test('the pass URL carries what the gate checks', () {
      final c = Anubis.parse(fixture('anubis_f5si.html'))!;
      final u = Anubis.passUrl(
        'https://invidious.f5.si',
        c,
        solution: (nonce: 7, hash: 'ab'),
        redirect: 'https://invidious.f5.si/watch?v=x',
        elapsedMs: 9,
      );
      expect(u.path, '/.within.website/x/cmd/anubis/api/pass-challenge');
      expect(u.queryParameters, {
        'id': c.id,
        'response': 'ab',
        'nonce': '7',
        'redir': 'https://invidious.f5.si/watch?v=x',
        'elapsedTime': '9',
      });
    });

    test('an odd difficulty checks the half byte', () {
      final s = Anubis.solve('abc', 3)!;
      expect(s.hash, startsWith('000'));
    });

    test('a prefix that is not a plain path is not taken', () {
      final page = fixture('anubis_f5si.html').replaceFirst(
        RegExp(r'id="anubis_base_prefix" type="application/json">""'),
        'id="anubis_base_prefix" type="application/json">"@evil.host"',
      );
      expect(Anubis.parse(page)!.basePrefix, '');
    });

    test('not an Anubis page', () {
      expect(Anubis.parse(watch), isNull);
    });
  });

  group('the registry', () {
    test('every clearnet https entry, down or not', () {
      final hosts = InvidiousInstances.allHttps(
        jsonDecodeFile('test/fixtures/youtube/invidious/registry.json'),
      );
      expect(hosts, contains('https://invidious.f5.si'));
      expect(hosts.first, 'https://inv.nadeko.net');
      expect(hosts.any((h) => h.contains('.onion') || h.contains('.i2p')), isFalse);
    });
  });

  test('caption languages from the label where the list is refused', () {
    expect(invidiousLanguageOf('German (Germany)'), 'de');
    expect(invidiousLanguageOf('English (auto-generated)'), 'en');
    expect(invidiousLanguageOf('Chinese (Traditional)'), 'zh-Hant');
    expect(invidiousLanguageOf('Chinese (China)'), 'zh-Hans');
    expect(invidiousLanguageOf('Klingon'), isNull);
  });

  group('the instances', () {
    test('a CAPTCHA instance is set aside, the next serves', () async {
      final net = _Net()
        ..on('captcha.example', '/watch', (_) => _page('<title>Auth with CAPTCHA</title>'))
        ..serveVideo('good.example', watch, dash, captionList);
      final source = net.source(['https://captcha.example', 'https://good.example']);

      final r = await source.detail('dQw4w9WgXcQ');
      expect(r.ok, isTrue);
      expect(r.value!.formats, hasLength(13));
      expect(r.value!.captionTracks.first.languageCode, 'en');
      expect(source.preferredHost, 'https://good.example');
      expect(source.label, 'Invidious (good.example)');

      source.forget('dQw4w9WgXcQ');
      net.asked.clear();
      await source.detail('dQw4w9WgXcQ');
      expect(net.asked.where((u) => u.host == 'captcha.example'), isEmpty);
    });

    test('the one that served is asked first next time', () async {
      final net = _Net()
        ..serveVideo('a.example', watch, dash, captionList)
        ..serveVideo('b.example', watch, dash, captionList);
      final source = net.source(['https://a.example', 'https://b.example']);
      await source.detail('dQw4w9WgXcQ');
      expect(source.preferredHost, 'https://a.example');
      expect(net.asked.where((u) => u.host == 'b.example'), isEmpty);
    });

    test('through Anubis: the cookie from the pass goes back', () async {
      final gate = fixture('anubis_tiekoetter.html');
      final net = _Net()
        ..on('gated.example', '/watch', (request) {
          final cookie = request.headers[HttpHeaders.cookieHeader] ?? '';
          return cookie.contains('anubis-auth=ok')
              ? _page(watch)
              : _page(gate);
        })
        ..on(
          'gated.example',
          '/.within.website/x/cmd/anubis/api/pass-challenge',
          (request) {
            expect(request.uri.queryParameters['nonce'], '123443');
            return InvidiousAnswer(
              302,
              '',
              location: '/watch?v=dQw4w9WgXcQ',
              cookies: [Cookie('anubis-auth', 'ok')],
            );
          },
        )
        ..serveVideo('gated.example', null, dash, captionList);
      final source = net.source(['https://gated.example']);
      final r = await source.detail('dQw4w9WgXcQ');
      expect(r.ok, isTrue);
      // the companion is another host: the gate's cookie is not sent there
      final companion = net.requests.firstWhere(
        (q) => q.uri.path.contains('/manifest/dash/'),
      );
      expect(companion.headers[HttpHeaders.cookieHeader], isNull);
    });

    test('a video no instance has: unavailable, nobody set aside', () async {
      final empty = watch.replaceAll('id="player_data"', 'id="nothing"');
      final net = _Net()
        ..on('a.example', '/watch', (_) => _page(empty))
        ..on('b.example', '/watch', (_) => _page(empty));
      final source = net.source(['https://a.example', 'https://b.example']);
      final r = await source.detail('dQw4w9WgXcQ');
      expect(r.verdict.cause, YtCause.contentUnavailable);
      expect(r.verdict.signal, 'invidious:no-player');
      net.asked.clear();
      await source.detail('dQw4w9WgXcQ');
      expect(net.asked.map((u) => u.host).toSet(), {'a.example', 'b.example'});
    });

    test("Invidious' own error page: the next instance, this one kept", () async {
      // tiekoetter 2026-10-12: one video "Can't load", another played
      const error =
          '<link rel="stylesheet" href="/css/pure-min.css?v=1">'
          "<p>Can't load the video on this Invidious instance.</p>";
      final net = _Net()
        ..on('a.example', '/watch', (_) => const InvidiousAnswer(500, error))
        ..serveVideo('b.example', watch, dash, captionList);
      final source = net.source(['https://a.example', 'https://b.example']);
      expect((await source.detail('dQw4w9WgXcQ')).ok, isTrue);
      source.forget('dQw4w9WgXcQ');
      net.asked.clear();
      await source.detail('dQw4w9WgXcQ');
      // b served, so b first; a is not set aside, only behind
      expect(net.asked.first.host, 'b.example');
      expect(source.preferredHost, 'https://b.example');
    });

    test("a gate of the instance's own, by redirect, is set aside", () async {
      final net = _Net()
        ..on('gandalf.example', '/watch', (_) => const InvidiousAnswer(
          307,
          '',
          location: '/.gandalf/check?gandalf_id=x',
        ))
        ..serveVideo('good.example', watch, dash, captionList);
      final source = net.source(['https://gandalf.example', 'https://good.example']);
      expect((await source.detail('dQw4w9WgXcQ')).ok, isTrue);
    });

    test('the detail and the streams together: one watch page', () async {
      final net = _Net()..serveVideo('a.example', watch, dash, captionList);
      final source = net.source(['https://a.example']);
      final both = await Future.wait([
        source.detail('dQw4w9WgXcQ'),
        source.streams('dQw4w9WgXcQ'),
      ]);
      expect(both.every((r) => r.ok), isTrue);
      expect(net.asked.where((u) => u.path == '/watch'), hasLength(1));
    });

    group('googlevideo refusing this machine', () {
      _Net refusing(int status) => _Net()
        ..serveVideo('a.example', watch, dash, captionList)
        ..on('*', '/companion/api/manifest/dash/', (q) => _page(
          q.uri.queryParameters['local'] == 'true' ? relayedDash : dash,
        ))
        ..on('.googlevideo.com', '/videoplayback', (q) {
          expect(q.headers[HttpHeaders.rangeHeader], 'bytes=0-1023');
          // the refusal comes after ipbypass's redirect, as measured
          return q.uri.queryParameters.containsKey('ipbypass')
              ? InvidiousAnswer(status, '')
              : const InvidiousAnswer(
                  302,
                  '',
                  location: 'https://rr9---x.googlevideo.com/videoplayback?ipbypass=yes',
                );
        });

      test('a 403: the streams through the companion', () async {
        final net = refusing(403);
        final r = await net.source(['https://a.example']).streams('dQw4w9WgXcQ');
        expect(r.ok, isTrue);
        final video = Uri.parse(r.value!.videoUrl);
        expect(video.host, companion);
        expect(video.path, '/companion/videoplayback');
        expect(Uri.parse(r.value!.audioUrl).host, companion);
        // one probe, its redirect followed
        expect(net.asked.where((u) => u.host.endsWith('googlevideo.com')), hasLength(2));
      });

      test('served: the streams from googlevideo, the companion spared', () async {
        final net = refusing(206);
        final r = await net.source(['https://a.example']).streams('dQw4w9WgXcQ');
        expect(Uri.parse(r.value!.videoUrl).host, endsWith('googlevideo.com'));
        expect(
          net.asked.where((u) => u.queryParameters['local'] == 'true'),
          isEmpty,
        );
      });

      test('always through the companion when asked to be', () async {
        final net = refusing(206);
        final r = await net
            .source(['https://a.example'], relayed: true)
            .streams('dQw4w9WgXcQ');
        expect(Uri.parse(r.value!.videoUrl).host, companion);
        expect(net.asked.where((u) => u.host.endsWith('googlevideo.com')), isEmpty);
      });
    });

    test('the registry read when no hosts are given, the known ones when '
        'it is out of reach', () async {
      final up = _Net()
        ..on('api.invidious.io', '/instances.json', (_) => _page(
          File('test/fixtures/youtube/invidious/registry.json').readAsStringSync(),
        ))
        ..serveVideo('inv.nadeko.net', watch, dash, captionList);
      final viaRegistry = up.source(null);
      expect((await viaRegistry.detail('dQw4w9WgXcQ')).ok, isTrue);
      expect(viaRegistry.preferredHost, 'https://inv.nadeko.net');

      final down = _Net()
        ..on('api.invidious.io', '/instances.json', (_) => const InvidiousAnswer(0, '', error: 'offline'))
        ..serveVideo('inv.nadeko.net', watch, dash, captionList);
      final fallback = down.source(null);
      expect((await fallback.detail('dQw4w9WgXcQ')).ok, isTrue);
      expect(fallback.preferredHost, YtInvidiousSource.knownHosts.first);
    });
  });
}

Object? jsonDecodeFile(String path) =>
    const JsonDecoder().convert(File(path).readAsStringSync());

InvidiousAnswer _page(String body) => InvidiousAnswer(200, body);

typedef _Request = ({Uri uri, String method, Map<String, String> headers});

/// A scripted network: `host + path prefix → answer`; anything else 404.
class _Net {
  final _routes = <(String, String), InvidiousAnswer Function(_Request)>{};
  final requests = <_Request>[];
  List<Uri> get asked => _asked;
  final _asked = <Uri>[];

  void on(String host, String path, InvidiousAnswer Function(_Request) answer) =>
      _routes[(host, path)] = answer;

  /// [host]'s watch page (unless null), and every companion's manifest and
  /// caption list.
  void serveVideo(String host, String? watch, String dash, String captions) {
    if (watch != null) on(host, '/watch', (_) => _page(watch));
    on(host, '/api/v1/captions/', (_) => _page(captions));
    on('*', '/companion/api/manifest/dash/', (_) => _page(dash));
  }

  YtInvidiousSource source(List<String>? hosts, {bool relayed = false}) =>
      YtInvidiousSource(
    hosts: hosts,
    relayed: relayed,
    fetch: (uri, {required method, required headers}) async {
      final request = (uri: uri, method: method, headers: headers);
      requests.add(request);
      _asked.add(uri);
      for (final MapEntry(key: (host, path), value: answer) in _routes.entries) {
        final hostMatches =
            host == uri.host ||
            host == '*' ||
            (host.startsWith('.') && uri.host.endsWith(host));
        if (hostMatches && uri.path.startsWith(path)) {
          return answer(request);
        }
      }
      return const InvidiousAnswer(404, 'not found');
    },
  );
}
