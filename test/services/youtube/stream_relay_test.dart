import 'dart:io';

import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

/// The relay of Invidious streams: what it refuses to ask for, and what it
/// answers the player. Names are looked up by a script: no request leaves
/// this machine.
void main() {
  final addresses = <String, List<InternetAddress>>{
    'public.example': [InternetAddress('203.0.113.7')],
    'lan.example': [InternetAddress('192.168.1.10')],
    'mixed.example': [
      InternetAddress('203.0.113.7'),
      InternetAddress('10.0.0.2'),
    ],
    'loop.example': [InternetAddress('127.0.0.1')],
  };

  setUp(() {
    YtInvidiousSource.lookup = (host) async =>
        addresses[host] ?? (throw const SocketException('no such host'));
    YtStreamRelay.proxyFor = null;
  });
  tearDown(() {
    YtInvidiousSource.lookup = InternetAddress.lookup;
    YtStreamRelay.proxyFor = null;
  });

  group('every hop is checked', () {
    late YtCheckedHops hops;
    setUp(() => hops = YtCheckedHops(HttpClient()));
    tearDown(() => hops.close());

    Future<String?> refusal(String url) async {
      try {
        await hops.check(Uri.parse(url));
        return null;
      } on YtHopRefused catch (e) {
        return e.why;
      }
    }

    test('a public https host passes', () async {
      expect(await refusal('https://public.example/videoplayback'), isNull);
    });

    test('not https is refused', () async {
      expect(await refusal('http://public.example/v'), 'not https');
    });

    test('a host on the local network is refused', () async {
      expect(await refusal('https://lan.example/v'), 'not a public address');
      expect(await refusal('https://loop.example/v'), 'not a public address');
      expect(await refusal('https://192.168.0.1/v'), 'not a public address');
      expect(await refusal('https://[::1]/v'), 'not a public address');
    });

    test('one local address among public ones is enough to refuse', () async {
      expect(await refusal('https://mixed.example/v'), 'not a public address');
    });

    test('a host with no address is refused', () async {
      expect(await refusal('https://nowhere.example/v'), 'no address');
    });

    test(
      'through a proxy, the name is left to it; a local one is not',
      () async {
        YtStreamRelay.proxyFor = (_) => 'PROXY 127.0.0.1:9';
        // the proxy looks it up: the scheme and the name are what is checked
        expect(await refusal('https://lan.example/v'), isNull);
        expect(await refusal('https://localhost/v'), 'a local host');
        expect(await refusal('https://10.1.2.3/v'), 'a local host');
        expect(await refusal('http://public.example/v'), 'not https');
      },
    );
  });

  group('the relay', () {
    late YtStreamRelay relay;
    late HttpClient player;
    setUp(() {
      relay = YtStreamRelay();
      player = HttpClient();
    });
    tearDown(() async {
      player.close(force: true);
      await relay.close();
    });

    Future<int> status(String url, {String method = 'GET'}) async {
      final request = await player.openUrl(method, Uri.parse(url));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    test('listens on the loopback, a long random token per stream', () async {
      expect(relay.wrapNow('https://public.example/a'), isNull);
      final a = Uri.parse(await relay.wrap('https://public.example/a'));
      final b = Uri.parse(await relay.wrap('https://public.example/b'));
      expect(a.host, '127.0.0.1');
      expect(a.pathSegments.first, hasLength(32));
      expect(a.pathSegments.last, 'public.example');
      expect(a.pathSegments.first, isNot(b.pathSegments.first));
      // the same URL keeps its token
      expect(await relay.wrap('https://public.example/a'), a.toString());
      expect(relay.wrapNow('https://public.example/a'), a.toString());
    });

    test('an unknown token, or another method, is not found', () async {
      final url = await relay.wrap('https://public.example/a');
      final port = Uri.parse(url).port;
      expect(await status('http://127.0.0.1:$port/0000/x'), 404);
      expect(await status(url, method: 'POST'), 404);
    });

    test('a stream on the local network is refused, not fetched', () async {
      final url = await relay.wrap('https://lan.example/videoplayback');
      expect(await status(url), 403);
      final plain = await relay.wrap('http://public.example/videoplayback');
      expect(await status(plain), 403);
    });

    test('closed, it answers nothing more', () async {
      final url = await relay.wrap('https://lan.example/v');
      await relay.close();
      expect(relay.running, isFalse);
      expect(() => status(url), throwsA(isA<SocketException>()));
    });

    test('closed while starting, it is not left listening', () async {
      final pending = relay.wrap('https://public.example/a');
      await relay.close();
      final url = await pending;
      expect(relay.running, isFalse);
      expect(() => status(url), throwsA(isA<SocketException>()));
    });

    test("the stream's expiry goes on the URL, for the player", () async {
      final url = Uri.parse(
        await relay.wrap(
          'https://public.example/videoplayback?expire=1760000000&id=1',
        ),
      );
      expect(url.queryParameters, {'expire': '1760000000'});
      expect(url.pathSegments.last, 'public.example');
      final none = Uri.parse(await relay.wrap('https://public.example/a'));
      expect(none.hasQuery, isFalse);
    });
  });
}
