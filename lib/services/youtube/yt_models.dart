/// Plain Dart models for the YouTube data layer.
///
/// Deliberately local to this folder and deliberately free of GetX, Hive and
/// `lib/models_new/`: nothing here is a bilibili model, nothing here needs a
/// generated adapter, and everything here is constructible in a unit test from
/// a recorded JSON fixture.
library;

import 'package:PiliPlus/services/youtube/yt_json.dart';

/// One entry of a `thumbnails` array.
class YtThumbnail {
  const YtThumbnail({required this.url, this.width, this.height});

  factory YtThumbnail.fromJson(Map<String, dynamic> m) => YtThumbnail(
    // YouTube sometimes returns protocol-relative thumbnail URLs.
    url: _absolute((m['url'] ?? '').toString()),
    width: asInt(m['width']),
    height: asInt(m['height']),
  );

  final String url;
  final int? width;
  final int? height;

  static String _absolute(String u) => u.startsWith('//') ? 'https:$u' : u;

  @override
  String toString() => '$url (${width}x$height)';
}

/// Pick the largest thumbnail, or null when there is none.
YtThumbnail? largestThumbnail(List<YtThumbnail> list) {
  if (list.isEmpty) return null;
  return list.reduce(
    (a, b) =>
        (b.width ?? 0) * (b.height ?? 0) > (a.width ?? 0) * (a.height ?? 0)
        ? b
        : a,
  );
}

/// One entry of `streamingData.adaptiveFormats` or `streamingData.formats`.
class YtFormat {
  YtFormat(this.raw)
    : itag = asInt(raw['itag']) ?? 0,
      mimeType = (raw['mimeType'] ?? '').toString(),
      url = raw['url'] as String?,
      signatureCipher = (raw['signatureCipher'] ?? raw['cipher']) as String?,
      bitrate = asInt(raw['bitrate']) ?? 0,
      averageBitrate = asInt(raw['averageBitrate']),
      width = asInt(raw['width']),
      height = asInt(raw['height']),
      fps = asInt(raw['fps']),
      qualityLabel = raw['qualityLabel'] as String?,
      contentLength = asInt(raw['contentLength']),
      approxDurationMs = asInt(raw['approxDurationMs']),
      audioTrackId = ((raw['audioTrack'] as Map?)?['id'])?.toString(),
      audioTrackName = ((raw['audioTrack'] as Map?)?['displayName'])
          ?.toString(),
      audioIsDefault = (raw['audioTrack'] as Map?)?['audioIsDefault'] == true;

  factory YtFormat.fromJson(Map<String, dynamic> m) => YtFormat(m);

  /// The untouched entry, so a later stage can reach a field this model has
  /// not needed yet without a migration.
  final Map<String, dynamic> raw;

  final int itag;

  /// e.g. `video/mp4; codecs="avc1.4d401f"`.
  final String mimeType;

  /// The signed, ready-to-play URL. Measured 852/852 present on VISIONOS/IOS.
  final String? url;

  /// Present INSTEAD of [url] when the URL needs JavaScript deciphering.
  /// Measured 0/852 — but see [needsJavaScript]: it must stay detected, not
  /// assumed absent.
  final String? signatureCipher;

  final int bitrate;
  final int? averageBitrate;
  final int? width;
  final int? height;
  final int? fps;
  final String? qualityLabel;
  final int? contentLength;
  final int? approxDurationMs;

  /// `audioTrack.id`, e.g. `it.10` for the Italian dub, `en-US.4` for the
  /// original. Null on a video format and on videos with a single audio track.
  final String? audioTrackId;
  final String? audioTrackName;

  /// `audioTrack.audioIsDefault`. The ONLY reliable way to avoid selecting a
  /// dubbed track: measured, a naive highest-bitrate `mp4a` pick landed on the
  /// Italian dub.
  final bool audioIsDefault;

  bool get isVideo => mimeType.startsWith('video/');
  bool get isAudio => mimeType.startsWith('audio/');

  /// The codec string out of [mimeType], e.g. `avc1.4d401f`.
  String get codec =>
      RegExp(r'codecs="([^"]+)"').firstMatch(mimeType)?.group(1) ?? '';

