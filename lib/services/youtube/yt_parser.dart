/// Turning `search` / `next` response trees into the models.
///
/// Two shape notes that a fresh port gets wrong silently, both measured
/// 2026-09-20 (`research/youtube-direct-spike.md` §1.3):
///
///  * **Related videos are no longer `compactVideoRenderer`.** Measured on a
///    `next` response: `compactVideoRenderer = 0`, `lockupViewModel = 26`. A
///    parser that only reads the old renderer gets zero related videos and no
///    error. Both are read here; NewPipe does the same.
///  * **Comments arrive as the entity-view-model form** — a
///    `commentEntityPayload` under `frameworkUpdates.entityBatchUpdate
///    .mutations`, cross-referenced by `commentId` with a `commentViewModel`
///    in the item list — not as the legacy `commentRenderer`. NewPipe has
///    `YoutubeCommentsEUVMInfoItemExtractor` for exactly this. Both forms are
///    read here.
library;

import 'package:PiliPlus/services/youtube/yt_json.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';

/// Video results from a `search` response (or a search continuation).
YtPage<YtSearchItem> parseSearchResults(Object? root) => YtPage(
  [
    for (final r in collectObjects(root, 'videoRenderer'))
      ?_fromVideoRenderer(r),
  ],
  pageContinuationToken(root),
);

/// Related videos from a `next` response.
///
/// Reads the modern `lockupViewModel` and the legacy `compactVideoRenderer`,
/// in that order, de-duplicated by video id.
List<YtSearchItem> parseRelatedVideos(Object? root) {
  final seen = <String>{};
  final out = <YtSearchItem>[];
  void add(YtSearchItem? item) {
    if (item != null && seen.add(item.videoId)) out.add(item);
  }

  for (final m in collectObjects(root, 'lockupViewModel')) {
    add(_fromLockupViewModel(m));
  }
  for (final m in collectObjects(root, 'compactVideoRenderer')) {
    add(_fromVideoRenderer(m));
  }
  return out;
}

/// The token that loads the comments section, out of a `next` response.
///
/// Structural, not positional: NewPipe locates the comments section by its
/// `itemSectionRenderer.sectionIdentifier == "comment-item-section"`, and a
/// `next` response carries several unrelated continuation tokens (related
/// videos, engagement panels) that look identical from the outside.
String? parseCommentsContinuationToken(Object? root) {
  for (final section in collectObjects(root, 'itemSectionRenderer')) {
    if (section['sectionIdentifier'] == 'comment-item-section' ||
        section['targetId'] == 'comments-section') {
      final tokens = collectContinuationTokens(section);
      if (tokens.isNotEmpty) return tokens.first;
    }
  }
  return null;
}

/// Comments from a `next` continuation response.
///
/// The payloads carry the text and the author; the view models carry the
/// per-comment UI state (pinned, uploader). They are joined on `commentId`.
YtPage<YtComment> parseComments(Object? root) {
  final viewModels = <String, Map<String, dynamic>>{};
  for (final vm in collectObjects(root, 'commentViewModel')) {
    final id = vm['commentId'];
    if (id is String) viewModels[id] = vm;
  }

  final out = <YtComment>[];
  final seen = <String>{};
  for (final p in collectObjects(root, 'commentEntityPayload')) {
    final c = _fromCommentEntityPayload(p, viewModels);
    if (c != null && seen.add(c.commentId)) out.add(c);
  }
  // Legacy form, for the day YouTube serves it again (or an A/B bucket does).
  for (final p in collectObjects(root, 'commentRenderer')) {
    final c = _fromLegacyCommentRenderer(p);
    if (c != null && seen.add(c.commentId)) out.add(c);
  }
  return YtPage(out, commentsPageContinuationToken(root));
}

