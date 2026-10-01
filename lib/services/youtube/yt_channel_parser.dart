/// Turning channel `browse` responses into the channel models.
///
/// Measured 2026-09-30 on Kurzgesagt and DW News (`research` notes in the
/// yt-channel-tabs plan, F1–F13). The facts the code below depends on:
///
///  * **A channel response carries several triggered continuation tokens,
///    and only one is the list's.** The header's About panel brings two
///    (136 chars), and the Home tab brings one per shelf, all inside
///    engagement panels. Taking "the first triggered token in the tree"
///    landed on the About one, which returns nothing — so paging stopped
///    after the first page. [listContinuationToken] reads only the list.
///  * **Tabs are identified by URL suffix**, never by title (titles are
///    localised) — see [YtChannelTab].
///  * **A channel tab's lockup has one metadata row** (views · age); search,
///    related and playlist lockups have two (channel, then views · age).
///    Neither carries a structural marker for "this is the channel", so
///    rows are told apart by count, with the channel passed in.
library;

import 'package:PiliPlus/services/youtube/yt_channel_models.dart';
import 'package:PiliPlus/services/youtube/yt_json.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_parser.dart';

const _onItemShown = 'CONTINUATION_TRIGGER_ON_ITEM_SHOWN';

/// The subtree that holds a list response's items.
///
/// On a first page that is the selected tab's content; on a continuation it
/// is the `continuationItems` of the append or reload action. Nothing in the
/// header, the sidebar or an engagement panel is part of it.
Object? listRootOf(Object? root) {
  if (root is Map) {
    final items = <Object?>[];
    for (final key in const [
      'onResponseReceivedActions',
      'onResponseReceivedEndpoints',
    ]) {
      final actions = root[key];
      if (actions is! List) continue;
      for (final action in actions.whereType<Map>()) {
        for (final kind in const [
          'appendContinuationItemsAction',
          'reloadContinuationItemsCommand',
        ]) {
          final list = (action[kind] as Map?)?['continuationItems'];
          if (list is List) items.addAll(list);
        }
      }
    }
    if (items.isNotEmpty) return items;
  }
  final tabs = collectObjects(root, 'tabRenderer');
  for (final tab in tabs) {
    if (tab['selected'] == true && tab['content'] != null) {
      return tab['content'];
    }
  }
  // a playlist page has one tab, and it is not always marked selected
  for (final tab in tabs) {
    if (tab['content'] != null) return tab['content'];
  }
  return null;
}

/// The "load the next page" token of a channel tab, playlist or post list.
///
/// Read from the list alone (see [listRootOf]), and never from inside an
/// engagement panel, where the Home tab's shelves keep theirs. Accepts the
/// renderer form with the scroll trigger, and the view-model form a
/// playlist page uses — which the search/related reader
/// ([pageContinuationToken]) does not know, so every playlist stopped at
/// its first 100.
String? listContinuationToken(Object? root) {
  final list = listRootOf(root);
  if (list == null) return null;
  String? found;
  void walk(Object? node, int depth) {
    if (found != null || depth > 40) return;
    if (node is Map) {
      for (final e in node.entries) {
        if (found != null) return;
        switch (e.key) {
          case 'header' ||
              'engagementPanel' ||
              'engagementPanels' ||
              'showEngagementPanelEndpoint':
            continue;
          case 'continuationItemRenderer' || 'continuationItemViewModel'
              when e.value is Map:
            final r = e.value as Map;
            final trigger = r['trigger'];
            // the view-model form has carried the trigger and has gone
            // without it; the renderer form always has one
            if (e.key == 'continuationItemRenderer' &&
                trigger != _onItemShown) {
              continue;
            }
            final tokens = collectContinuationTokens(r);
            if (tokens.isNotEmpty) {
              found = tokens.first;
              return;
            }
          default:
            walk(e.value, depth + 1);
        }
      }
    } else if (node is List) {
      for (final x in node) {
        walk(x, depth + 1);
      }
    }
  }

  walk(list, 0);
  return found;
}

