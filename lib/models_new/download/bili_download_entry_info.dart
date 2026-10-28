import 'dart:io' show File;

import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:get/route_manager.dart';
import 'package:material_ui/material_ui.dart';

export 'package:PiliPlus/models_new/download/download_entry.dart';

class BiliDownloadEntryInfo extends DownloadEntry {
  /// [DownloadEntry.platform] of these.
  static const platformId = 'bilibili';

  int mediaType;
  bool hasDashAudio;
  @override
  bool isCompleted;
  @override
  int totalBytes;
  @override
  int downloadedBytes;
  @override
  final String title;
  String? typeTag;
  @override
  final String cover;
  int? videoQuality;
  int preferedVideoQuality;
  String qualityPithyDescription;
  final int guessedTotalBytes;
  @override
  int totalTimeMilli;
  final int danmakuCount;
  @override
  final int timeUpdateStamp;
  final int timeCreateStamp;
  final bool canPlayInAdvance;
  bool interruptTransformTempFile;
  final int avid;
  final int? spid;
  final String bvid;
  final int? ownerId;
  @override
  final String? ownerName;
  PageInfo? pageData;
  final String? seasonId;
  final SourceInfo? source;
  EpInfo? ep;

  /// Absolute path of the merged single-file video (audio + video), set once
  /// the downloaded DASH streams have been remuxed. Null for legacy entries
  /// that still play from the separate `.m4s` files.
  @override
  String? mergedPath;

  /// The other exported files when the segments of an old (durl) stream had
  /// no common MP4 mapping and were kept as they are: [mergedPath] is then
  /// only the first part, so the entry is complete on disk but not playable
  /// as one video.
  @override
  List<String>? mergedParts;

  /// LibrePili: the video is complete, the extras next to it (comments,
  /// subtitles, ...) are not saved yet; they are saved again after a
  /// restart.
  @override
  bool extrasPending;

  /// LibrePili: the video is complete, its transcript is not: transcribed
  /// in the background (DownloadTranscripts), after a restart too.
  @override
  bool transcriptPending;

  /// LibrePili (Android local player): the video is played from this
  /// `content://` URI (system grant, not copied); [mergedPath] then names it
  /// inside a cache folder that holds only the small side files. Not saved.
  String? playUri;

  /// Stable identity of [playUri] (provider + document id), for the resume
  /// position. Not saved.
  String? playKey;

  int get cid => source?.cid ?? pageData!.cid;

  @override
  DownloadKey get key => 'bili:$cid';

  @override
  String get platform => platformId;

  @override
  String get logLabel => '$cid';

  /// [typeTag] names the stream sub-folder; an `entry.json` written by
  /// another client may have none, so every path built from it uses this
  /// fallback (never `typeTag!`, which crashes the playback path).
  @override
  String get streamTypeTag => typeTag ?? '0';

  String get pageId => seasonId ?? avid.toString();

  @override
  String get groupId => pageId;

  @override
  String get groupTitle => title;

  @override
  int get sortKey => ep?.sortIndex ?? pageData!.page;

  /// The quality downloaded (not the one asked for).
  @override
  String? get qualityLabel => switch (videoQuality) {
    final videoQuality? => VideoQuality.fromCode(videoQuality).shortDesc,
    null => null,
  };

  @override
  String get showTitle {
    if (pageData case PageInfo(:final part)) {
      return part != null && part.isNotEmpty ? part : title;
    }
    if (ep case final ep?) {
      return ep.showTitle ?? '${ep.index} ${ep.indexTitle}';
    }
    return title;
  }

  Widget moreBtn(ColorScheme colorScheme) => SizedBox(
    width: 29,
    height: 29,
    child: PopupMenuButton(
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      icon: Icon(
        Icons.more_vert_outlined,
        color: colorScheme.outline,
        size: 18,
      ),
      itemBuilder: (_) => [
        PopupMenuItem(
          height: 38,
          child: const Text('查看详情页', style: TextStyle(fontSize: 13)),
          onTap: () {
            if (ep case final ep?) {
              if (ep.from == VideoType.pugv.name) {
                PageUtils.viewPugv(
                  seasonId: seasonId,
                  epId: ep.episodeId,
                );
              } else {
                PageUtils.viewPgc(
                  seasonId: seasonId,
                  epId: ep.episodeId,
                );
              }
              return;
            }
            PageUtils.toVideoPage(
              aid: avid,
              bvid: bvid,
              cid: cid,
              epId: ep?.episodeId,
              title: title,
              cover: cover,
              isVertical: pageData?.isVertical ?? false,
            );
          },
        ),
        if (PlatformUtils.isDesktop)
          PopupMenuItem(
            height: 38,
            child: const Text('打开本地文件夹', style: TextStyle(fontSize: 13)),
            onTap: () => PathUtils.openDir(
              mergedPath != null ? File(mergedPath!).parent.path : entryDirPath,
            ),
          )
        else
          PopupMenuItem(
            height: 38,
            child: Text(
              mergedPath != null ? '复制视频路径' : '复制缓存路径',
              style: const TextStyle(fontSize: 13),
            ),
            onTap: () => Utils.copyText(mergedPath ?? entryDirPath),
          ),
        if (ownerId case final mid?)
          PopupMenuItem(
            height: 38,
            child: Text(
              '访问${ownerName != null ? '：$ownerName' : '用户主页'}',
              style: const TextStyle(fontSize: 13),
            ),
            onTap: () => Get.toNamed('/member?mid=$mid'),
          ),
      ],
    ),
  );

