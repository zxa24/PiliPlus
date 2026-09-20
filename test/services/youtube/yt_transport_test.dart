/// What [IoYtTransport] actually puts on the wire.
///
/// These tests bind a throwaway HTTP server on 127.0.0.1 and talk to that.
/// Nothing leaves the machine: there is no DNS lookup, no external host, and
/// the server is torn down in `tearDown`. It is the only way to assert on
/// headers a real `HttpClient` emits, and the header set is exactly the
/// privacy property this folder exists to keep.
library;

import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late List<HttpHeaders> seen;
  late IoYtTransport transport;

  /// What each request should be answered with.
  late void Function(HttpRequest) handler;

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  setUp(() async {
    seen = [];
    handler = (req) => req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write('{"ok":true}');

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((req) async {
        seen.add(req.headers);
        await req.drain<void>();
        handler(req);
        await req.response.close();
      });
    transport = IoYtTransport();
  });

  tearDown(() async {
    transport.close();
    await server.close(force: true);
  });

  test(
    'sends exactly the headers it was given, plus accept and language',
    () async {
      final r = await transport.send(
        'POST',
        url('/youtubei/v1/player'),
        headers: const {
          'User-Agent': 'com.google.visionos.youtube/1.04(x)',
          'X-Goog-Api-Format-Version': '2',
        },
        body: utf8.encode('{"videoId":"dQw4w9WgXcQ"}'),
      );

      expect(r.status, 200);
      expect(r.obj['ok'], true);

      final h = seen.single;
      expect(h.value('user-agent'), 'com.google.visionos.youtube/1.04(x)');
      expect(h.value('x-goog-api-format-version'), '2');
      expect(h.value('accept'), contains('application/json'));
      expect(h.value('accept-language'), 'en-US,en;q=0.9');
      expect(h.value('content-type'), 'application/json');

      // Nothing from the bilibili stack, and no cookie at all.
      expect(h.value('cookie'), isNull);
      expect(h.value('referer'), isNull);
      expect(h.value('origin'), isNull);
      expect(h.value('authorization'), isNull);
    },
  );

  test('does NOT persist Set-Cookie across requests', () async {
    handler = (req) => req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..headers.add(
        'set-cookie',
        'SESSION=leak_me; Path=/; Domain=127.0.0.1',
      )
      ..write('{"ok":true}');

    await transport.send('GET', url('/one'));
    await transport.send('GET', url('/two'));

    expect(seen, hasLength(2));
    expect(
      seen[1].value('cookie'),
      isNull,
      reason: 'a cookie jar here would join this identity to the next request',
    );
  });

  test('a redirect is reported, not followed, by default', () async {
    handler = (req) => req.response
      ..statusCode = 302
      ..headers.add('location', 'https://www.google.com/sorry/index');

    final r = await transport.send('GET', url('/blocked'));
    expect(r.status, 302);
    expect(seen, hasLength(1), reason: 'the redirect target was not fetched');

    // And the classifier reads it correctly.
    final v = classifyYtTransport(r);
    expect(v!.cause, YtCause.ipBlocked);
    expect(v.signal, 'redirect-sorry');
  });

  test(
    'a connection failure becomes a transient verdict, not an exception',
    () async {
      final dead = url('/gone'); // capture the port before it goes away
      await server.close(force: true);
      final r = await transport.send('GET', dead);
      expect(r.status, 0);
      expect(r.transportError, isNotEmpty);
      final v = classifyYtTransport(r);
      expect(v!.cause, YtCause.transient);
      expect(v.signal, 'transport');
      // Re-bind so tearDown has something to close.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    },
  );

  test('a non-JSON body is kept as bytes and leaves json null', () async {
    handler = (req) => req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.text
      ..write('WEBVTT\n\n00:00:01.200 --> 00:00:03.360\nhello');

    final r = await transport.send('GET', url('/caption'), parseJson: false);
    expect(r.json, isNull);
    expect(r.text, startsWith('WEBVTT'));
    expect(r.byteCount, greaterThan(0));
    // Bytes are preserved verbatim: a lossy round-trip through `text` is how
    // the spike silently truncated 5% of a media fragment.
    expect(r.body, utf8.encode(r.text));
  });

  test('counts requests and bytes for the diagnostics line', () async {
    await transport.send('GET', url('/a'));
    await transport.send('GET', url('/b'));
    expect(transport.requests, 2);
    expect(transport.bytesIn, greaterThan(0));
  });

  test('close() releases the client', () {
    final t = IoYtTransport();
    expect(t.close, returnsNormally);
  });
}