/// The tabs a channel response lists, with each one's `params`.
Map<YtChannelTab, String> parseChannelTabs(Object? root) {
  final out = <YtChannelTab, String>{};
  for (final t in collectObjects(root, 'tabRenderer')) {
    final endpoint = t['endpoint'];
    if (endpoint is! Map) continue;
    final tab =
        YtChannelTab.fromUrl(_webUrl(endpoint)) ??
        _tabFromParams((endpoint['browseEndpoint'] as Map?)?['params']);
    final params = (endpoint['browseEndpoint'] as Map?)?['params'];
    if (tab != null && params is String && params.isNotEmpty) {
      out[tab] = params;
    }
  }
  return out;
}

/// The tab the response says it is showing, or null.
YtChannelTab? selectedChannelTab(Object? root) {
  for (final t in collectObjects(root, 'tabRenderer')) {
    if (t['selected'] != true) continue;
    final endpoint = t['endpoint'];
    if (endpoint is! Map) return null;
    return YtChannelTab.fromUrl(_webUrl(endpoint)) ??
        _tabFromParams((endpoint['browseEndpoint'] as Map?)?['params']);
  }
  return null;
}

String? _webUrl(Map endpoint) =>
    ((endpoint['commandMetadata'] as Map?)?['webCommandMetadata']
            as Map?)?['url']
        as String?;

/// The params of a tab name the tab in plain bytes: field 2 = the name
/// (`EgZ2aWRlb3M…` is 0x12, 6, "videos"). Their first 8 base64 characters
/// are the tag, the length and the first four letters, which is enough to
/// tell these five apart (shorts `EgZzaG9y` vs shows `EgVzaG93` differ in
/// the length byte). Used only when the URL is absent.
YtChannelTab? _tabFromParams(Object? params) {
  if (params is! String || params.length < 8) return null;
  for (final tab in YtChannelTab.values) {
    if (params.startsWith(tab.fallbackParams.substring(0, 8))) return tab;
  }
  return null;
}

/// Videos on a channel's 视频 or 直播 tab, or a playlist page.
///
/// [channel] is the channel the list belongs to: a lockup there has only
/// the stats row, and the author has to come from the page.
List<YtSearchItem> parseChannelVideos(
  Object? root, {
  ({String name, String id})? channel,
}) => parseRelatedVideos(listRootOf(root) ?? root, channel: channel);

/// Shorts, from `shortsLockupViewModel`s.
List<YtShortItem> parseChannelShorts(Object? root) {
  final out = <YtShortItem>[];
  final seen = <String>{};
  for (final m in collectObjects(
    listRootOf(root) ?? root,
    'shortsLockupViewModel',
  )) {
    final endpoint = collectObjects(
      m['onTap'],
      'reelWatchEndpoint',
    ).firstOrNull;
    final id = endpoint?['videoId'];
    if (id is! String || id.isEmpty || !seen.add(id)) continue;
    final overlay = (m['overlayMetadata'] as Map?) ?? const {};
    final image = collectObjects(m['thumbnailViewModel'], 'image').firstOrNull;
    out.add(
      YtShortItem(
        videoId: id,
        title: readText(overlay['primaryText']),
        viewCountText: _orNull(readText(overlay['secondaryText'])),
        thumbnails: mapList(image?['sources'], YtThumbnail.fromJson),
      ),
    );
  }
  return out;
}

const _playlistTypes = {
  'LOCKUP_CONTENT_TYPE_PLAYLIST',
  // a channel's own series: Kurzgesagt's are all SHOW, and dropping them
  // left its 播放列表 tab empty
  'LOCKUP_CONTENT_TYPE_SHOW',
  'LOCKUP_CONTENT_TYPE_PODCAST',
};

