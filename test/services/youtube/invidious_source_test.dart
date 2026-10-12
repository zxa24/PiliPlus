import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:flutter_test/flutter_test.dart';

/// `inv.nadeko.net` as a source, from pages recorded there 2026-10-12
/// (`test/fixtures/youtube/invidious/`, `ip=` redacted). No network.
void main() {
  String fixture(String name) =>
      File('test/fixtures/youtube/invidious/$name').readAsStringSync();

  group('go-away', () {
    test('the proof-of-work page names its script, the script its id', () {
      final page = fixture('goaway_pow.html');
      expect(GoAway.isChallenge(page), isTrue);
      expect(GoAway.challengeName(page), 'js-pow-sha256');
      expect(
        GoAway.powScript(page),
        startsWith('${GoAway.powPath}/script.mjs'),
      );
      expect(
        GoAway.powId(fixture('goaway_pow_script.mjs')),
        '5c77285484e9afaafb7179dc2985f8b0',
      );
      expect(GoAway.refreshUrl(page), isNull);
    });

    test('the refresh page sends the browser to its own verify URL', () {
      final page = fixture('goaway_refresh.html');
      expect(GoAway.isChallenge(page), isTrue);
      expect(GoAway.powScript(page), isNull);
      final url = GoAway.refreshUrl(page)!;
      expect(url, startsWith('${GoAway.prefix}/challenge/js-refresh/verify-challenge?'));
      expect(url, isNot(contains(r'\u0026')));
      expect(url, contains('&__goaway_id='));
      final query = Uri.parse(url).queryParameters;
      expect(query['__goaway_challenge'], 'js-refresh');
      expect(query['v'], 'dQw4w9WgXcQ');
    });

    test('the measured challenge solves at the measured nonce', () {
      // 2026-10-12, difficulty 12: nonce 3398 (python, the same algorithm)
      const challenge =
          '3331669fd313a614d58dc3d90f5750dbcf244551ec59628900e75db519a248ff';
      final token = GoAway.solve(
        challenge,
        '000fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
      );
      // 3398 = 0x0d46, eight bytes little-endian
      expect(token, '${challenge}460d000000000000');
    });

    test('a target out of reach gives up rather than spinning', () {
      expect(
        GoAway.solve('00', '0' * 63 + '1', maxIterations: 1000),
        isNull,
      );
      expect(GoAway.solve('zz', 'ff' * 32), isNull);
    });

    test('a watch page is not a challenge', () {
      expect(GoAway.isChallenge(fixture('watch_dQw4w9WgXcQ.html')), isFalse);
    });
  });

  group('the watch page', () {
    test('what the video page needs, from the page the instance serves', () {
      final watch = parseInvidiousWatch(
        fixture('watch_dQw4w9WgXcQ.html'),
        'dQw4w9WgXcQ',
      )!;
      expect(watch.title, startsWith('Rick Astley - Never Gonna Give You Up'));
      expect(watch.author, 'Rick Astley');
      expect(watch.channelId, 'UCuAXFkgsw1L7xaCfnd5JJOw');
      expect(watch.duration, const Duration(seconds: 214));
      expect(watch.viewCount, 1825862361);
      expect(watch.isLive, isFalse);
      expect(watch.description, contains('Never Gonna Give You Up'));
      expect(watch.captions, hasLength(6));
      expect(watch.captions.first.label, 'English');
      expect(watch.captions.first.url, contains('/companion/api/v1/captions/'));
      expect(watch.captions.first.url, isNot(contains('&amp;')));
    });

    test("the manifest without local=true: googlevideo's own URLs", () {
      final watch = parseInvidiousWatch(
        fixture('watch_dQw4w9WgXcQ.html'),
        'dQw4w9WgXcQ',
      )!;
      expect(watch.dashUrl, contains('/companion/api/manifest/dash/id/dQw4w9WgXcQ?'));
      expect(watch.dashUrl, isNot(contains('local=')));
      expect(watch.dashUrl, contains('check='));
    });

    test('a challenge page is not a watch page', () {
      expect(parseInvidiousWatch(fixture('goaway_pow.html'), 'x'), isNull);
    });

    test('withoutLocal takes the parameter out wherever it is', () {
      expect(withoutLocal('https://h/a?local=true&b=1'), 'https://h/a?b=1');
      expect(withoutLocal('https://h/a?b=1&local=true'), 'https://h/a?b=1');
      expect(withoutLocal('https://h/a?b=1&local=true&c=2'), 'https://h/a?b=1&c=2');
      expect(withoutLocal('https://h/a?b=1'), 'https://h/a?b=1');
    });

    test('caption languages from the caption list, by label', () {
      final watch = parseInvidiousWatch(
        fixture('watch_dQw4w9WgXcQ.html'),
        'dQw4w9WgXcQ',
      )!;
      final codes = invidiousCaptionCodes(
        jsonDecode(fixture('captions_dQw4w9WgXcQ.json')),
      );
      final tracks = invidiousCaptionTracks(watch, codes);
      expect(tracks.map((t) => t.languageCode), [
        'en',
        'en',
        'de-DE',
        'ja',
        'pt-BR',
        'es-419',
      ]);
      expect(tracks[0].isAutomatic, isFalse);
      expect(tracks[1].isAutomatic, isTrue);
      expect(invidiousCaptionTracks(watch).first.languageCode, '');
    });
  });

  group('the manifest', () {
    test('every stream, playable: the n= is worked out', () {
      final formats = parseInvidiousDash(fixture('dash_dQw4w9WgXcQ.mpd'));
      expect(formats, hasLength(13));
      expect(formats.every((f) => f.url!.contains('googlevideo.com')), isTrue);
      expect(formats.any((f) => Uri.parse(f.url!).queryParameters.containsKey('n')), isTrue);
      expect(formats.every((f) => f.isPlayable), isTrue);
      final f137 = formats.firstWhere((f) => f.itag == 137);
      expect(f137.codecFamily, 'avc1');
      expect(f137.height, 1080);
      expect(f137.contentLength, isNotNull);
    });

    test('the standard pick: 1080p AVC and the one audio track', () {
      final pick = selectYtFormats(
        parseInvidiousDash(fixture('dash_dQw4w9WgXcQ.mpd')),
      )!;
      expect(pick.video.itag, 137);
      expect(pick.audio.itag, 140);
      expect(pick.audio.audioTrackId, isNull);
    });

    test('of 22 audio tracks, the original, not its drc copy or a dub', () {
      final formats = parseInvidiousDash(fixture('dash_xQlKGiIwhF4_dubs.mpd'));
      final audio = formats.where((f) => f.isAudio).toList();
      expect(audio, hasLength(21), reason: 'the -drc copy left out');
      expect(audio.where((f) => f.audioIsDefault), hasLength(1));
      final pick = selectYtAudioFormat(formats)!;
      expect(pick.audioTrackId, 'en-US.4');
      expect(pick.audioIsDefault, isTrue);
      expect(pick.audioTrackName, contains('original'));
    });

    test('a portrait video capped by its short side', () {
      final formats = parseInvidiousDash(fixture('dash_xQlKGiIwhF4_dubs.mpd'));
      final pick = selectYtVideoFormat(
        formats,
        const YtFormatPreference(maxHeight: 480),
      )!;
      expect(pick.width, 480);
      expect(pick.codecFamily, 'avc1');
    });

    test('expiry from the URLs', () {
      final at = invidiousExpiry(parseInvidiousDash(fixture('dash_dQw4w9WgXcQ.mpd')));
      expect(at, DateTime.fromMillisecondsSinceEpoch(1791840790 * 1000));
    });
  });

  test('a format whose n= nobody worked out is still the throttled kind', () {
    final f = YtFormat({
      'itag': 140,
      'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
      'url': 'https://x.googlevideo.com/videoplayback?n=abc',
    });
    expect(f.isPlayable, isFalse);
  });
}