  BiliDownloadEntryInfo({
    this.mediaType = 1,
    this.hasDashAudio = false,
    required this.isCompleted,
    required this.totalBytes,
    required this.downloadedBytes,
    required this.title,
    this.typeTag,
    required this.cover,
    this.videoQuality,
    required this.preferedVideoQuality,
    this.qualityPithyDescription = '',
    required this.guessedTotalBytes,
    required this.totalTimeMilli,
    required this.danmakuCount,
    this.timeUpdateStamp = 0,
    this.timeCreateStamp = 0,
    this.canPlayInAdvance = false,
    this.interruptTransformTempFile = false,
    required this.avid,
    this.spid,
    required this.bvid,
    this.ownerId,
    this.ownerName,
    this.pageData,
    this.seasonId,
    this.source,
    this.ep,
    this.mergedPath,
    this.mergedParts,
    this.extrasPending = false,
    this.transcriptPending = false,
  });

  factory BiliDownloadEntryInfo.fromJson(
    Map<String, dynamic> json,
  ) => BiliDownloadEntryInfo(
    mediaType: json['media_type'] as int? ?? 1,
    hasDashAudio: json['has_dash_audio'] as bool? ?? false,
    isCompleted: json['is_completed'] as bool,
    totalBytes: json['total_bytes'] as int,
    downloadedBytes: json['downloaded_bytes'] as int,
    title: json['title'] as String,
    typeTag: json['type_tag'] as String?,
    cover: json['cover'] as String,
    videoQuality: json['video_quality'] as int?,
    preferedVideoQuality: json['prefered_video_quality'] as int,
    qualityPithyDescription: json['quality_pithy_description'] as String? ?? '',
    guessedTotalBytes: json['guessed_total_bytes'] as int,
    totalTimeMilli: json['total_time_milli'] as int,
    danmakuCount: json['danmaku_count'] as int,
    timeUpdateStamp: json['time_update_stamp'] as int? ?? 0,
    timeCreateStamp: json['time_create_stamp'] as int? ?? 0,
    canPlayInAdvance: json['can_play_in_advance'] as bool? ?? false,
    interruptTransformTempFile:
        json['interrupt_transform_temp_file'] as bool? ?? false,
    avid: json['avid'] as int,
    spid: json['spid'] as int?,
    bvid: json['bvid'] as String,
    ownerId: json['owner_id'] as int?,
    ownerName: json['owner_name'] as String?,
    pageData: json['page_data'] != null
        ? PageInfo.fromJson(json['page_data'] as Map<String, dynamic>)
        : null,
    seasonId: json['season_id'] as String?,
    source: json['source'] != null
        ? SourceInfo.fromJson(json['source'] as Map<String, dynamic>)
        : null,
    ep: json['ep'] != null
        ? EpInfo.fromJson(json['ep'] as Map<String, dynamic>)
        : null,
    mergedPath: json['merged_path'] as String?,
    mergedParts: (json['merged_parts'] as List?)?.whereType<String>().toList(),
    extrasPending: json['extras_pending'] as bool? ?? false,
    transcriptPending: json['transcript_pending'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'media_type': mediaType,
    'has_dash_audio': hasDashAudio,
    'is_completed': isCompleted,
    'total_bytes': totalBytes,
    'downloaded_bytes': downloadedBytes,
    'title': title,
    'type_tag': ?typeTag,
    'cover': cover,
    'video_quality': ?videoQuality,
    'prefered_video_quality': preferedVideoQuality,
    'quality_pithy_description': qualityPithyDescription,
    'guessed_total_bytes': guessedTotalBytes,
    'total_time_milli': totalTimeMilli,
    'danmaku_count': danmakuCount,
    'time_update_stamp': timeUpdateStamp,
    'time_create_stamp': timeCreateStamp,
    'can_play_in_advance': canPlayInAdvance,
    'interrupt_transform_temp_file': interruptTransformTempFile,
    'avid': avid,
    'spid': ?spid,
    'bvid': bvid,
    'owner_id': ownerId,
    'owner_name': ownerName,
    'page_data': ?pageData?.toJson(),
    'season_id': ?seasonId,
    'source': ?source?.toJson(),
    'ep': ?ep?.toJson(),
    'merged_path': ?mergedPath,
    'merged_parts': ?mergedParts,
    if (extrasPending) 'extras_pending': true,
    if (transcriptPending) 'transcript_pending': true,
  };
}

class PageInfo {
  final int cid;
  final int page;
  final String? from;
  final String? part;
  final String? vid;
  final bool hasAlias;
  final int tid;
  int width;
  int height;
  final int rotate;
  final String? downloadTitle;
  final String? downloadSubtitle;

