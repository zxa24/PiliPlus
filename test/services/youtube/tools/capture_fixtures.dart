// Stdlib-only fixture recorder for the LibrePili YouTube stage-1 tests.
// Lives OUTSIDE the repo; writes pruned, redacted real responses into
// test/fixtures/youtube/. Nothing but the bare 11-char video id leaves here.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const outDir =
    r'C:\Users\Z14\Documents\Coding\Piliplus\test\fixtures\youtube';

const gapis = 'https://youtubei.googleapis.com/youtubei/v1/';
const web = 'https://www.youtube.com/youtubei/v1/';
const alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
final rng = Random.secure();
String nonce(int n) =>
    List.generate(n, (_) => alphabet[rng.nextInt(alphabet.length)]).join();

Map<String, dynamic> ctx(
  String name,
  String version, {
  String? visitorData,
  String? screen,
  String? platform,
  String? make,
  String? model,
  String? osName,
  String? osVersion,
}) => {
  'context': {
    'client': {
      'clientName': name,
      'clientVersion': version,
      if (screen != null) 'clientScreen': screen,
      if (platform != null) 'platform': platform,
      if (visitorData != null) 'visitorData': visitorData,
      if (make != null) 'deviceMake': make,
      if (model != null) 'deviceModel': model,
      if (osName != null) 'osName': osName,
      if (osVersion != null) 'osVersion': osVersion,
      'hl': 'en-GB',
      'gl': 'GB',
      'utcOffsetMinutes': 0,
    },
    'request': {'internalExperimentFlags': <dynamic>[], 'useSsl': true},
    'user': {'lockedSafetyMode': false},
  },
};

const visionUa = 'com.google.visionos.youtube/1.04(RealityDevice17,1; U; '
    'CPU visionOS 26_6_0 like Mac OS X; GB)';
const desktopUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) '
    'Gecko/20100101 Firefox/140.0';

Map<String, String> visionHeaders = {
  'User-Agent': visionUa,
  'X-Goog-Api-Format-Version': '2',
};
Map<String, String> webHeaders = {
  'User-Agent': desktopUa,
  'Origin': 'https://www.youtube.com',
  'Referer': 'https://www.youtube.com',
  'X-YouTube-Client-Name': '1',
  'X-YouTube-Client-Version': '2.20260805.01.00',
  'Cookie': 'SOCS=CAISAiAD',
};

final http = HttpClient()..autoUncompress = true;

Future<(int, Object?)> post(
  String base,
  String endpoint,
  Map<String, String> headers,
  Map<String, dynamic> body, {
  String q = '',
}) async {
  final url = Uri.parse('$base$endpoint?prettyPrint=false$q');
  final req = await http.openUrl('POST', url);
  req.followRedirects = false;
  headers.forEach(req.headers.set);
  final bytes = utf8.encode(jsonEncode(body));
  req.headers
    ..set(HttpHeaders.contentTypeHeader, 'application/json')
    ..set(HttpHeaders.contentLengthHeader, '${bytes.length}');
  req.add(bytes);
  final res = await req.close();
  final raw = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
  final text = utf8.decode(raw, allowMalformed: true);
  Object? j;
  try {
    j = jsonDecode(text);
  } catch (_) {}
  stderr.writeln('  $endpoint -> ${res.statusCode} ${raw.length}B');
  return (res.statusCode, j);
}

/// visitorData is CLIENT-SCOPED: a blob minted with the VISIONOS context makes
/// a WEB/ANDROID player call answer 404 NOT_FOUND. Mint one per identity.
Future<String?> mintVisitor([String client = 'VISIONOS']) async {
  final (_, j) = await post(
    web,
    'visitor_id',
    _headersFor(client),
    _ctxFor(client, null),
  );
  return ((j as Map?)?['responseContext'] as Map?)?['visitorData'] as String?;
}

Map<String, dynamic> _ctxFor(String client, String? visitor) =>
    switch (client) {
      'VISIONOS' => ctx(
        'VISIONOS',
        '1.04',
        visitorData: visitor,
        screen: 'WATCH',
        platform: 'MOBILE',
        make: 'Apple',
        model: 'RealityDevice17,1',
        osName: 'visionOS',
        osVersion: '26.6.0.23O770',
      ),
      'ANDROID' => ctx(
        'ANDROID',
        '21.03.36',
        visitorData: visitor,
        screen: 'WATCH',
        platform: 'MOBILE',
        osName: 'Android',
        osVersion: '15',
      ),
      _ => ctx(
        'WEB',
        '2.20260805.01.00',
        visitorData: visitor,
        screen: 'WATCH',
        platform: 'DESKTOP',
      ),
    };

