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
///
/// [channel] is set by a channel's own list, whose lockups leave the
/// channel out (see [_fromLockupViewModel]).
List<YtSearchItem> parseRelatedVideos(
  Object? root, {
  ({String name, String id})? channel,
}) {
  final seen = <String>{};
  final out = <YtSearchItem>[];
  void add(YtSearchItem? item) {
    if (item != null && seen.add(item.videoId)) out.add(item);
  }

  for (final m in collectObjects(root, 'lockupViewModel')) {
    add(_fromLockupViewModel(m, channel));
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
  final replyTokens = _replyTokensByComment(root);
  final replyLabels = _replyLabelsByComment(root);

  final out = <YtComment>[];
  final seen = <String>{};
  for (final p in collectObjects(root, 'commentEntityPayload')) {
    final c = _fromCommentEntityPayload(p, viewModels);
    if (c != null && seen.add(c.commentId)) {
      out.add(
        c.copyWith(
          replyToken: replyTokens[c.commentId],
          replyCountText: replyLabels[c.commentId],
        ),
      );
    }
  }
  // Legacy form, for the day YouTube serves it again (or an A/B bucket does).
  for (final p in collectObjects(root, 'commentRenderer')) {
    final c = _fromLegacyCommentRenderer(p);
    if (c != null && seen.add(c.commentId)) {
      out.add(
        c.copyWith(
          replyToken: replyTokens[c.commentId],
          replyCountText: replyLabels[c.commentId],
        ),
      );
    }
  }
  return YtPage(out, commentsPageContinuationToken(root));
}

/// YouTube's own label on each thread's expand button ('962 replies').
Map<String, String> _replyLabelsByComment(Object? root) {
  final out = <String, String>{};
  for (final thread in collectObjects(root, 'commentThreadRenderer')) {
    final button = collectObjects(thread, 'viewReplies').firstOrNull;
    final label = readText(
      (button?['buttonRenderer'] as Map?)?['text'],
    ).trim();
    if (label.isEmpty) continue;
    if (_topCommentIdOf(thread) case final id?) out[id] = label;
  }
  return out;
}

/// Which comment each thread-scoped continuation belongs to.
///
/// A `commentThreadRenderer` holds one top-level comment and, when it has
/// replies, the token that loads them. Both are inside the same object, so
/// the pairing is structural rather than positional — the order comments
/// arrive in is not the order the tokens do.
Map<String, String> _replyTokensByComment(Object? root) {
  final out = <String, String>{};
  for (final thread in collectObjects(root, 'commentThreadRenderer')) {
    final tokens = collectContinuationTokens(thread);
    if (tokens.isEmpty) continue;
    if (_topCommentIdOf(thread) case final id?) out[id] = tokens.first;
  }
  return out;
}

/// The watch page's own metadata, out of the `next` response.
///
/// Read from `videoPrimaryInfoRenderer` (date, exact view count) and
/// `videoOwnerRenderer` (avatar, subscribers). Both are looked up by key
/// anywhere in the tree rather than by path: the watch page's layout moves
/// between A/B buckets and a fixed path is the thing that breaks silently.
YtVideoExtra parseVideoExtra(Object? root) {
  final primary = collectObjects(root, 'videoPrimaryInfoRenderer').firstOrNull;
  final owner = collectObjects(root, 'videoOwnerRenderer').firstOrNull;
  final viewCount = collectObjects(root, 'videoViewCountRenderer').firstOrNull;
  return YtVideoExtra(
    dateText: _orNull(readText(primary?['dateText'])),
    relativeDateText: _orNull(readText(primary?['relativeDateText'])),
    viewCountText: _orNull(readText(viewCount?['viewCount'])),
    ownerName: _orNull(readText(owner?['title'])),
    ownerAvatar: mapList(
      (owner?['thumbnail'] as Map?)?['thumbnails'],
      YtThumbnail.fromJson,
    ).lastOrNull,
    subscriberText: _orNull(readText(owner?['subscriberCountText'])),
  );
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
  String? fallback;
  for (final r in collectObjects(root, 'continuationItemRenderer')) {
    final onItemShown = r['trigger'] == 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN';
    for (final token in collectContinuationTokens(r)) {
      if (threadScoped.contains(token)) continue;
      if (onItemShown) return token;
      // A page of REPLIES carries its "Show more replies" token in a
      // continuationItemRenderer with no `trigger` at all — measured: one
      // token, trigger absent, behind a button labelled 'Show more
      // replies'. Requiring the scroll trigger found nothing there, so a
      // thread with 114 replies reported that its 9 were all of them.
      // A comments page always has the triggered one, and it is returned
      // above, so this never takes precedence over it.
      fallback ??= token;
    }
  }
  return fallback;
}

/// The id of the comment a thread is about.
///
/// A thread carries two `commentViewModel`s and the first has no
/// `commentId` at all, so this takes the first one that does.
String? _topCommentIdOf(Map<String, dynamic> thread) {
  for (final vm in collectObjects(thread, 'commentViewModel')) {
    if (vm['commentId'] case final String value when value.isNotEmpty) {
      return value;
    }
  }
  // the legacy shape carries the id on the renderer itself
  for (final c in collectObjects(thread, 'commentRenderer')) {
    if (c['commentId'] case final String value when value.isNotEmpty) {
      return value;
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

YtSearchItem? _fromLockupViewModel(
  Map<String, dynamic> m, [
  ({String name, String id})? channel,
]) {
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

  // Rows are told apart by how many there are, because nothing in them says
  // which is which (measured 2026-09-30: the channel part is a bare text, no
  // endpoint). In search, related and on a playlist page there are two:
  // the channel, then "views · age". On a channel's own tab there is one —
  // "views · age" — and the channel is the page's. Reading that one row as
  // the channel put the view count where the author goes and left the date
  // out entirely.
  //
  // Without a channel from the page, one row is still read as the channel:
  // that is what the measured contexts without one do, and guessing
  // otherwise would change lists nobody has looked at.
  final String author;
  final List<String> stats;
  if (channel != null && rows.length == 1) {
    author = channel.name;
    stats = _metadataTexts(rows.first);
  } else {
    final row0 = rows.isNotEmpty ? _metadataTexts(rows[0]) : const <String>[];
    author = row0.isNotEmpty ? row0.first : (channel?.name ?? '');
    stats = rows.length > 1 ? _metadataTexts(rows.last) : const <String>[];
  }

  final badges = _lockupBadges(m);
  final durationBadge = badges
      .map((b) => b['text'])
      .whereType<String>()
      .map(parseClockDuration)
      .nonNulls
      .firstOrNull;
  return YtSearchItem(
    videoId: id,
    title: readText(meta['title']),
    author: author,
    channelId: _browseIdIn(meta['image']) ?? channel?.id,
    thumbnails: lockupThumbnails(m),
    duration: durationBadge,
    // a stream that is live now has one part: "288人正在观看"
    viewCountText: stats.isNotEmpty ? stats.first : null,
    publishedText: stats.length > 1 ? stats[1] : null,
    isLive: badges.any(_isLiveBadge),
  );
}

/// The badge's *style*, not its text: the text is localised ('直播' under
/// zh-CN), and comparing it with 'LIVE' found no live stream at all.
bool _isLiveBadge(Map<String, dynamic> badge) =>
    badge['badgeStyle'] == 'THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE' ||
    collectByKey(badge['icon'], 'imageName').contains('LIVE');

List<Map<String, dynamic>> _lockupBadges(Map<String, dynamic> m) =>
    collectObjects(m['contentImage'], 'thumbnailBadgeViewModel');

/// The cover of a lockup: a video's `thumbnailViewModel`, or the primary
/// thumbnail of a playlist's `collectionThumbnailViewModel` — the first
/// `thumbnailViewModel` under `contentImage` either way.
List<YtThumbnail> lockupThumbnails(Map<String, dynamic> m) {
  final view = collectObjects(m['contentImage'], 'thumbnailViewModel')
      .firstOrNull;
  final image = view?['image'];
  return mapList(image is Map ? image['sources'] : null, YtThumbnail.fromJson);
}

List<String> _metadataTexts(Map<dynamic, dynamic> row) => [
  for (final part in (row['metadataParts'] as List?) ?? const [])
    if (part is Map && readText(part['text']).isNotEmpty)
      readText(part['text']),
];

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