  /// The codec family: `avc1`, `vp9`, `av01`, `mp4a`, `opus`, …
  String get codecFamily => codec.split('.').first;

  /// The container, e.g. `video/mp4` without the codec parameters.
  String get container => mimeType.split(';').first.trim();

  /// Does this format need a JavaScript engine before it can be played?
  ///
  /// Two independent triggers, both from NewPipe's deciphering path:
  ///   * `signatureCipher` present instead of `url` → needs the `sig` function;
  ///   * a `url` carrying `&n=` → needs the `n` throttling function, or
  ///     playback is throttled to a crawl (throttled, not blocked).
  ///
  /// Measured 0/852 today. It stays wired to a **(d) clientBroken** alarm
  /// rather than being assumed away: the risk is not that JS is needed now, it
  /// is that a future change moves us onto a cipher-bearing identity.
  bool get needsJavaScript => needsSignatureJs || hasThrottleParam;

  bool get needsSignatureJs => url == null && signatureCipher != null;

  bool get hasThrottleParam {
    final u = url;
    if (u == null) return false;
    try {
      return Uri.parse(u).queryParameters.containsKey('n');
    } catch (_) {
      return false;
    }
  }

  /// True when this format can be handed to a player as-is.
  bool get isPlayable => url != null && !hasThrottleParam;

  @override
  String toString() =>
      'itag=$itag $container ${qualityLabel ?? ''}'
      '${isAudio ? ' ${bitrate ~/ 1000}kbps'
                '${audioTrackId == null ? '' : ' [$audioTrackId'
                          '${audioIsDefault ? '*' : ''}]'}' : ''}'
      '${needsSignatureJs ? ' [CIPHER]' : ''}'
      '${hasThrottleParam ? ' [n]' : ''}';
}

/// One entry of `captions.playerCaptionsTracklistRenderer.captionTracks`.
class YtCaptionTrack {
  const YtCaptionTrack({
    required this.languageCode,
    required this.baseUrl,
    required this.vssId,
    required this.name,
    required this.translatable,
  });

  factory YtCaptionTrack.fromJson(Map<String, dynamic> m) => YtCaptionTrack(
    languageCode: (m['languageCode'] ?? '').toString(),
    baseUrl: (m['baseUrl'] ?? '').toString(),
    vssId: (m['vssId'] ?? '').toString(),
    name: readText(m['name']),
    translatable: m['isTranslatable'] == true,
  );

  final String languageCode;
  final String baseUrl;
  final String vssId;
  final String name;
  final bool translatable;

  /// NewPipe: `isAutoGenerated = vssId.startsWith("a.")`.
  bool get isAutoGenerated => vssId.startsWith('a.');

  /// The fetch URL for one of the caption formats.
  ///
  /// NewPipe (`YoutubeStreamExtractor.java:681-713`): strip any existing
  /// `&fmt=` / `&tlang=` from `baseUrl`, then append `&fmt=<format>`.
  /// Re-adding `&tlang=` is how auto-translation works — measured to work, and
  /// measured to be rate-limited hard (the second consecutive `tlang` request
  /// returned HTTP 429 while everything else kept answering 200).
  String urlFor(YtCaptionFormat format, {String? translateTo}) {
    var u = baseUrl
        .replaceAll(RegExp(r'&fmt=[^&]*'), '')
        .replaceAll(RegExp(r'&tlang=[^&]*'), '');
    u = '$u&fmt=${format.wire}';
    if (translateTo != null) u = '$u&tlang=$translateTo';
    return u;
  }

  @override
  String toString() =>
      '$languageCode${isAutoGenerated ? '(auto)' : ''} '
      'vss=$vssId "$name"';
}

/// Caption serialisations YouTube will hand back. All three measured to return
/// real content; `vtt` is the largest and the one a player wants.
enum YtCaptionFormat {
  vtt('vtt'),
  ttml('ttml'),
  srv3('srv3');

  const YtCaptionFormat(this.wire);

  final String wire;
}