Map<String, String> _headersFor(String client) => switch (client) {
  'VISIONOS' => visionHeaders,
  'ANDROID' => {
    'User-Agent':
        'com.google.android.youtube/21.03.36 (Linux; U; Android 15; GB) gzip',
    'X-Goog-Api-Format-Version': '2',
  },
  _ => webHeaders,
};

Future<Object?> player(
  String id, {
  String? visitor,
  String client = 'VISIONOS',
  String version = '1.04',
}) async {
  final base = _ctxFor(client, visitor);
  if (version != '1.04') {
    ((base['context'] as Map)['client'] as Map)['clientVersion'] = version;
  }
  final body = <String, dynamic>{
    ...base,
    'videoId': id,
    'cpn': nonce(16),
    'contentCheckOk': true,
    'racyCheckOk': true,
  };
  final isWeb = client == 'WEB';
  final (_, j) = await post(
    isWeb ? web : gapis,
    'player',
    _headersFor(client),
    body,
    q: isWeb ? '' : '&t=${nonce(12)}&id=$id',
  );
  return j;
}

// ------------------------------------------------------------------ pruning

/// Cap every list at [n] elements, recursively.
Object? capLists(Object? o, int n) {
  if (o is Map) {
    return {for (final e in o.entries) e.key: capLists(e.value, n)};
  }
  if (o is List) return o.take(n).map((x) => capLists(x, n)).toList();
  return o;
}

/// Redact the caller's egress IP out of signed stream URLs and truncate them:
/// the tests only need "a plain `url` is present", never a fetchable one.
Object? redactUrls(Object? o, {int keep = 110}) {
  if (o is Map) {
    return {
      for (final e in o.entries)
        e.key: (e.key == 'url' || e.key == 'baseUrl') && e.value is String
            ? _short(e.value as String, keep)
            : redactUrls(e.value, keep: keep),
    };
  }
  if (o is List) return o.map((x) => redactUrls(x, keep: keep)).toList();
  return o;
}

String _short(String u, int keep) {
  var s = u
      .replaceAllMapped(
        RegExp(r'([?&])ip=[^&]*'),
        (m) => '${m[1]}ip=0.0.0.0',
      )
      .replaceAllMapped(
        RegExp(r'([?&])ipbits=[^&]*'),
        (m) => '${m[1]}ipbits=0',
      );
  if (s.length > keep) s = '${s.substring(0, keep)}&truncated=1';
  return s;
}

Map<String, dynamic> prunePlayer(Object? j, {int? capFormats}) {
  final m = (j as Map).cast<String, dynamic>();
  final out = <String, dynamic>{};
  for (final k in const [
    'playabilityStatus',
    'videoDetails',
    'streamingData',
    'captions',
    'error',
  ]) {
    if (m[k] != null) out[k] = m[k];
  }
  Object? pruned = redactUrls(out);
  if (capFormats != null) pruned = capLists(pruned, capFormats);
  return (pruned as Map).cast<String, dynamic>();
}

Future<void> write(String name, Object? j) async {
  final f = File('$outDir${Platform.pathSeparator}$name');
  await f.parent.create(recursive: true);
  await f.writeAsString(const JsonEncoder.withIndent('  ').convert(j));
  stdout.writeln('wrote $name  ${await f.length()} B');
}

Future<void> gap() => Future<void>.delayed(const Duration(milliseconds: 900));