/// Playlists on a channel's 播放列表 tab.
List<YtPlaylistItem> parseChannelPlaylists(Object? root) {
  final out = <YtPlaylistItem>[];
  final seen = <String>{};
  for (final m in collectObjects(listRootOf(root) ?? root, 'lockupViewModel')) {
    if (!_playlistTypes.contains(m['contentType'])) continue;
    var id = m['contentId'];
    if (id is! String || id.isEmpty) {
      // otherwise the VL<id> that the "view full playlist" row opens
      for (final e in collectObjects(m, 'browseEndpoint')) {
        final browseId = e['browseId'];
        if (browseId is String && browseId.startsWith('VL')) {
          id = browseId.substring(2);
          break;
        }
      }
    }
    if (id is! String || id.isEmpty || !seen.add(id)) continue;
    final meta =
        (m['metadata'] as Map?)?['lockupMetadataViewModel'] as Map? ?? const {};
    final rows = _rowsOf(meta);
    final first = rows.isNotEmpty ? _metadataTexts(rows.first) : const [];
    out.add(
      YtPlaylistItem(
        playlistId: id,
        title: readText(meta['title']),
        thumbnails: lockupThumbnails(m),
        countText: _badgeTexts(m).firstOrNull,
        // when the only row is the "view full playlist" link, there is no
        // first-video title to show
        firstVideoTitle: rows.length > 1 && first.isNotEmpty
            ? first.first
            : null,
      ),
    );
  }
  return out;
}

/// Posts on a channel's 帖子 tab, or the one post of a detail page.
List<YtPost> parseChannelPosts(Object? root) => [
  for (final p in collectObjects(
    listRootOf(root) ?? root,
    'backstagePostRenderer',
  ))
    ?_fromPostRenderer(p),
];

YtPost? _fromPostRenderer(Map<String, dynamic> p) {
  final id = p['postId'];
  if (id is! String || id.isEmpty) return null;
  final attachment = (p['backstageAttachment'] as Map?) ?? const {};
  final images = <YtThumbnail>[
    if (attachment['backstageImageRenderer'] case final Map single)
      ?_largestImage(single),
    if (attachment['postMultiImageRenderer'] case final Map multi)
      for (final image in collectObjects(multi, 'backstageImageRenderer'))
        ?_largestImage(image),
  ];
  YtSearchItem? video;
  if (attachment['videoRenderer'] case final Map v) {
    video = parseSearchResults({'videoRenderer': v}).items.firstOrNull;
  }
  // not in the recordings (Kurzgesagt had no polls); read defensively from
  // the renderer NewPipe documents, and shown only when it parses
  final poll = attachment['pollRenderer'] as Map?;
  final pollChoices = <String>[
    for (final c in (poll?['choices'] as List?) ?? const [])
      if (c is Map && readText(c['text']).isNotEmpty) readText(c['text']),
  ];
  final author = p['authorText'];
  final buttons =
      (p['actionButtons'] as Map?)?['commentActionButtonsRenderer'] as Map?;
  final reply = (buttons?['replyButton'] as Map?)?['buttonRenderer'] as Map?;
  return YtPost(
    postId: id,
    author: readText(author),
    authorChannelId: _browseIdIn(p['authorEndpoint'] ?? author),
    authorAvatar: largestThumbnail(
      mapList(
        (p['authorThumbnail'] as Map?)?['thumbnails'],
        YtThumbnail.fromJson,
      ),
    ),
    runs: _runsOf(p['contentText']),
    publishedText: _orNull(readText(p['publishedTimeText'])),
    likeCountText: _orNull(readText(p['voteCount'])),
    commentCountText: _orNull(readText(reply?['text'])),
    images: images,
    video: video,
    pollChoices: pollChoices,
    pollVotesText: _orNull(readText(poll?['totalVotes'])),
    detailParams: _postDetailParams(p),
  );
}

