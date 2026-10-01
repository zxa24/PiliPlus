/// The models a channel page needs beyond a video list: which tabs it has,
/// what a Short, a playlist and a post are, and a playlist page's header.
///
/// Kept apart from `yt_models.dart` because none of it is about a video's
/// playback, and that file is already long. Same rules: plain Dart, no GetX,
/// constructible from a recorded response in a unit test.
library;

import 'package:PiliPlus/services/youtube/yt_models.dart';

/// The channel tabs the app shows, in the order it shows them.
///
/// Each carries the URL suffix YouTube gives the tab (`/@handle/videos`) and
/// a fallback `params` value. The suffix is what identifies a tab: the titles
/// are localised (视频 / Videos / Vidéos), and the params have changed before
/// — `EgZ2aWRlb3M%3D`, the value this app used to send, now opens the Home
/// tab, and the uploads list the user saw was really a shelf of the home
/// page. The fallback is only the first request's; afterwards the params
/// are read off the response's own tab list.
enum YtChannelTab {
  videos('/videos', 'EgZ2aWRlb3PyBgQKAjoA', '视频'),
  shorts('/shorts', 'EgZzaG9ydHPyBgUKA5oBAA%3D%3D', 'Shorts'),
  streams('/streams', 'EgdzdHJlYW1z8gYECgJ6AA%3D%3D', '直播'),
  playlists('/playlists', 'EglwbGF5bGlzdHPyBgoKCEIGCgIQaCIA', '播放列表'),
  posts('/posts', 'EgVwb3N0c_IGBAoCSgA%3D', '帖子');

  const YtChannelTab(this.suffix, this.fallbackParams, this.label);

  /// The end of the tab's `webCommandMetadata.url`.
  final String suffix;
  final String fallbackParams;

  /// What the tab bar says. Fixed rather than YouTube's localised title, so
  /// the tab bar reads the same whatever `hl` the data was fetched in.
  final String label;

  /// The tab whose URL ends in [url]'s last path segment, if any.
  static YtChannelTab? fromUrl(String? url) {
    if (url == null) return null;
    for (final tab in values) {
      if (url.endsWith(tab.suffix)) return tab;
    }
    return null;
  }
}

/// One Short, from a `shortsLockupViewModel`.
///
/// YouTube gives a Short a title, a view count and a portrait thumbnail —
/// no date and no duration — so that is all this has.
class YtShortItem {
  const YtShortItem({
    required this.videoId,
    required this.title,
    required this.thumbnails,
    this.viewCountText,
  });

  final String videoId;
  final String title;
  final List<YtThumbnail> thumbnails;

  /// '64万次观看', as YouTube wrote it.
  final String? viewCountText;

  YtThumbnail? get bestThumbnail => largestThumbnail(thumbnails);

  @override
  String toString() => 'YtShortItem($videoId "$title")';
}

/// One playlist on a channel's 播放列表 tab.
class YtPlaylistItem {
  const YtPlaylistItem({
    required this.playlistId,
    required this.title,
    required this.thumbnails,
    this.countText,
    this.firstVideoTitle,
  });

  final String playlistId;
  final String title;
  final List<YtThumbnail> thumbnails;

  /// The cover badge, as YouTube wrote it: '28 集', '12 个视频'.
  final String? countText;

  /// The first metadata row: the title of the playlist's first video.
  final String? firstVideoTitle;

  YtThumbnail? get bestThumbnail => largestThumbnail(thumbnails);

  @override
  String toString() => 'YtPlaylistItem($playlistId "$title", $countText)';
}

/// The header of a playlist page (`browse VL<id>`).
class YtPlaylistInfo {
  const YtPlaylistInfo({
    required this.playlistId,
    required this.title,
    this.ownerName,
    this.ownerChannelId,
    this.countText,
    this.viewCountText,
  });

  final String playlistId;
  final String title;
  final String? ownerName;
  final String? ownerChannelId;

  /// '28 个视频'.
  final String? countText;

  /// '864,338次观看'.
  final String? viewCountText;