/// Everything the app needs out of one `player` response.
class YtVideoDetail {
  const YtVideoDetail({
    required this.videoId,
    required this.title,
    required this.author,
    required this.channelId,
    required this.duration,
    required this.thumbnails,
    required this.formats,
    required this.captionTracks,
    required this.isLive,
    required this.expiresIn,
    this.description = '',
    this.viewCount,
    this.hlsManifestUrl,
  });

  /// Parse a `player` response body. Call only after [classifyYtPlayer] has
  /// returned [YtCause.ok]; the fields this reads are the ones the classifier
  /// has already proven present.
  factory YtVideoDetail.fromPlayerJson(Map<String, dynamic> root) {
    final vd = (root['videoDetails'] as Map?)?.cast<String, dynamic>() ?? {};
    final sd = (root['streamingData'] as Map?)?.cast<String, dynamic>() ?? {};
    final tracklist =
        ((root['captions'] as Map?)?['playerCaptionsTracklistRenderer'] as Map?)
            ?.cast<String, dynamic>() ??
        {};
    return YtVideoDetail(
      videoId: (vd['videoId'] ?? '').toString(),
      title: (vd['title'] ?? '').toString(),
      author: (vd['author'] ?? '').toString(),
      channelId: (vd['channelId'] ?? '').toString(),
      description: (vd['shortDescription'] ?? '').toString(),
      viewCount: asInt(vd['viewCount']),
      duration: Duration(seconds: asInt(vd['lengthSeconds']) ?? 0),
      isLive: vd['isLiveContent'] == true,
      thumbnails: mapList(
        (vd['thumbnail'] as Map?)?['thumbnails'],
        YtThumbnail.fromJson,
      ),
      formats: [
        ...mapList(sd['adaptiveFormats'], YtFormat.fromJson),
        ...mapList(sd['formats'], YtFormat.fromJson),
      ],
      captionTracks: mapList(
        tracklist['captionTracks'],
        YtCaptionTrack.fromJson,
      ),
      // Measured consistently 21540 s (~6 h).
      expiresIn: Duration(seconds: asInt(sd['expiresInSeconds']) ?? 0),
      hlsManifestUrl: sd['hlsManifestUrl'] as String?,
    );
  }

  final String videoId;
  final String title;
  final String author;
  final String channelId;
  final String description;
  final int? viewCount;
  final Duration duration;
  final bool isLive;
  final List<YtThumbnail> thumbnails;

  /// Adaptive formats first, then the muxed `formats` array.
  final List<YtFormat> formats;

  /// **Do not cache this as authoritative, and do not tell the user "this
  /// video has no subtitles" on the strength of one response.** Measured and
  /// unexplained: the same video, same client, same minute returned
  /// `captionTracks=1` three times and `captionTracks=21` on the fourth call.
  final List<YtCaptionTrack> captionTracks;

  final Duration expiresIn;

  /// Present on VISIONOS for live content; absent on ANDROID/IOS. Live is HLS
  /// and is handed to the player as a manifest URL, not as a stream pair.
  final String? hlsManifestUrl;

  List<YtFormat> get videoFormats =>
      formats.where((f) => f.isVideo).toList(growable: false);

  List<YtFormat> get audioFormats =>
      formats.where((f) => f.isAudio).toList(growable: false);

  YtThumbnail? get bestThumbnail => largestThumbnail(thumbnails);

  @override
  String toString() =>
      'YtVideoDetail($videoId "$title" by $author, ${duration.inSeconds}s, '
      '${formats.length} formats, ${captionTracks.length} caption tracks)';
}

/// One video in a search result page (or a related-videos shelf).
class YtSearchItem {
  const YtSearchItem({
    required this.videoId,
    required this.title,
    required this.author,
    required this.thumbnails,
    this.channelId,
    this.duration,
    this.viewCountText,
    this.publishedText,
    this.isLive = false,
  });

  final String videoId;
  final String title;
  final String author;
  final String? channelId;
  final List<YtThumbnail> thumbnails;

  /// Parsed from the overlay label (`4:13`, `1:02:30`) when present. YouTube
  /// does not give a numeric duration in these renderers.
  final Duration? duration;