YtThumbnail? _largestImage(Map image) => largestThumbnail(
  mapList((image['image'] as Map?)?['thumbnails'], YtThumbnail.fromJson),
);

/// The `FEpost_detail` params, which every link to the post carries — the
/// date is one, the image another.
String? _postDetailParams(Map<String, dynamic> p) {
  for (final e in collectObjects(p, 'browseEndpoint')) {
    final params = e['params'];
    if (e['browseId'] == 'FEpost_detail' && params is String) return params;
  }
  return null;
}

List<YtTextRun> _runsOf(Object? text) {
  if (text is Map && text['runs'] is List) {
    return [
      for (final r in (text['runs'] as List).whereType<Map>())
        if ((r['text'] ?? '').toString().isNotEmpty) _runOf(r),
    ];
  }
  final plain = readText(text);
  return plain.isEmpty ? const [] : [YtTextRun(plain)];
}

YtTextRun _runOf(Map r) {
  final text = r['text'].toString();
  final endpoint = r['navigationEndpoint'];
  if (endpoint is! Map) return YtTextRun(text);
  if ((endpoint['watchEndpoint'] as Map?)?['videoId'] case final String id) {
    return YtTextRun(text, videoId: id);
  }
  if ((endpoint['browseEndpoint'] as Map?)?['browseId'] case final String id) {
    return YtTextRun(text, browseId: id);
  }
  if ((endpoint['urlEndpoint'] as Map?)?['url'] case final String url) {
    return YtTextRun(text, url: unwrapYtRedirect(url));
  }
  return YtTextRun(text);
}

/// YouTube sends outside links as `youtube.com/redirect?…&q=<target>`; the
/// target is what the user is going to, so that is what is opened.
String unwrapYtRedirect(String url) {
  final uri = Uri.tryParse(url);
  final target = uri?.queryParameters['q'];
  if (uri != null &&
      uri.path == '/redirect' &&
      uri.host.endsWith('youtube.com') &&
      target != null &&
      target.isNotEmpty) {
    return target;
  }
  return url;
}