  /// The number in [countText], when there is one.
  int? get count {
    final digits = RegExp(r'[\d,]+').firstMatch(countText ?? '')?.group(0);
    return digits == null ? null : int.tryParse(digits.replaceAll(',', ''));
  }

  @override
  String toString() => 'YtPlaylistInfo($playlistId "$title", $countText)';
}

/// One run of a post's text. A run with a target is a link.
class YtTextRun {
  const YtTextRun(this.text, {this.url, this.browseId, this.videoId});

  final String text;

  /// An outside link. YouTube wraps these in its own redirect; the target is
  /// unwrapped from its `q` parameter where it can be.
  final String? url;

  /// A channel (`UC…`) or hashtag page.
  final String? browseId;

  /// A video.
  final String? videoId;

  bool get isLink => url != null || browseId != null || videoId != null;
}

/// One post on a channel's 帖子 tab, or the post a detail page is about.
///
/// The attachment is one of: images, a video, a poll — or nothing.
class YtPost {
  const YtPost({
    required this.postId,
    required this.author,
    required this.runs,
    this.authorChannelId,
    this.authorAvatar,
    this.publishedText,
    this.likeCountText,
    this.commentCountText,
    this.images = const [],
    this.video,
    this.pollChoices = const [],
    this.pollVotesText,
    this.detailParams,
  });

  final String postId;
  final String author;
  final String? authorChannelId;
  final YtThumbnail? authorAvatar;
  final List<YtTextRun> runs;
  final String? publishedText;

  /// '4575' — YouTube's own text, which may be abbreviated.
  final String? likeCountText;
  final String? commentCountText;

  /// The largest version of each attached image.
  final List<YtThumbnail> images;
  final YtSearchItem? video;
  final List<String> pollChoices;
  final String? pollVotesText;

  /// The `params` of the `FEpost_detail` browse that opens this post with
  /// its comments.
  final String? detailParams;

  String get text => runs.map((r) => r.text).join();

  @override
  String toString() =>
      'YtPost($postId, ${images.length} images, video=${video != null}, '
      'poll=${pollChoices.length})';
}

/// One of the sort chips over a channel's video list: 最新 / 最热门 / 最早.
///
/// Choosing one is a continuation request whose answer replaces the list.
class YtSortChip {
  const YtSortChip(this.text, this.token, {this.selected = false});

  final String text;
  final String token;
  final bool selected;

  @override
  String toString() => 'YtSortChip($text${selected ? ', selected' : ''})';
}

/// One page of one channel tab.
///
/// [info], [tabs] and [chips] arrive only with a tab's first page; a
/// continuation carries the items and the next token and nothing else.
class YtChannelTabPage {
  const YtChannelTabPage({
    required this.tab,
    required this.items,
    this.continuation,
    this.info,
    this.tabs = const {},
    this.chips = const [],
  });

  final YtChannelTab tab;

  /// [YtSearchItem] for videos and streams, [YtShortItem] for Shorts,
  /// [YtPlaylistItem] for playlists, [YtPost] for posts.
  final List<Object> items;
  final String? continuation;
  final YtChannelInfo? info;

  /// The tabs this channel has, with the params YouTube gave each.
  final Map<YtChannelTab, String> tabs;
  final List<YtSortChip> chips;

  @override
  String toString() =>
      'YtChannelTabPage(${tab.name}, ${items.length} items, '
      'more=${continuation != null}, tabs=${tabs.keys.map((t) => t.name)})';
}

/// One page of a playlist; [info] only with the first.
class YtPlaylistPage {
  const YtPlaylistPage(this.info, this.videos);

  final YtPlaylistInfo? info;
  final YtPage<YtSearchItem> videos;
}

/// A post's detail page: the post, and the door to its comments.
class YtPostDetail {
  const YtPostDetail(this.post, this.commentsToken, {this.commentCountText});

  final YtPost post;

  /// Null when the post has comments turned off, or the section moved.
  final String? commentsToken;

  /// '117 条评论' — YouTube's own count line, when the response carries it.
  final String? commentCountText;
}
