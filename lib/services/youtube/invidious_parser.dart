/// LibrePili: reading a video out of an Invidious instance's own pages —
/// `inv.nadeko.net`, where `/api/v1/videos` answers `403 Endpoint disabled`
/// for everyone (measured 2026-10-12) and the watch page is what its own
/// player reads.
///
/// What the watch page carries, measured on `dQw4w9WgXcQ` and
/// `xQlKGiIwhF4`:
///
///  * `<script id="player_data">` — title, the full description;
///  * `<script id="video_data">` — `length_seconds`, `live_now`;
///  * `<span id="channel-name">`, `<a href="/channel/UC…">`, `<p id="views">`;
///  * `<source … type='application/dash+xml'>` — a DASH manifest on the
///    instance's companion (`inv-us2.nadeko.net/companion/…?local=true`);
///  * `<track kind="captions" src=… label=…>` — WebVTT through the companion.
///
/// The manifest asked for with `local=true` points every stream back at the
/// companion (the instance's bandwidth) with `ip=` taken out, so googlevideo
/// refuses it directly (403). Without `local=true` it lists googlevideo's
/// own URLs, and those serve this machine (206, 1080p/720p/AV1/audio,
/// measured): the instance answers one page per video and none of the video.
library;

import 'dart:convert';

import 'package:PiliPlus/services/youtube/yt_json.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';

/// What one watch page says about its video.
class InvidiousWatch {
  const InvidiousWatch({
    required this.videoId,
    required this.title,
    required this.author,
    required this.channelId,
    required this.description,
    required this.duration,
    required this.isLive,
    required this.dashUrl,
    required this.captions,
    this.viewCount,
  });

  final String videoId;
  final String title;
  final String author;
  final String channelId;
  final String description;
  final Duration duration;
  final bool isLive;
  final int? viewCount;

  /// The manifest with googlevideo's own URLs (`local=true` taken out); null
  /// when the page offers none — a video the instance cannot play.
  final String? dashUrl;

  /// `(label, url)` per caption track, in the page's order.
  final List<({String label, String url})> captions;
}

/// The watch page in [html], or null when it is not one (a challenge page,
/// an error page without the player's data).
InvidiousWatch? parseInvidiousWatch(String html, String videoId) {
  final player = _jsonScript(html, 'player_data');
  final video = _jsonScript(html, 'video_data');
  if (player == null || video == null) return null;

  final dash = RegExp(
    r'''<source src="([^"]+)" type=['"]application/dash\+xml['"]''',
  ).firstMatch(html)?.group(1);

  final captions = [
    for (final m in RegExp(
      r'<track kind="captions" src="([^"]+)" label="([^"]*)"',
    ).allMatches(html))
      (label: _unescape(m.group(2)!), url: _unescape(m.group(1)!)),
  ];

  final views = RegExp(
    r'<p id="views">(?:<[^>]*>|\s)*([\d,]+)',
  ).firstMatch(html)?.group(1);

  return InvidiousWatch(
    videoId: videoId,
    title: (player['title'] ?? '').toString(),
    description: (player['description'] ?? '').toString(),
    author: _text(
      RegExp(
        r'<span id="channel-name"[^>]*>(.*?)</span>',
        dotAll: true,
      ).firstMatch(html)?.group(1),
    ),
    channelId:
        RegExp(r'href="/channel/(UC[\w-]{22})"').firstMatch(html)?.group(1) ??
        '',
    duration: Duration(seconds: asInt(video['length_seconds']) ?? 0),
    isLive: video['live_now'] == true,
    viewCount: views == null ? null : int.tryParse(views.replaceAll(',', '')),
    dashUrl: dash == null ? null : withoutLocal(_unescape(dash)),
    captions: captions,
  );
}

/// [url] without `local=true`: googlevideo's own stream URLs instead of the
/// companion's.
String withoutLocal(String url) => url
    .replaceAll(RegExp(r'(?<=[?&])local=[^&]*&'), '')
    .replaceAll(RegExp(r'[?&]local=[^&]*$'), '');