  /// Left as text on purpose: YouTube returns localised, abbreviated strings
  /// ("1.8B views"), and inventing a number from them would be a lie.
  final String? viewCountText;
  final String? publishedText;

  final bool isLive;

  YtThumbnail? get bestThumbnail => largestThumbnail(thumbnails);

  @override
  String toString() => 'YtSearchItem($videoId "$title" by $author)';
}

/// One top-level comment.
class YtComment {
  const YtComment({
    required this.commentId,
    required this.author,
    required this.content,
    this.authorChannelId,
    this.authorAvatar,
    this.likeCountText,
    this.publishedText,
    this.replyCount = 0,
    this.isPinned = false,
    this.authorIsUploader = false,
    this.replyToken,
  });

  final String commentId;
  final String author;
  final String? authorChannelId;
  final YtThumbnail? authorAvatar;
  final String content;
  final String? likeCountText;
  final String? publishedText;
  final int replyCount;
  final bool isPinned;
  final bool authorIsUploader;

  /// The continuation that loads this thread's replies, when it has any.
  ///
  /// It is the token the comments page already had to identify in order to
  /// subtract it from the page-level one — this just keeps it instead of
  /// throwing it away.
  final String? replyToken;

  bool get hasReplies => replyToken != null;

  YtComment copyWith({String? replyToken}) => YtComment(
    commentId: commentId,
    author: author,
    authorChannelId: authorChannelId,
    authorAvatar: authorAvatar,
    content: content,
    likeCountText: likeCountText,
    publishedText: publishedText,
    replyCount: replyCount,
    isPinned: isPinned,
    authorIsUploader: authorIsUploader,
    replyToken: replyToken ?? this.replyToken,
  );

  @override
  String toString() =>
      'YtComment($author: '
      '${content.length > 40 ? '${content.substring(0, 40)}…' : content})';
}

/// A page of items plus the token that fetches the next one.
class YtPage<T> {
  const YtPage(this.items, this.continuation);

  final List<T> items;

  /// Opaque InnerTube continuation token, or null at the end of the list.
  final String? continuation;

  bool get hasMore => continuation != null;

  @override
  String toString() => 'YtPage(${items.length} items, more=$hasMore)';
}


/// A channel's own page header: the things a video response does not carry.
class YtChannelInfo {
  const YtChannelInfo({
    required this.channelId,
    required this.name,
    this.avatar,
    this.subscriberText,
    this.videoCountText,
    this.description,
  });

  final String channelId;
  final String name;
  final YtThumbnail? avatar;

  /// Left as YouTube's own localised string ("5.2M subscribers"): turning it
  /// into a number would be inventing precision it does not have.
  final String? subscriberText;
  final String? videoCountText;
  final String? description;

  @override
  String toString() => 'YtChannelInfo($name, $subscriberText)';
}

/// What the watch page knows about a video that its *player* response does
/// not: when it was published, how many times it has been seen in full, and
/// the channel's avatar and subscriber count.
///
/// All of it comes out of the `next` response the related shelf already
/// needs, so it costs no request. It replaced a separate channel `browse`
/// call that had been made for the avatar alone.
class YtVideoExtra {
  const YtVideoExtra({
    this.dateText,
    this.relativeDateText,
    this.viewCountText,
    this.ownerName,
    this.ownerAvatar,
    this.subscriberText,
  });

  /// '25 Oct 2009' — an absolute date, as YouTube formats it for the locale
  /// the request asked for.
  final String? dateText;

  /// '16 years ago'.
  final String? relativeDateText;

  /// '1,818,000,663 views' — the exact figure, not the abbreviated one the
  /// search results carry.
  final String? viewCountText;

  final String? ownerName;
  final YtThumbnail? ownerAvatar;

  /// '4.54m subscribers'.
  final String? subscriberText;

  bool get isEmpty =>
      dateText == null &&
      relativeDateText == null &&
      viewCountText == null &&
      ownerAvatar == null &&
      subscriberText == null;

  @override
  String toString() =>
      'YtVideoExtra($dateText, $viewCountText, $subscriberText)';
}