Future<void> main(List<String> args) async {
  final want = args.isEmpty ? const <String>[] : args;
  bool on(String n) => want.isEmpty || want.contains(n);

  final visitor = await mintVisitor();
  final webVisitor = await mintVisitor('WEB');
  stderr.writeln('visitorData: VISIONOS=${visitor?.length} '
      'WEB=${webVisitor?.length} chars');

  if (on('ok')) {
    // dQw4w9WgXcQ: healthy, modest format count. Full detail + captions.
    await write(
      'player_ok.json',
      // NOT capped: capping at 8 kept only video formats (the adaptive array
      // is video-first), which made the audio half of every parser test moot.
      prunePlayer(await player('dQw4w9WgXcQ', visitor: visitor)),
    );
    await gap();
  }
  if (on('formats')) {
    // xQlKGiIwhF4: 120 formats incl. AV1 video and dubbed audio tracks.
    // Lists NOT capped: format selection is exactly what this one tests.
    final j = await player('xQlKGiIwhF4', visitor: visitor);
    await write('player_formats.json', prunePlayer(j));
    await gap();
  }
  if (on('dead')) {
    await write(
      'player_dead.json',
      prunePlayer(await player('AAAAAAAAAAA', visitor: visitor), capFormats: 4),
    );
    await gap();
  }
  if (on('age')) {
    for (final id in const ['HtVdAasjOgU', 'Tq92D6wQ1mg', '6kLq3WMV1nU']) {
      final j = await player(id, visitor: visitor);
      final st = (((j as Map)['playabilityStatus'] as Map?)?['status'] ?? '');
      stderr.writeln('  age candidate $id -> $st');
      if ('$st'.toUpperCase() == 'LOGIN_REQUIRED') {
        await write('player_age_gate.json', prunePlayer(j, capFormats: 4));
        break;
      }
      await gap();
    }
    await gap();
  }
  if (on('bot')) {
    // No visitorData at all: measured to produce the bot wall on 7/8 videos.
    final j = await player('xQlKGiIwhF4');
    final st = (((j as Map)['playabilityStatus'] as Map?)?['status'] ?? '');
    stderr.writeln('  no-visitor -> $st');
    await write('player_bot_check.json', prunePlayer(j, capFormats: 4));
    await gap();
  }
  if (on('webgeneric')) {
    // WEB identity on a healthy video: UNPLAYABLE + videoDetails = suspect (d).
    await write(
      'player_web_generic.json',
      prunePlayer(
        await player('dQw4w9WgXcQ',
            visitor: await mintVisitor('WEB'), client: 'WEB'),
        capFormats: 4,
      ),
    );
    await gap();
  }
  if (on('sabr')) {
    // ANDROID identity: formats with neither url nor signatureCipher.
    await write(
      'player_sabr.json',
      prunePlayer(
        await player('dQw4w9WgXcQ',
            visitor: await mintVisitor('ANDROID'), client: 'ANDROID'),
        capFormats: 6,
      ),
    );
    await gap();
  }
  if (on('rpc404')) {
    // A retired clientVersion answers 404 WITH a Google-RPC error envelope.
    final j = await player('dQw4w9WgXcQ', visitor: visitor, version: '0.01');
    await write('player_rpc_404.json', prunePlayer(j));
    await gap();
  }
  if (on('search')) {
    final (_, j) = await post(web, 'search', webHeaders, {
      ..._ctxFor('WEB', webVisitor),
      'query': 'flutter tutorial',
      'params': '8AEB',
    });
    await write('search.json', capLists(redactUrls(j, keep: 120), 4));
    await gap();
  }
  if (on('next')) {
    final (_, j) = await post(web, 'next', webHeaders, {
      ..._ctxFor('WEB', webVisitor),
      'videoId': 'dQw4w9WgXcQ',
      'contentCheckOk': true,
      'racyCheckOk': true,
    });
    await write('next.json', capLists(redactUrls(j, keep: 120), 5));
    // comments continuation: find the longest continuation token
    final toks = <String>[];
    void walk(Object? o, int d) {
      if (d > 30) return;
      if (o is Map) {
        for (final e in o.entries) {
          if (e.key == 'continuationCommand' && e.value is Map) {
            final t = (e.value as Map)['token'];
            if (t is String) toks.add(t);
          }
          walk(e.value, d + 1);
        }
      } else if (o is List) {
        for (final x in o) {
          walk(x, d + 1);
        }
      }
    }

    walk(j, 0);
    stderr.writeln('  tokens: ${toks.map((t) => t.length).toList()}');
    await gap();
    for (final t in toks.toSet()) {
      final (_, jc) = await post(web, 'next', webHeaders, {
        ...ctx('WEB', '2.20260805.01.00', visitorData: visitor,
            screen: 'WATCH', platform: 'DESKTOP'),
        'continuation': t,
      });
      var n = 0;
      void count(Object? o, int d) {
        if (d > 30) return;
        if (o is Map) {
          for (final e in o.entries) {
            if (e.key == 'commentEntityPayload') n++;
            count(e.value, d + 1);
          }
        } else if (o is List) {
          for (final x in o) {
            count(x, d + 1);
          }
        }
      }

      count(jc, 0);
      stderr.writeln('  token(${t.length}) -> payloads=$n');
      if (n > 0) {
        await write(
          'next_comments.json',
          capLists(redactUrls(jc, keep: 120), 30),
        );
        break;
      }
      await gap();
    }
  }

  http.close(force: true);
}
