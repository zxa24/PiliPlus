import 'dart:convert';

import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

import 'yt_test_support.dart';

/// A nonce source that is stable across a test run, so request bodies and the
/// `&cpn=` suffix can be asserted on.
String _fixedNonce(int length) => 'N' * length;

YtDirectSource _source(FakeYtTransport t) => YtDirectSource(
  InnertubeClient(t, nonce: _fixedNonce),
);

void main() {
  group('the request this layer actually sends', () {
    test('player: two headers, one JSON body, and only the video id', () async {
      late FakeYtTransport transport;
      transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
        return loadYtResponse(YtFixtures.playerOk);
      });

      final result = await _source(transport).streams('dQw4w9WgXcQ');
      expect(result.ok, isTrue);

      final player = transport.to('player').single;
      expect(player.method, 'POST');
      expect(player.url.host, 'youtubei.googleapis.com');
      expect(player.url.path, '/youtubei/v1/player');
      expect(player.url.queryParameters['prettyPrint'], 'false');
      expect(player.url.queryParameters['id'], 'dQw4w9WgXcQ');
      expect(player.url.queryParameters['t'], hasLength(12));

      // The exact client identity block.
      final client = player.clientContext;
      expect(client['clientName'], 'VISIONOS');
      expect(client['clientVersion'], '1.04');
      expect(client['deviceModel'], 'RealityDevice17,1');
      expect(client['osName'], 'visionOS');
      expect(client['visitorData'], 'VISITOR_0');
      expect(client['hl'], 'en-GB');
      expect(client['gl'], 'GB');

      final body = player.jsonBody;
      expect(body['videoId'], 'dQw4w9WgXcQ');
      expect(body['cpn'], hasLength(16));
      expect(body['contentCheckOk'], isTrue);
      expect(body['racyCheckOk'], isTrue);
      expect((body['context'] as Map)['user'], {'lockedSafetyMode': false});

      // Headers: the identity's two, and nothing bilibili-shaped.
      expect(player.headers.keys, ['User-Agent', 'X-Goog-Api-Format-Version']);
      expect(player.headers['User-Agent'], startsWith('com.google.visionos'));
      expect(
        player.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(
        player.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('referer')),
      );
    });

    test(
      'nothing but the 11-char id appears anywhere in any request we send',
      () async {
        late FakeYtTransport transport;
        transport = FakeYtTransport((req) {
          if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
          return loadYtResponse(YtFixtures.playerOk);
        });

        // A pasted watch URL full of tracking parameters.
        const pasted =
            'https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=SHARE_TOKEN_XYZ'
            '&pp=OPAQUE_TRACKING_BLOB&list=PLsomething&t=42'
            '&utm_source=somewhere';
        final id = parseYouTubeVideoId(pasted);
        expect(id, 'dQw4w9WgXcQ');

        await _source(transport).streams(id);

        for (final req in transport.requests) {
          final wire =
              '${req.url}\n'
              '${req.headers}\n'
              '${req.body == null ? '' : utf8.decode(req.body!)}';
          for (final leak in const [
            'SHARE_TOKEN_XYZ',
            'OPAQUE_TRACKING_BLOB',
            'PLsomething',
            'utm_source',
            'buvid',
            'bilibili',
            'SESSDATA',
            'access_key',
          ]) {
            expect(
              wire,
              isNot(contains(leak)),
              reason: '$leak in ${req.endpoint}',
            );
          }
        }
      },
    );

    test('visitor_id is minted on www, not on the gapis host', () async {
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
        return loadYtResponse(YtFixtures.playerOk);
      });
      await _source(transport).detail('dQw4w9WgXcQ');
      final v = transport.to('visitor_id').single;
      expect(v.url.host, 'www.youtube.com');
      // The bootstrap carries no visitorData of its own, by definition.
      expect(v.clientContext.containsKey('visitorData'), isFalse);
    });

    test(
      'the WEB identity sends the fixed consent cookie and nothing else',
      () async {
        final transport = FakeYtTransport((req) {
          if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
          return YtResponse.recorded(loadYtFixture(YtFixtures.search));
        });
        await _source(transport).search('flutter tutorial');
        final search = transport.to('search').single;
        expect(search.url.host, 'www.youtube.com');
        expect(search.headers['Cookie'], 'SOCS=CAISAiAD');
        expect(search.headers['X-YouTube-Client-Name'], '1');
        expect(search.jsonBody['params'], '8AEB');
        expect(search.jsonBody['query'], 'flutter tutorial');
      },
    );

    test('the cpn sent in the body is appended to both stream URLs', () async {
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
        return loadYtResponse(YtFixtures.playerOk);
      });
      final pair = (await _source(transport).streams('dQw4w9WgXcQ')).value!;
      final sentCpn = transport.to('player').single.jsonBody['cpn'] as String;
      expect(pair.videoUrl, endsWith('&cpn=$sentCpn'));
      expect(pair.audioUrl, endsWith('&cpn=$sentCpn'));
      expect(pair.sourceId, 'direct');
      expect(pair.expiresIn.inSeconds, greaterThan(3600));
    });

    test('edl:// is built with the %N% length prefixes', () {
      const pair = YtStreamPair(
        videoUrl: 'https://v.invalid/a;b',
        audioUrl: 'https://a.invalid/c',
        sourceId: 'direct',
        expiresIn: Duration(hours: 6),
      );
      expect(
        pair.edl,
        'edl://!no_chapters;%21%https://v.invalid/a;b;'
        '!new_stream;!no_chapters;%19%https://a.invalid/c',
      );
    });
  });

  // THE self-heal. A bot wall is what a missing/stale visitorData produces:
  // measured 8/8 with one, 1/8 without. Treating it as an IP block would make
  // the app fall back to a third party because of its own bug.
  group('bot-check self-heal', () {
    test('a bot wall that a fresh visitorData clears is NOT reported as a '
        'block — and the caller never sees it', () async {
      var visitorsMinted = 0;
      var playerCalls = 0;
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') {
          visitorsMinted++;
          return fakeVisitorIdResponse('VISITOR_$visitorsMinted');
        }
        playerCalls++;
        // First call: the bot wall. Second: fine.
        return playerCalls == 1
            ? loadYtResponse(YtFixtures.playerBotCheck)
            : loadYtResponse(YtFixtures.playerOk);
      });

      final result = await _source(transport).detail('dQw4w9WgXcQ');

      expect(result.ok, isTrue, reason: 'the retry succeeded');
      expect(result.verdict.cause, YtCause.ok);
      expect(playerCalls, 2);
      expect(visitorsMinted, 2, reason: 'a FRESH visitorData was minted');

      // And the retry really did carry the new blob.
      final players = transport.to('player');
      expect(players[0].clientContext['visitorData'], 'VISITOR_1');
      expect(players[1].clientContext['visitorData'], 'VISITOR_2');
    });

    test('a bot wall that SURVIVES a fresh visitorData is reported as a '
        'confirmed block', () async {
      var visitorsMinted = 0;
      var playerCalls = 0;
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') {
          visitorsMinted++;
          return fakeVisitorIdResponse('VISITOR_$visitorsMinted');
        }
        playerCalls++;
        return loadYtResponse(YtFixtures.playerBotCheck);
      });

      final result = await _source(transport).detail('dQw4w9WgXcQ');

      expect(result.ok, isFalse);
      expect(result.verdict.cause, YtCause.ipBlocked);
      expect(result.verdict.signal, YtSignals.botCheckConfirmed);
      expect(result.verdict.detail, contains('freshly minted'));
      expect(playerCalls, 2, reason: 'exactly one retry, not a loop');
      expect(visitorsMinted, 2);
    });

    test('an AGE GATE is never retried and never becomes a block', () async {
      var playerCalls = 0;
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
        playerCalls++;
        return loadYtResponse(YtFixtures.playerAgeGate);
      });

      final result = await _source(transport).detail('HtVdAasjOgU');

      expect(result.verdict.cause, YtCause.contentUnavailable);
      expect(result.verdict.signal, 'playability:age-gate');
      expect(
        playerCalls,
        1,
        reason: 'no wasted re-mint on a content verdict',
      );
    });

    test(
      'a failed re-mint surfaces the mint failure, not a fake block',
      () async {
        var visitorsMinted = 0;
        final transport = FakeYtTransport((req) {
          if (req.endpoint == 'visitor_id') {
            visitorsMinted++;
            return visitorsMinted == 1
                ? fakeVisitorIdResponse()
                : YtResponse.transportFailure('timeout');
          }
          return loadYtResponse(YtFixtures.playerBotCheck);
        });

        final result = await _source(transport).detail('dQw4w9WgXcQ');
        expect(result.verdict.cause, YtCause.transient);
        expect(result.verdict.signal, 'transport');
      },
    );

    test('a visitorData that cannot be minted at all fails before the player '
        'call', () async {
      var playerCalls = 0;
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') {
          return YtResponse.recorded(const {
            'responseContext': <String, dynamic>{},
          });
        }
        playerCalls++;
        return loadYtResponse(YtFixtures.playerOk);
      });

      final result = await _source(transport).detail('dQw4w9WgXcQ');
      expect(result.verdict.cause, YtCause.clientBroken);
      expect(result.verdict.signal, 'no-visitorData');
      expect(playerCalls, 0);
    });

    test(
      'the visitorData is reused across calls, not re-minted each time',
      () async {
        var visitorsMinted = 0;
        final transport = FakeYtTransport((req) {
          if (req.endpoint == 'visitor_id') {
            visitorsMinted++;
            return fakeVisitorIdResponse();
          }
          return loadYtResponse(YtFixtures.playerOk);
        });
        final source = _source(transport);
        await source.detail('dQw4w9WgXcQ');
        await source.detail('dQw4w9WgXcQ');
        await source.detail('dQw4w9WgXcQ');
        expect(visitorsMinted, 1);
        expect(transport.to('player'), hasLength(3));
      },
    );
  });

  group('verdicts the direct source passes through', () {
    Future<YtResult<YtStreamPair>> streamsWith(String fixture) {
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
        return loadYtResponse(fixture);
      });
      return _source(transport).streams('dQw4w9WgXcQ');
    }

    test('a dead video is contentUnavailable', () async {
      final r = await streamsWith(YtFixtures.playerDead);
      expect(r.verdict.cause, YtCause.contentUnavailable);
    });

    test('the SABR shape is clientBroken', () async {
      final r = await streamsWith(YtFixtures.playerSabr);
      expect(r.verdict.cause, YtCause.clientBroken);
      expect(r.verdict.signal, 'sabr-only');
    });

    test(
      'a retired client version is clientBroken via the RPC envelope',
      () async {
        final transport = FakeYtTransport((req) {
          if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
          return loadYtResponse(YtFixtures.playerRpc404, status: 404);
        });
        final r = await _source(transport).streams('dQw4w9WgXcQ');
        expect(r.verdict.cause, YtCause.clientBroken);
        expect(r.verdict.signal, 'rpc-error:NOT_FOUND');
      },
    );

    test('an all-cipher response is clientBroken, not a silent skip', () async {
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
        return syntheticPlayer(
          status: 'OK',
          videoDetails: const {'videoId': 'dQw4w9WgXcQ', 'title': 't'},
          streamingData: {
            'expiresInSeconds': '21540',
            'adaptiveFormats': [
              fakeFormat(
                itag: 137,
                mimeType: 'video/mp4; codecs="avc1.640028"',
                url: null,
                signatureCipher: 's=abc&sp=sig&url=https%3A%2F%2Fx.invalid',
              ),
              fakeFormat(
                itag: 140,
                mimeType: 'audio/mp4; codecs="mp4a.40.2"',
                url: null,
                signatureCipher: 's=def&sp=sig&url=https%3A%2F%2Fx.invalid',
              ),
            ],
          },
        );
      });
      final r = await _source(transport).streams('dQw4w9WgXcQ');
      expect(r.verdict.cause, YtCause.clientBroken);
      expect(r.verdict.signal, 'needs-javascript');
    });

    test('a response with no usable pair is clientBroken', () async {
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
        return syntheticPlayer(
          status: 'OK',
          videoDetails: const {'videoId': 'dQw4w9WgXcQ', 'title': 't'},
          streamingData: {
            'expiresInSeconds': '21540',
            'adaptiveFormats': [
              fakeFormat(
                itag: 137,
                mimeType: 'video/mp4; codecs="avc1.640028"',
                width: 1920,
                height: 1080,
              ),
            ],
          },
        );
      });
      final r = await _source(transport).streams('dQw4w9WgXcQ');
      expect(r.verdict.cause, YtCause.clientBroken);
      expect(r.verdict.signal, 'no-playable-pair');
    });
  });

  group('browse-side calls', () {
    test('search parses the recorded page', () async {
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
        return YtResponse.recorded(loadYtFixture(YtFixtures.search));
      });
      final r = await _source(transport).search('flutter tutorial');
      expect(r.ok, isTrue);
      expect(r.value!.items, isNotEmpty);
      expect(r.value!.hasMore, isTrue);
    });

    test(
      'a search that parses to nothing at all is clientBroken, not empty',
      () async {
        final transport = FakeYtTransport((req) {
          if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
          return YtResponse.recorded(const {'contents': <String, dynamic>{}});
        });
        final r = await _source(transport).search('anything');
        expect(r.verdict.cause, YtCause.clientBroken);
        expect(r.verdict.signal, 'search-no-items');
      },
    );

    test('related returns the shelf and the comments door', () async {
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
        return YtResponse.recorded(loadYtFixture(YtFixtures.next));
      });
      final r = await _source(transport).related('dQw4w9WgXcQ');
      expect(r.ok, isTrue);
      expect(r.value!.related, isNotEmpty);
      expect(r.value!.commentsToken, isNotNull);
      expect(transport.to('next').single.jsonBody['videoId'], 'dQw4w9WgXcQ');
    });

    test('comments parse from a continuation token', () async {
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
        return YtResponse.recorded(loadYtFixture(YtFixtures.nextComments));
      });
      final r = await _source(transport).comments('TOKEN');
      expect(r.ok, isTrue);
      expect(r.value!.items, isNotEmpty);
      expect(transport.to('next').single.jsonBody['continuation'], 'TOKEN');
    });
  });

  group('caption content', () {
    const track = YtCaptionTrack(
      languageCode: 'en',
      baseUrl: 'https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=en',
      vssId: '.en',
      name: 'English',
      translatable: true,
    );

    Future<YtResult<String>> fetch(
      YtResponse response, {
      YtCaptionFormat format = YtCaptionFormat.vtt,
    }) {
      final transport = FakeYtTransport((req) => response);
      return _source(transport).captionContent(track, format: format);
    }

    // The bug the live run caught: a JSON-expecting classifier calls a
    // perfectly good VTT `unparseable`.
    test('a WEBVTT body is returned, not rejected', () async {
      final r = await fetch(
        YtResponse(
          status: 200,
          headers: const {'content-type': 'text/vtt; charset=utf-8'},
          body: utf8.encode('WEBVTT\n\n00:00:01.360 --> 00:00:03.040\n[♪♪♪]'),
        ),
      );
      expect(r.ok, isTrue);
      expect(r.value, startsWith('WEBVTT'));
    });

    test('a TTML body is returned despite starting with <', () async {
      final r = await fetch(
        YtResponse(
          status: 200,
          headers: const {'content-type': 'text/xml; charset=utf-8'},
          body: utf8.encode('<?xml version="1.0"?><tt><body/></tt>'),
        ),
        format: YtCaptionFormat.ttml,
      );
      expect(r.ok, isTrue);
      expect(r.value, startsWith('<?xml'));
    });

    test('the request goes to the signed baseUrl with fmt appended', () async {
      final transport = FakeYtTransport(
        (req) => YtResponse(
          status: 200,
          headers: const {'content-type': 'text/vtt'},
          body: utf8.encode('WEBVTT'),
        ),
      );
      await _source(transport).captionContent(
        track,
        format: YtCaptionFormat.srv3,
        translateTo: 'de',
      );
      final req = transport.requests.single;
      expect(req.method, 'GET');
      expect(req.url.queryParameters['fmt'], 'srv3');
      expect(req.url.queryParameters['tlang'], 'de');
      expect(req.body, isNull);
    });

    test('a 200 with zero bytes is reported, never returned as ""', () async {
      final r = await fetch(
        YtResponse(status: 200, headers: const {}, body: const []),
      );
      expect(r.ok, isFalse);
      expect(r.value, isNull, reason: 'never an empty caption');
      expect(r.verdict.cause, YtCause.transient);
      expect(r.verdict.signal, 'empty-200');
    });

    test('the measured tlang rate limit surfaces as ipBlocked', () async {
      final r = await fetch(
        YtResponse(
          status: 429,
          headers: const {'content-type': 'text/html; charset=UTF-8'},
          body: utf8.encode('<html><title>Sorry...</title></html>'),
        ),
      );
      expect(r.verdict.cause, YtCause.ipBlocked);
      expect(r.verdict.signal, 'http-429');
    });
  });

  group('probe', () {
    test('is one visitor_id POST, not a player call', () async {
      final transport = FakeYtTransport((req) {
        if (req.endpoint == 'visitor_id') return fakeVisitorIdResponse();
        return loadYtResponse(YtFixtures.playerOk);
      });
      final verdict = await _source(transport).probe();
      expect(verdict.cause, YtCause.ok);
      expect(transport.to('visitor_id'), hasLength(1));
      expect(transport.to('player'), isEmpty);
    });

    test('reports a block when the mint itself is walled off', () async {
      final transport = FakeYtTransport(
        (req) => YtResponse(
          status: 429,
          headers: const {'content-type': 'text/html'},
          body: utf8.encode('<html><title>Sorry...</title></html>'),
        ),
      );
      final verdict = await _source(transport).probe();
      expect(verdict.cause, YtCause.ipBlocked);
    });
  });
}
