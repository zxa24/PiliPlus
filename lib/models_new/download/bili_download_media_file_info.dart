sealed class BiliDownloadMediaInfo {
  const BiliDownloadMediaInfo();

  Map<String, String> get httpHeader => {};

  Map<String, dynamic> toJson();
}

class Type1 extends BiliDownloadMediaInfo {
  final int availablePeriodMilli;
  final String description;
  final String format;
  final String? from;
  final bool intact;
  final bool isDownloaded;
  final bool isResolved;
  final String marlinToken;
  final bool needLogin;
  final bool needVip;
  final int parseTimestampMilli;
  final List<Type1PlayerCodecConfig> playerCodecConfigList;
  final int playerError;
  final int quality;
  final List<Type1Segment> segmentList;
  final int timeLength;
  final String? typeTag;
  final String? userAgent;
  final String? referer;
  final int videoCodecId;
  final bool videoProject;

  @override
  Map<String, String> get httpHeader => {
    if (referer?.isNotEmpty ?? false) 'referer': referer!,
    if (userAgent?.isNotEmpty ?? false) 'user-agent': userAgent!,
  };

  Type1({
    required this.availablePeriodMilli,
    required this.description,
    required this.format,
    this.from,
    required this.intact,
    required this.isDownloaded,
    required this.isResolved,
    required this.marlinToken,
    required this.needLogin,
    required this.needVip,
    required this.parseTimestampMilli,
    required this.playerCodecConfigList,
    required this.playerError,
    required this.quality,
    required this.segmentList,
    required this.timeLength,
    this.typeTag,
    this.userAgent,
    this.referer,
    required this.videoCodecId,
    required this.videoProject,
  });

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'available_period_milli': availablePeriodMilli,
    'description': description,
    'format': format,
    'from': ?from,
    'intact': intact,
    'is_downloaded': isDownloaded,
    'is_resolved': isResolved,
    'marlin_token': marlinToken,
    'need_login': needLogin,
    'need_vip': needVip,
    'parse_timestamp_milli': parseTimestampMilli,
    'player_codec_config_list': playerCodecConfigList
        .map((e) => e.toJson())
        .toList(),
    'player_error': playerError,
    'quality': quality,
    'segment_list': segmentList.map((e) => e.toJson()).toList(),
    'time_length': timeLength,
    'type_tag': ?typeTag,
    'user_agent': ?userAgent,
    'referer': ?referer,
    'video_codec_id': videoCodecId,
    'video_project': videoProject,
  };
}

class Type1PlayerCodecConfig {
  final String player;
  final bool useIjkMediaCodec;

  Type1PlayerCodecConfig({
    required this.player,
    required this.useIjkMediaCodec,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'player': player,
    'use_ijk_media_codec': useIjkMediaCodec,
  };
}

class Type1Segment {
  final List<String> backupUrls;
  final int bytes;
  final int duration;
  final String md5;
  final String metaUrl;
  final int order;
  final String url;

  Type1Segment({
    required this.backupUrls,
    required this.bytes,
    this.duration = 0,
    required this.md5,
    required this.metaUrl,
    required this.order,
    required this.url,
  });

  factory Type1Segment.fromJson(Map<String, dynamic> json) => Type1Segment(
    backupUrls: List<String>.from(json['backup_urls']),
    bytes: json['bytes'] as int,
    duration: json['duration'] as int,
    md5: json['md5'] as String,
    metaUrl: json['meta_url'] as String,
    order: json['order'] as int,
    url: json['url'] as String,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'backup_urls': backupUrls,
    'bytes': bytes,
    'duration': duration,
    'md5': md5,
    'meta_url': metaUrl,
    'order': order,
    'url': url,
  };
}

class Type2 extends BiliDownloadMediaInfo {
  final int duration;
  final List<Type2File> video;
  final List<Type2File>? audio;
  final String? userAgent;
  final String? referer;

  Type2({
    this.duration = 0,
    required this.video,
    this.audio,
    this.userAgent,
    this.referer,
  });

  @override
  Map<String, String> get httpHeader => {
    if (referer?.isNotEmpty ?? false) 'referer': referer!,
    if (userAgent?.isNotEmpty ?? false) 'user-agent': userAgent!,
  };

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    'duration': duration,
    'video': video.map((e) => e.toJson()).toList(),
    'audio': ?audio?.map((e) => e.toJson()).toList(),
    'user_agent': ?userAgent,
    'referer': ?referer,
  };
}

class Type2File {
  final int id;
  final String baseUrl;
  final List<String>? backupUrl;
  final int bandwidth;
  final int codecid;
  int size;
  final String md5;
  final bool noRexcode;
  final String frameRate;
  final int width;
  final int height;
  final int dashDrmType;

  Type2File({
    required this.id,
    required this.baseUrl,
    this.backupUrl,
    required this.bandwidth,
    required this.codecid,
    required this.size,
    required this.md5,
    required this.noRexcode,
    this.frameRate = '',
    this.width = 1,
    this.height = 1,
    this.dashDrmType = 0,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'base_url': baseUrl,
    'backup_url': ?backupUrl,
    'bandwidth': bandwidth,
    'codecid': codecid,
    'size': size,
    'md5': md5,
    'no_rexcode': noRexcode,
    'frame_rate': frameRate,
    'width': width,
    'height': height,
    'dash_drm_type': dashDrmType,
  };
}

class None extends BiliDownloadMediaInfo {
  final String message;

  const None({
    required this.message,
  });

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}