/// The formats in an Invidious companion's DASH manifest, in the shape the
/// rest of the YouTube layer reads ([YtFormat]).
///
/// A representation's id is `itag[-audioTrack][-drc]` (`140-en-US.4`,
/// `140-en-US.4-drc`); the audio track's `xtags` in the URL say which one is
/// the original (`acont=original`) and which a dub (`acont=dubbed-auto`).
/// The `-drc` copies (dynamic range compressed) are left out: the original
/// once is enough, and the selection would otherwise have two defaults.
///
/// The URLs carry an `n=` that the companion has already worked out (the
/// stream came in at the line's speed, not a throttled trickle — measured
/// 2026-10-12); the formats are marked so, so [YtFormat.isPlayable] does
/// not take them for the undeciphered kind.
List<YtFormat> parseInvidiousDash(String xml) {
  final out = <YtFormat>[];
  for (final set in RegExp(
    r'<AdaptationSet([^>]*)>(.*?)</AdaptationSet>',
    dotAll: true,
  ).allMatches(xml)) {
    final setAttrs = _attrs(set.group(1)!);
    final mime = setAttrs['mimeType'] ?? '';
    final label = RegExp(r'<Label[^>]*>([^<]*)</Label>').firstMatch(set.group(2)!)?.group(1);
    final fps = asInt(setAttrs['frameRate']);
    for (final rep in RegExp(
      r'<Representation([^>]*)>(.*?)</Representation>',
      dotAll: true,
    ).allMatches(set.group(2)!)) {
      final attrs = _attrs(rep.group(1)!);
      final base = RegExp(
        r'<BaseURL>([^<]*)</BaseURL>',
      ).firstMatch(rep.group(2)!)?.group(1);
      final id = attrs['id'];
      if (base == null || id == null) continue;
      final url = _unescape(base);
      if (id.endsWith('-drc')) continue;
      final itag = asInt(RegExp(r'^\d+').firstMatch(id)?.group(0));
      if (itag == null) continue;
      final query = Uri.tryParse(url)?.queryParameters ?? const {};
      final xtags = query['xtags'] ?? '';
      final dash = id.indexOf('-');
      final trackId = dash < 0 ? null : id.substring(dash + 1);
      final range = RegExp(
        r'<Initialization range="(\d+)-(\d+)"',
      ).firstMatch(rep.group(2)!);
      final index = RegExp(
        r'indexRange="(\d+)-(\d+)"',
      ).firstMatch(rep.group(2)!);
      out.add(
        YtFormat({
          'itag': itag,
          'mimeType': '$mime; codecs="${attrs['codecs'] ?? ''}"',
          'url': url,
          'bitrate': asInt(attrs['bandwidth']) ?? 0,
          'width': ?asInt(attrs['width']),
          'height': ?asInt(attrs['height']),
          'fps': ?fps,
          'contentLength': ?asInt(query['clen']),
          if (double.tryParse(query['dur'] ?? '') case final dur?)
            'approxDurationMs': (dur * 1000).round(),
          if (trackId != null)
            'audioTrack': {
              'id': trackId,
              'displayName': ?label,
              'audioIsDefault': xtags.contains('acont=original'),
            },
          if (range != null)
            'initRange': {'start': range.group(1), 'end': range.group(2)},
          if (index != null)
            'indexRange': {'start': index.group(1), 'end': index.group(2)},
          YtFormat.nWorkedOut: true,
        }),
      );
    }
  }
  return out;
}

/// The caption tracks of [watch] as the layer's [YtCaptionTrack]s.
///
/// The page names a track only by its label (`English`, `English
/// (auto-generated)`); [codes] — `label → languageCode` from the instance's
/// `/api/v1/captions/<id>`, which still answers — fills the language in.
List<YtCaptionTrack> invidiousCaptionTracks(
  InvidiousWatch watch, [
  Map<String, String> codes = const {},
]) => [
  for (final c in watch.captions)
    YtCaptionTrack(
      languageCode: codes[c.label] ?? '',
      baseUrl: c.url,
      vssId:
          '${c.label.contains('(auto-generated)') ? 'a' : ''}.'
          '${codes[c.label] ?? ''}',
      name: c.label,
      translatable: false,
    ),
];

/// `label → languageCode` out of `/api/v1/captions/<id>`'s answer.
Map<String, String> invidiousCaptionCodes(Object? json) {
  final list = json is Map ? json['captions'] : null;
  if (list is! List) return const {};
  return {
    for (final c in list)
      if (c is Map && c['label'] is String && c['languageCode'] is String)
        c['label'] as String: c['languageCode'] as String,
  };
}

/// The thumbnails YouTube itself serves for [videoId] (i.ytimg.com does not
/// sit behind the bot wall the player does).
List<YtThumbnail> invidiousThumbnails(String videoId) => [
  YtThumbnail(
    url: 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
    width: 480,
    height: 360,
  ),
  YtThumbnail(
    url: 'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg',
    width: 1280,
    height: 720,
  ),
];

/// When the googlevideo URLs in [formats] stop working, from their `expire`
/// (absolute seconds); null when none says.
DateTime? invidiousExpiry(List<YtFormat> formats) {
  for (final f in formats) {
    final s = Uri.tryParse(f.url ?? '')?.queryParameters['expire'];
    final at = s == null ? null : int.tryParse(s);
    if (at != null) return DateTime.fromMillisecondsSinceEpoch(at * 1000);
  }
  return null;
}

Map<String, dynamic>? _jsonScript(String html, String id) {
  final m = RegExp(
    '<script id="$id" type="application/json">(.*?)</script>',
    dotAll: true,
  ).firstMatch(html);
  if (m == null) return null;
  try {
    final json = jsonDecode(m.group(1)!);
    return json is Map<String, dynamic> ? json : null;
  } catch (_) {
    return null;
  }
}

Map<String, String> _attrs(String s) => {
  for (final m in RegExp(r'([\w:]+)="([^"]*)"').allMatches(s))
    m.group(1)!: m.group(2)!,
};

String _text(String? html) => _unescape(
  (html ?? '').replaceAll(RegExp(r'<[^>]*>'), ''),
).replaceAll('\u00a0', ' ').trim();

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', '\u00a0');