/// The sort chips over a channel's video list (最新 / 最热门 / 最早).
List<YtSortChip> parseSortChips(Object? root) {
  final list = listRootOf(root) ?? root;
  final out = <YtSortChip>[];
  for (final chip in collectObjects(list, 'chipViewModel')) {
    final text = (chip['text'] ?? '').toString();
    final token = collectContinuationTokens(chip['tapCommand']).firstOrNull;
    if (text.isEmpty || token == null) continue;
    out.add(YtSortChip(text, token, selected: chip['selected'] == true));
  }
  return out;
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

  // the avatar is under `image` and nowhere else: collecting every `sources`
  // in the header picked the banner (2560 wide) as the largest "avatar"
  final avatar = largestThumbnail([
    for (final sources in collectByKey(header['image'], 'sources'))
      ...mapList(sources, YtThumbnail.fromJson),
  ]);
  final banner = largestThumbnail([
    for (final sources in collectByKey(header['banner'], 'sources'))
      ...mapList(sources, YtThumbnail.fromJson),
  ]);

  // "@handle", then "5.2M subscribers • 1.2K videos", as metadata rows
  final rows = <String>[
    for (final parts in collectByKey(header['metadata'], 'metadataParts'))
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

  final description = [
    for (final d in collectObjects(header['description'], 'description'))
      readText(d).trim(),
    readText(header['description']).trim(),
  ].firstWhere((s) => s.isNotEmpty, orElse: () => '');

  final link = [
    for (final a in collectObjects(
      header['attribution'],
      'attributionViewModel',
    ))
      readText(a['text']).trim(),
  ].firstWhere((s) => s.isNotEmpty, orElse: () => '');

  return YtChannelInfo(
    channelId: channelId,
    name: name,
    avatar: avatar,
    banner: banner,
    handle: pick((r) => r.startsWith('@')),
    subscriberText: pick((r) => r.contains('subscriber') || r.contains('订阅')),
    videoCountText: pick((r) => r.contains('video') || r.contains('视频')),
    description: description,
    link: _orNull(link),
  );
}

/// The header of a playlist page, in either of the two shapes it arrives
/// in: `pageHeaderViewModel` (a channel's own playlist) or
/// `playlistHeaderRenderer` (the uploads list, `VLUU…`).
YtPlaylistInfo? parsePlaylistInfo(Object? root, String playlistId) {
  if (collectObjects(root, 'playlistHeaderRenderer').firstOrNull
      case final h?) {
    return YtPlaylistInfo(
      playlistId: playlistId,
      title: readText(h['title']),
      ownerName: _orNull(readText(h['ownerText'])),
      ownerChannelId: _browseIdIn(h['ownerText'] ?? h['ownerEndpoint']),
      countText: _orNull(readText(h['numVideosText'])),
      viewCountText: _orNull(readText(h['viewCountText'])),
    );
  }
  final header = collectObjects(
    (root is Map) ? root['header'] : null,
    'pageHeaderViewModel',
  ).firstOrNull;
  if (header == null) return null;
  final parts = <Map>[
    for (final list in collectByKey(header['metadata'], 'metadataParts'))
      if (list is List) ...list.whereType<Map>(),
  ];
  final texts = [
    for (final part in parts) readText(part['text']).trim(),
  ]..removeWhere((s) => s.isEmpty);
  String? owner;
  String? ownerId;
  for (final part in parts) {
    if (part['avatarStack'] case final Map stack) {
      final text = collectObjects(stack, 'avatarStackViewModel')
          .map((a) => readText(a['text']))
          .firstWhere((s) => s.isNotEmpty, orElse: () => '');
      // '创建者：Kurzgesagt – In a Nutshell': the name is after the colon
      owner = text.split(RegExp('[:：]')).last.trim();
      ownerId = _browseIdIn(stack);
    }
  }
  return YtPlaylistInfo(
    playlistId: playlistId,
    title: [
      for (final c in collectByKey(header['title'], 'content'))
        if (c is String) c.trim(),
    ].firstWhere((s) => s.isNotEmpty, orElse: () => ''),
    ownerName: _orNull(owner ?? ''),
    ownerChannelId: ownerId,
    countText: texts
        .where((t) => RegExp(r'\d').hasMatch(t) && !t.contains('观看'))
        .where((t) => !t.toLowerCase().contains('view'))
        .firstOrNull,
    viewCountText: texts
        .where((t) => t.contains('观看') || t.toLowerCase().contains('view'))
        .firstOrNull,
  );
}

/// The post and the comments token of a `FEpost_detail` response.
YtPostDetail? parsePostDetail(Object? root) {
  final post = parseChannelPosts(root).firstOrNull;
  if (post == null) return null;
  return YtPostDetail(post, parseCommentsContinuationToken(root));
}

// ------------------------------------------------------------- helpers

List<Map> _rowsOf(Map meta) =>
    collectObjects(meta['metadata'], 'contentMetadataViewModel')
        .expand((v) => (v['metadataRows'] as List?) ?? const [])
        .whereType<Map>()
        .toList(growable: false);

List<String> _metadataTexts(Map<dynamic, dynamic> row) => [
  for (final part in (row['metadataParts'] as List?) ?? const [])
    if (part is Map && readText(part['text']).isNotEmpty)
      readText(part['text']),
];

List<String> _badgeTexts(Map<String, dynamic> m) => [
  for (final b in collectObjects(m['contentImage'], 'thumbnailBadgeViewModel'))
    if (b['text'] case final String t when t.isNotEmpty) t,
];

String? _orNull(String s) => s.isEmpty ? null : s;

String? _browseIdIn(Object? node) {
  for (final e in collectObjects(node, 'browseEndpoint')) {
    final id = e['browseId'];
    if (id is String && id.isNotEmpty) return id;
  }
  return null;
}
