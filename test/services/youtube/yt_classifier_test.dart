import 'dart:convert';

import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

import 'yt_test_support.dart';

YtResponse _raw(
  int status, {
  String body = '',
  Map<String, String> headers = const {},
  bool parseJson = true,
}) {
  final bytes = utf8.encode(body);
  Object? json;
  if (parseJson && body.isNotEmpty) {
    try {
      json = jsonDecode(body);
    } catch (_) {}
  }
  return YtResponse(
    status: status,
    headers: headers,
    body: bytes,
    json: json,
  );
}

void main() {
  group('classifyYtTransport', () {
    test('status 0 is transient and carries the socket error', () {
      final v = classifyYtTransport(
        YtResponse.transportFailure('SocketException: host lookup failed'),
      );
      expect(v!.cause, YtCause.transient);
      expect(v.signal, 'transport');
      expect(v.detail, contains('SocketException'));
    });

    test('a healthy JSON 200 returns null (keep going)', () {
      expect(classifyYtTransport(loadYtResponse(YtFixtures.playerOk)), isNull);
    });

    // THE trap this taxonomy exists for. A retired clientVersion answers 404.
    // A status-first client reads that as "video gone" and hands it to the
    // fallback, hiding its own breakage behind a third party.
    test(
      'RECORDED 404 carrying the Google-RPC envelope is clientBroken, '
      'not "video unavailable"',
      () {
        final v = classifyYtTransport(
          loadYtResponse(YtFixtures.playerRpc404, status: 404),
        );
        expect(v, isNotNull);
        expect(v!.cause, YtCause.clientBroken);
        expect(v.signal, 'rpc-error:NOT_FOUND');
        expect(v.detail, contains('404'));
        expect(v.cause, isNot(YtCause.contentUnavailable));
        expect(v.cause, isNot(YtCause.ipBlocked));
      },
    );

    test('the RPC envelope wins even on a 200', () {
      final v = classifyYtTransport(
        _raw(
          200,
          body:
              '{"error":{"code":400,"status":"INVALID_ARGUMENT",'
              '"message":"bad clientName"}}',
        ),
      );
      expect(v!.cause, YtCause.clientBroken);
      expect(v.signal, 'rpc-error:INVALID_ARGUMENT');
    });

    test('404 with no envelope and no body is a wrong endpoint path', () {
      final v = classifyYtTransport(_raw(404));
      expect(v!.cause, YtCause.clientBroken);
      expect(v.signal, 'http-404');
      expect(v.detail, contains('endpoint path'));
    });

    test('404 with a non-JSON body reports the body', () {
      final v = classifyYtTransport(_raw(404, body: 'nope'));
      expect(v!.cause, YtCause.clientBroken);
      expect(v.signal, 'http-404');
      expect(v.detail, 'nope');
    });

    test('429 is ipBlocked', () {
      final v = classifyYtTransport(_raw(429, body: '<html>Sorry...</html>'));
      expect(v!.cause, YtCause.ipBlocked);
      expect(v.signal, 'http-429');
    });

    test('403 carrying HTML/captcha is ipBlocked', () {
      final v = classifyYtTransport(
        _raw(
          403,
          body: '<html><body>detected unusual traffic</body></html>',
          headers: const {'content-type': 'text/html'},
        ),
      );
      expect(v!.cause, YtCause.ipBlocked);
      expect(v.signal, 'http-403+html');
    });

    test('403 carrying JSON is clientBroken, not a block', () {
      final v = classifyYtTransport(_raw(403, body: '{"ok":false}'));
      expect(v!.cause, YtCause.clientBroken);
      expect(v.signal, 'http-403+json');
    });

    test('400 is clientBroken', () {
      expect(
        classifyYtTransport(_raw(400, body: '{"a":1}'))!.signal,
        'http-400',
      );
    });

    test('5xx is transient', () {
      for (final s in [500, 502, 503]) {
        final v = classifyYtTransport(_raw(s, body: 'x'));
        expect(v!.cause, YtCause.transient, reason: 'status $s');
        expect(v.signal, 'http-$s');
      }
    });

    test('a consent redirect is clientBroken (our SOCS cookie is missing)', () {
      final v = classifyYtTransport(
        _raw(302, headers: const {'location': 'https://consent.youtube.com/m'}),
      );
      expect(v!.cause, YtCause.clientBroken);
      expect(v.signal, 'redirect-consent');
    });

    test('a /sorry/ redirect is ipBlocked', () {
      final v = classifyYtTransport(
        _raw(
          302,
          headers: const {'location': 'https://www.google.com/sorry/index'},
        ),
      );
      expect(v!.cause, YtCause.ipBlocked);
      expect(v.signal, 'redirect-sorry');
    });

    test('any other redirect is clientBroken', () {
      final v = classifyYtTransport(
        _raw(307, headers: const {'location': 'https://example.invalid/'}),
      );
      expect(v!.cause, YtCause.clientBroken);
      expect(v.signal, 'redirect-307');
    });

    test('200 with zero bytes is transient', () {
      final v = classifyYtTransport(_raw(200));
      expect(v!.cause, YtCause.transient);
      expect(v.signal, 'empty-200');
    });

    test('200 HTML with a captcha marker is ipBlocked', () {
      final v = classifyYtTransport(
        _raw(
          200,
          body: '<html><title>Sorry...</title>/sorry/index</html>',
          headers: const {'content-type': 'text/html; charset=UTF-8'},
        ),
      );
      expect(v!.cause, YtCause.ipBlocked);
      expect(v.signal, 'html-captcha');
    });

    test('200 HTML without one is clientBroken', () {
      final v = classifyYtTransport(
        _raw(200, body: '<html><body>hello</body></html>'),
      );
      expect(v!.cause, YtCause.clientBroken);
      expect(v.signal, 'html-where-json');
    });

    test('200 with an unparseable body is clientBroken', () {
      final v = classifyYtTransport(_raw(200, body: 'not json at all'));
      expect(v!.cause, YtCause.clientBroken);
      expect(v.signal, 'unparseable');
    });

    // Caption content is not JSON: vtt is plain text, ttml/srv3 are XML. A
    // JSON-expecting classifier calls a perfectly good caption `unparseable`,
    // and an XML one `html-where-json` because it starts with `<`. Found by
    // running the ported client against the live service.
    group('expectJson: false (caption fetches)', () {
      test('a WEBVTT body passes', () {
        final v = classifyYtTransport(
          _raw(
            200,
            body: 'WEBVTT\n\n00:00:01.360 --> 00:00:03.040\n[music]',
            headers: const {'content-type': 'text/vtt; charset=utf-8'},
          ),
          expectJson: false,
        );
        expect(v, isNull);
      });

      test('a TTML/XML body passes despite starting with <', () {
        final v = classifyYtTransport(
          _raw(
            200,
            body:
                '<?xml version="1.0"?><tt xmlns="http://www.w3.org/ns/ttml">'
                '<body><div><p begin="1s">hi</p></div></body></tt>',
            headers: const {'content-type': 'text/xml; charset=utf-8'},
          ),
          expectJson: false,
        );
        expect(v, isNull);
      });

      test('but a /sorry/ interstitial is STILL caught', () {
        // The one real rate limit measured arrived on a caption fetch.
        final v = classifyYtTransport(
          _raw(
            200,
            body: '<html><title>Sorry...</title>/sorry/index</html>',
            headers: const {'content-type': 'text/html; charset=UTF-8'},
          ),
          expectJson: false,
        );
        expect(v!.cause, YtCause.ipBlocked);
        expect(v.signal, 'html-captcha');
      });

      test('and a 429 is still a 429', () {
        final v = classifyYtTransport(_raw(429), expectJson: false);
        expect(v!.cause, YtCause.ipBlocked);
      });
    });
  });

  group('classifyYtPlayer — recorded responses', () {
    test('RECORDED healthy player response is ok', () {
      final v = classifyYtPlayer(loadYtResponse(YtFixtures.playerOk));
      expect(v.cause, YtCause.ok);
      expect(v.suspectClient, isFalse);
    });

    test('RECORDED dead id is contentUnavailable and NOT suspect', () {
      final v = classifyYtPlayer(loadYtResponse(YtFixtures.playerDead));
      expect(v.cause, YtCause.contentUnavailable);
      // videoDetails is absent, so the server is talking about the video.
      expect(v.suspectClient, isFalse);
      expect(v.signal, 'playability:error');
    });

    // The disambiguation. PipePipe raises AntiBotException on any body
    // containing "Sign in to confirm"; the age gate says "Sign in to confirm
    // your age". A client built that way falls back to a third party on EVERY
    // age-restricted video.
    test('RECORDED age gate is contentUnavailable, NOT ipBlocked', () {
      final r = loadYtResponse(YtFixtures.playerAgeGate);
      // Guard the premise: the fixture really does start with those words.
      final reason = ((r.obj['playabilityStatus'] as Map)['reason'] ?? '')
          .toString();
      expect(reason, startsWith('Sign in to confirm'));
      expect(reason, contains('your age'));

      final v = classifyYtPlayer(r);
      expect(v.cause, YtCause.contentUnavailable);
      expect(v.signal, 'playability:age-gate');
      expect(v.cause, isNot(YtCause.ipBlocked));
    });

    test('RECORDED bot wall is ipBlocked with the un-confirmed signal', () {
      final r = loadYtResponse(YtFixtures.playerBotCheck);
      final reason = ((r.obj['playabilityStatus'] as Map)['reason'] ?? '')
          .toString();
      expect(reason, startsWith('Sign in to confirm'));
      expect(reason, contains('not a bot'));

      final v = classifyYtPlayer(r);
      expect(v.cause, YtCause.ipBlocked);
      // NOT the confirmed signal: only YtDirectSource, after re-minting a
      // visitorData, may produce that.
      expect(v.signal, YtSignals.botCheck);
      expect(v.signal, isNot(YtSignals.botCheckConfirmed));
    });

    test(
      'RECORDED wrong-identity "Video unavailable" is contentUnavailable '
      'but flagged suspect (videoDetails came back)',
      () {
        final r = loadYtResponse(YtFixtures.playerWebGeneric);
        expect(r.obj['videoDetails'], isNotNull);

        final v = classifyYtPlayer(r);
        expect(v.cause, YtCause.contentUnavailable);
        expect(v.signal, 'playability:unplayable-generic');
        expect(v.suspectClient, isTrue);
      },
    );

    test('RECORDED SABR-only response is clientBroken, not ok', () {
      final r = loadYtResponse(YtFixtures.playerSabr);
      // Premise: status OK, adaptive formats present, none with a url — but a
      // single muxed itag-18 leftover DOES have one. Pooling the two arrays
      // would let that 360p leftover mask the failure.
      expect((r.obj['playabilityStatus'] as Map)['status'], 'OK');
      final sd = r.obj['streamingData'] as Map;
      final adaptive = sd['adaptiveFormats'] as List;
      expect(adaptive, isNotEmpty);
      expect(adaptive.every((f) => (f as Map)['url'] == null), isTrue);
      expect(
        (sd['formats'] as List).any((f) => (f as Map)['url'] != null),
        isTrue,
        reason: 'the muxed leftover this branch has to see past',
      );

      final v = classifyYtPlayer(r);
      expect(v.cause, YtCause.clientBroken);
      expect(v.signal, 'sabr-only');
      expect(v.detail, contains('muxed'));
    });

    test(
      'a URL-less response with no muxed array at all is also sabr-only',
      () {
        final v = classifyYtPlayer(
          syntheticPlayer(
            status: 'OK',
            videoDetails: const {'videoId': 'aaaaaaaaaaa'},
            streamingData: {
              'serverAbrStreamingUrl': 'https://x.invalid/abr',
              'adaptiveFormats': [
                fakeFormat(
                  itag: 137,
                  mimeType: 'video/mp4; codecs="avc1.640028"',
                  url: null,
                ),
              ],
            },
          ),
        );
        expect(v.cause, YtCause.clientBroken);
        expect(v.signal, 'sabr-only');
      },
    );
  });

  group('classifyYtPlayer — synthetic branches', () {
    test('an empty object is clientBroken', () {
      final v = classifyYtPlayer(
        YtResponse.recorded(const <String, dynamic>{}),
      );
      expect(v.cause, YtCause.clientBroken);
      expect(v.signal, 'not-an-object');
    });

    test('explicit throttle wording is ipBlocked', () {
      final v = classifyYtPlayer(
        syntheticPlayer(status: 'ERROR', reason: 'We detected unusual traffic'),
      );
      expect(v.cause, YtCause.ipBlocked);
      expect(v.signal, 'playability:throttle');
    });

    test('login_required + "private" is a private video', () {
      final v = classifyYtPlayer(
        syntheticPlayer(
          status: 'LOGIN_REQUIRED',
          reason: 'This video is private',
        ),
      );
      expect(v.cause, YtCause.contentUnavailable);
      expect(v.signal, 'playability:private');
    });

    test('login_required with NewPipe\'s age wording is also an age gate', () {
      final v = classifyYtPlayer(
        syntheticPlayer(
          status: 'LOGIN_REQUIRED',
          reason: 'This video may be inappropriate for some users.',
        ),
      );
      expect(v.signal, 'playability:age-gate');
    });

    test(
      'login_required with an unrecognised reason stays (a): a block must be '
      'proven, never assumed',
      () {
        final v = classifyYtPlayer(
          syntheticPlayer(status: 'LOGIN_REQUIRED', reason: 'Something new'),
        );
        expect(v.cause, YtCause.contentUnavailable);
        expect(v.signal, 'playability:login_required');
      },
    );

    test('named content states are recognised and not flagged suspect', () {
      const cases = {
        'This video is available to members': 'playability:members-only',
        'This video requires payment to watch': 'playability:paid',
        'The uploader has not made this video available in your country':
            'playability:geo-blocked',
        'This account has been terminated': 'playability:account-terminated',
        "We're processing this video. Check back later.":
            'playability:processing',
      };
      cases.forEach((reason, signal) {
        final v = classifyYtPlayer(
          syntheticPlayer(
            status: 'UNPLAYABLE',
            reason: reason,
            videoDetails: const {'videoId': 'aaaaaaaaaaa'},
          ),
        );
        expect(v.signal, signal, reason: reason);
        expect(v.suspectClient, isFalse, reason: reason);
      });
    });

    test('the reason can also come out of errorScreen', () {
      final v = classifyYtPlayer(
        syntheticPlayer(
          status: 'UNPLAYABLE',
          extraPlayability: const {
            'errorScreen': {
              'playerErrorMessageRenderer': {
                'subreason': {
                  'runs': [
                    {'text': 'This video is available to members only'},
                  ],
                },
              },
            },
          },
        ),
      );
      expect(v.signal, 'playability:members-only');
    });

    test('OK with no videoDetails is clientBroken', () {
      final v = classifyYtPlayer(syntheticPlayer(status: 'OK'));
      expect(v.cause, YtCause.clientBroken);
      expect(v.signal, 'ok-but-no-videoDetails');
    });

    test('OK with videoDetails but no streamingData is clientBroken', () {
      final v = classifyYtPlayer(
        syntheticPlayer(
          status: 'OK',
          videoDetails: const {'videoId': 'aaaaaaaaaaa'},
        ),
      );
      expect(v.cause, YtCause.clientBroken);
      expect(v.signal, 'ok-but-no-streamingData');
    });

    test('OK with empty format arrays is clientBroken', () {
      final v = classifyYtPlayer(
        syntheticPlayer(
          status: 'OK',
          videoDetails: const {'videoId': 'aaaaaaaaaaa'},
          streamingData: const {
            'adaptiveFormats': <dynamic>[],
            'formats': <dynamic>[],
          },
        ),
      );
      expect(v.cause, YtCause.clientBroken);
      expect(v.signal, 'streamingData-empty');
    });

    test(
      'a signatureCipher-only format is NOT sabr-only (it is decipherable)',
      () {
        final v = classifyYtPlayer(
          syntheticPlayer(
            status: 'OK',
            videoDetails: const {'videoId': 'aaaaaaaaaaa'},
            streamingData: {
              'adaptiveFormats': [
                fakeFormat(
                  itag: 137,
                  mimeType: 'video/mp4; codecs="avc1.640028"',
                  url: null,
                  signatureCipher: 's=abc&sp=sig&url=https://x.invalid/',
                ),
              ],
            },
          ),
        );
        // The classifier passes it; selecting formats is what rejects it, as
        // (d) needs-javascript. See yt_format_select_test.dart.
        expect(v.cause, YtCause.ok);
      },
    );

    test('a status absent entirely with formats present is ok', () {
      final v = classifyYtPlayer(
        YtResponse.recorded({
          'videoDetails': const {'videoId': 'aaaaaaaaaaa'},
          'streamingData': {
            'adaptiveFormats': [
              fakeFormat(itag: 140, mimeType: 'audio/mp4; codecs="mp4a.40.2"'),
            ],
          },
        }),
      );
      expect(v.cause, YtCause.ok);
    });
  });
}