  bool get cacheWidth => width <= height;

  bool get isVertical => rotate == 1 ? width > height : height > width;

  PageInfo({
    required this.cid,
    required this.page,
    this.from,
    this.part,
    this.vid,
    required this.hasAlias,
    required this.tid,
    this.width = 0,
    this.height = 0,
    this.rotate = 0,
    this.downloadTitle,
    this.downloadSubtitle,
  });

  factory PageInfo.fromJson(Map<String, dynamic> json) => PageInfo(
    cid: json['cid'] as int,
    page: json['page'] as int,
    from: json['from'] as String?,
    part: json['part'] as String?,
    vid: json['vid'] as String?,
    hasAlias: json['has_alias'] as bool,
    tid: json['tid'] as int,
    width: json['width'] as int? ?? 0,
    height: json['height'] as int? ?? 0,
    rotate: json['rotate'] as int? ?? 0,
    downloadTitle: json['download_title'] as String?,
    downloadSubtitle: json['download_subtitle'] as String?,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'cid': cid,
    'page': page,
    'from': ?from,
    'part': ?part,
    'vid': ?vid,
    'has_alias': hasAlias,
    'tid': tid,
    'width': width,
    'height': height,
    'rotate': rotate,
    'download_title': downloadTitle,
    'download_subtitle': downloadSubtitle,
  };
}

class SourceInfo {
  final int avId;
  final int cid;

  SourceInfo({
    required this.avId,
    required this.cid,
  });

  factory SourceInfo.fromJson(Map<String, dynamic> json) => SourceInfo(
    avId: json['av_id'] as int,
    cid: json['cid'] as int,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'av_id': avId,
    'cid': cid,
  };
}

class EpInfo {
  final int avId;
  final int page;
  final int danmaku;
  final String cover;
  final int episodeId;
  final String index;
  final String indexTitle;
  final String? showTitle;
  final String from;
  final int seasonType;
  int width;
  int height;
  final int rotate;
  final String link;
  final String bvid;
  final int sortIndex;

  EpInfo({
    required this.avId,
    required this.page,
    required this.danmaku,
    required this.cover,
    required this.episodeId,
    required this.index,
    required this.indexTitle,
    this.showTitle,
    required this.from,
    required this.seasonType,
    required this.width,
    required this.height,
    required this.rotate,
    this.link = '',
    this.bvid = '',
    this.sortIndex = 0,
  });

  factory EpInfo.fromJson(Map<String, dynamic> json) => EpInfo(
    avId: json['av_id'] as int,
    page: json['page'] as int,
    danmaku: json['danmaku'] as int,
    cover: json['cover'] as String,
    episodeId: json['episode_id'] as int,
    index: json['index'] as String,
    indexTitle: json['index_title'] as String,
    showTitle: json['show_title'] as String?,
    from: json['from'] as String,
    seasonType: json['season_type'] as int,
    width: json['width'] as int,
    height: json['height'] as int,
    rotate: json['rotate'] as int,
    link: json['link'] as String? ?? '',
    bvid: json['bvid'] as String? ?? '',
    sortIndex: json['sort_index'] as int? ?? 0,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'av_id': avId,
    'page': page,
    'danmaku': danmaku,
    'cover': cover,
    'episode_id': episodeId,
    'index': index,
    'index_title': indexTitle,
    'show_title': showTitle,
    'from': from,
    'season_type': seasonType,
    'width': width,
    'height': height,
    'rotate': rotate,
    'link': link,
    'bvid': bvid,
    'sort_index': sortIndex,
  };
}