/// The "load the next page" token of a list response.
///
/// It lives in a `continuationItemRenderer` with
/// `trigger == CONTINUATION_TRIGGER_ON_ITEM_SHOWN` — the load-on-scroll one.
String? pageContinuationToken(Object? root) {
  for (final r in collectObjects(root, 'continuationItemRenderer')) {
    if (r['trigger'] != 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN') continue;
    final tokens = collectContinuationTokens(r);
    if (tokens.isNotEmpty) return tokens.first;
  }
  return null;
}

/// [pageContinuationToken] for a comments page.
///
/// A comments response carries one `continuationItemRenderer` per thread (the
/// "show replies" token, measured 208 chars) plus exactly one page-level token
/// (measured 548 chars). Telling them apart by length would be a guess, so the
/// thread-scoped ones are identified structurally — they sit inside a
/// `commentThreadRenderer` — and subtracted.
String? commentsPageContinuationToken(Object? root) {
  final threadScoped = <String>{};
  for (final t in collectObjects(root, 'commentThreadRenderer')) {
    threadScoped.addAll(collectContinuationTokens(t));
  }
  for (final r in collectObjects(root, 'continuationItemRenderer')) {
    if (r['trigger'] != 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN') continue;
    for (final token in collectContinuationTokens(r)) {
      if (!threadScoped.contains(token)) return token;
    }
  }
  return null;
}

// --------------------------------------------------------------- renderers

YtSearchItem? _fromVideoRenderer(Map<String, dynamic> m) {
  final id = m['videoId'];
  if (id is! String || id.isEmpty) return null;
  final byline = m['longBylineText'] ?? m['ownerText'] ?? m['shortBylineText'];
  return YtSearchItem(
    videoId: id,
    title: readText(m['title']),
    author: readText(byline),
    channelId: _browseIdIn(byline),
    thumbnails: mapList(
      (m['thumbnail'] as Map?)?['thumbnails'],
      YtThumbnail.fromJson,
    ),
    duration: parseClockDuration(readText(m['lengthText'])),
    viewCountText: _orNull(readText(m['viewCountText'])),
    publishedText: _orNull(readText(m['publishedTimeText'])),
    isLive: _videoRendererIsLive(m),
  );
}

bool _videoRendererIsLive(Map<String, dynamic> m) {
  for (final o in collectObjects(m, 'thumbnailOverlayTimeStatusRenderer')) {
    if (o['style'] == 'LIVE') return true;
  }
  return false;
}

YtSearchItem? _fromLockupViewModel(Map<String, dynamic> m) {
  if (m['contentType'] != null &&
      m['contentType'] != 'LOCKUP_CONTENT_TYPE_VIDEO') {
    // Playlists, channels and shorts shelves use the same view model.
    return null;
  }
  final id = m['contentId'];
  if (id is! String || id.isEmpty) return null;

  final meta =
      (m['metadata'] as Map?)?['lockupMetadataViewModel'] as Map? ?? const {};
  final rows =
      collectObjects(
            meta['metadata'],
            'contentMetadataViewModel',
          )
          .expand((v) => (v['metadataRows'] as List?) ?? const [])
          .whereType<Map>()
          .toList(growable: false);

  // Row 0 is the channel; row 1 is "views · age". Not a contract, so each
  // piece is read defensively and left null when absent.
  final row0 = rows.isNotEmpty ? _metadataTexts(rows[0]) : const <String>[];
  final row1 = rows.length > 1 ? _metadataTexts(rows[1]) : const <String>[];

  final badge = _lockupBadgeText(m);
  return YtSearchItem(
    videoId: id,
    title: readText(meta['title']),
    author: row0.isNotEmpty ? row0.first : '',
    channelId: _browseIdIn(meta['image']),
    thumbnails: mapList(
      ((m['contentImage'] as Map?)?['thumbnailViewModel'] as Map?)?['image']
              is Map
          ? (((m['contentImage'] as Map)['thumbnailViewModel'] as Map)['image']
                as Map)['sources']
          : null,
      YtThumbnail.fromJson,
    ),
    duration: parseClockDuration(badge),
    viewCountText: row1.isNotEmpty ? row1.first : null,
    publishedText: row1.length > 1 ? row1[1] : null,
    isLive: badge != null && badge.toUpperCase() == 'LIVE',
  );
}

List<String> _metadataTexts(Map<dynamic, dynamic> row) => [
  for (final part in (row['metadataParts'] as List?) ?? const [])
    if (part is Map && readText(part['text']).isNotEmpty)
      readText(part['text']),
];

String? _lockupBadgeText(Map<String, dynamic> m) {
  for (final b in collectObjects(
    m['contentImage'],
    'thumbnailBadgeViewModel',
  )) {
    final t = b['text'];
    if (t is String && t.isNotEmpty) return t;
  }
  return null;
}

YtComment? _fromCommentEntityPayload(
  Map<String, dynamic> p,
  Map<String, Map<String, dynamic>> viewModels,
) {
  final props = (p['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
  final id = props['commentId'];
  if (id is! String || id.isEmpty) return null;
  final author = (p['author'] as Map?)?.cast<String, dynamic>() ?? const {};
  final toolbar = (p['toolbar'] as Map?)?.cast<String, dynamic>() ?? const {};
  final vm = viewModels[id];
  final avatarUrl = author['avatarThumbnailUrl'];
  return YtComment(
    commentId: id,
    author: (author['displayName'] ?? '').toString(),
    authorChannelId: author['channelId'] as String?,
    authorAvatar: avatarUrl is String && avatarUrl.isNotEmpty
        ? YtThumbnail(url: avatarUrl)
        : null,
    content: readText(props['content']),
    likeCountText: _orNull(
      (toolbar['likeCountNotliked'] ?? toolbar['likeCountLiked'] ?? '')
          .toString(),
    ),
    publishedText: _orNull((props['publishedTime'] ?? '').toString()),
    replyCount: _looseCount(toolbar['replyCount']),
    isPinned: vm?['pinnedText'] != null,
    authorIsUploader: author['isCreator'] == true,
  );
}

YtComment? _fromLegacyCommentRenderer(Map<String, dynamic> m) {
  final id = m['commentId'];
  if (id is! String || id.isEmpty) return null;
  return YtComment(
    commentId: id,
    author: readText(m['authorText']),
    authorChannelId:
        ((m['authorEndpoint'] as Map?)?['browseEndpoint'] as Map?)?['browseId']
            as String?,
    authorAvatar: mapList(
      (m['authorThumbnail'] as Map?)?['thumbnails'],
      YtThumbnail.fromJson,
    ).lastOrNull,
    content: readText(m['contentText']),
    likeCountText: _orNull(readText(m['voteCount'])),
    publishedText: _orNull(readText(m['publishedTimeText'])),
    replyCount: _looseCount(m['replyCount']),
    isPinned: m['pinnedCommentBadge'] != null,
    authorIsUploader: m['authorIsChannelOwner'] == true,
  );
}

/// Reply counts arrive as an int, as `"962"`, or as the abbreviated `"1.2K"`.
/// Only the first two are numbers; the abbreviated form is reported as 0
/// rather than invented.
int _looseCount(Object? v) => asInt(v) ?? 0;

String? _orNull(String s) => s.isEmpty ? null : s;

/// The first `browseEndpoint.browseId` (a `UC…` channel id) anywhere in [node].
String? _browseIdIn(Object? node) {
  for (final e in collectObjects(node, 'browseEndpoint')) {
    final id = e['browseId'];
    if (id is String && id.isNotEmpty) return id;
  }
  return null;
}


/// The channel header of a `browse` response.
///
/// Reads `pageHeaderViewModel`, which is what a channel page carries today —
/// measured on two channels; the older `c4TabbedHeaderRenderer` did not
/// appear at all.
YtChannelInfo? parseChannelInfo(Object? root, String channelId) {
  final header = collectObjects(root, 'pageHeaderViewModel').firstOrNull;
  if (header == null) return null;

  // the title is not a plain text node here: `pageHeaderViewModel` nests it
  // in a `dynamicTextViewModel`, so the first non-empty `content` under it is
  // the channel name
  final name = [
    readText(header['title']).trim(),
    for (final content in collectByKey(header['title'], 'content'))
      if (content is String) content.trim(),
  ].firstWhere((s) => s.isNotEmpty, orElse: () => '');

  // the avatar is the largest source under the header's image blocks
  final avatars = <YtThumbnail>[
    for (final sources in collectByKey(header, 'sources'))
      ...mapList(sources, YtThumbnail.fromJson),
  ];

  // "5.2M subscribers" and "1.2K videos" arrive as metadata rows
  final rows = <String>[
    for (final part in collectObjects(header, 'metadataParts'))
      readText(part['text']).trim(),
    for (final parts in collectByKey(header, 'metadataParts'))
      if (parts is List)
        for (final part in parts)
          if (part is Map) readText(part['text']).trim(),
  ]..removeWhere((s) => s.isEmpty);

  String? pick(bool Function(String) test) {
    for (final row in rows) {
      if (test(row.toLowerCase())) return row;
    }
    return null;
  }

  return YtChannelInfo(
    channelId: channelId,
    name: name,
    avatar: largestThumbnail(avatars),
    subscriberText: pick((r) => r.contains('subscriber') || r.contains('订阅')),
    videoCountText: pick((r) => r.contains('video') || r.contains('视频')),
    description: readText(header['description']).trim(),
  );
}
