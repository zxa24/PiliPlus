import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/services/youtube/yt_video_id.dart';

export 'package:PiliPlus/models_new/download/download_entry.dart';

/// LibrePili: a YouTube download (feature-logs/download-platforms design
/// §2.2, stage-2 plan §3.2): `<root>/yt_<videoId>/main/entry.librepili.json`,
/// one entry per video group. Its streams live in `main/<streamTag>/`.
class YtDownloadEntry extends DownloadEntry {
  YtDownloadEntry({
    required this.videoId,
    required this.title,
    required this.channel,
    required this.channelId,
    required this.cover,
    required this.durationMs,
    required this.maxHeight,
    this.streamTag,
    this.streamSource,
    this.quality,
    this.totalBytes = 0,
    this.downloadedBytes = 0,
    this.isCompleted = false,
    this.mergedPath,
    this.extrasPending = false,
    this.transcriptPending = false,
    this.commentsPending = false,
    this.commentsTries = 0,
    this.commentsAfter,
    this.commentsNote,
    required this.timeCreateStamp,
    required this.timeUpdateStamp,
  });

  /// [DownloadEntry.platform] of these.
  static const platformId = 'youtube';

  /// The record's `format`.
  static const format = 'librepili-entry-1';

  /// The record's file in the entry folder.
  static const recordFile = 'entry.librepili.json';

  /// A stream folder's name (`YtStreamTag`): `<videoItag>-<audioItag>`,
  /// `.` and 12 hex digits of the audio track's digest, `.drc`.
  static final streamTagPattern = RegExp(
    r'^(\d+)-(\d+)(?:\.([0-9a-f]{12}))?(\.drc)?$',
  );

  final String videoId;
  @override
  final String title;
  final String channel;
  final String channelId;

  /// The remote thumbnail (a record only: the list shows `cover.jpg`).
  @override
  final String cover;
  final int durationMs;

  /// The quality tier the panel chose (stage-2 plan §4.3, §4.5: exact, not a
  /// cap; a tier, not the short side).
  int maxHeight;

  /// The stream folder in use (`<videoItag>-<audioItag>[.<h>][.drc]`); null
  /// before the first start found its streams.
  String? streamTag;

  /// The source the last start took its streams from (`direct` /
  /// `invidious`).
  String? streamSource;

  /// What the list's quality badge says (the format's own label).
  String? quality;

  @override
  int totalBytes;
  @override
  int downloadedBytes;
  @override
  bool isCompleted;
  @override
  String? mergedPath;

  /// A YouTube export is one file: never parts.
  @override
  List<String>? get mergedParts => null;
  @override
  set mergedParts(List<String>? parts) {}

  @override
  bool extrasPending;
  @override
  bool transcriptPending;

  /// The comments a wall kept out of the extras are to be asked for again
  /// (`comments_pending`, review 2 item 5); the other extras are saved
  /// ([extrasPending] is cleared all the same).
  bool commentsPending;

  /// How many times they were asked for again and not saved.
  int commentsTries;

  /// Not asked for again before this.
  DateTime? commentsAfter;

  /// Why they were last not saved, or why they were given up.
  String? commentsNote;

  /// Seconds, as bilibili's (the list sorts by [timeUpdateStamp]).
  final int timeCreateStamp;
  @override
  int timeUpdateStamp;

  @override
  DownloadKey get key => 'yt:$videoId';
  @override
  String get platform => platformId;
  @override
  String get logLabel => 'yt:$videoId';
  @override
  String get groupId => 'yt_$videoId';
  @override
  String get groupTitle => title;
  @override
  int get sortKey => 0;
  @override
  String get showTitle => title;
  @override
  String? get ownerName => channel;
  @override
  int get totalTimeMilli => durationMs;
  @override
  String? get qualityLabel => quality;

  /// Never empty: the stream folder is joined from it (an empty one would
  /// be the entry folder itself, which is deleted recursively).
  @override
  String get streamTypeTag => streamTag ?? '0';

  /// Reads a record; throws [FormatException] when it is not one of these
  /// (another format, another platform, a malformed id).
  factory YtDownloadEntry.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format) {
      throw FormatException('not a $format record: ${json['format']}');
    }
    if (json['platform'] != platformId) {
      throw FormatException('not a YouTube record: ${json['platform']}');
    }
    final id = json['video_id'];
    if (id is! String || !isYouTubeVideoId(id)) {
      throw FormatException('not a YouTube video id: $id');
    }
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    return YtDownloadEntry(
      videoId: id,
      title: json['title'] as String? ?? '',
      channel: json['channel'] as String? ?? '',
      channelId: json['channel_id'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      durationMs: asInt(json['duration_ms']),
      maxHeight: asInt(json['max_height']),
      // joined into a path that is deleted recursively: only a stream
      // folder's name is kept (review 2bc)
      streamTag: switch (json['stream_tag']) {
        final String tag when streamTagPattern.hasMatch(tag) => tag,
        _ => null,
      },
      streamSource: json['stream_source'] as String?,
      quality: json['quality_label'] as String?,
      totalBytes: asInt(json['total_bytes']),
      downloadedBytes: asInt(json['downloaded_bytes']),
      isCompleted: json['is_completed'] == true,
      mergedPath: json['merged_path'] as String?,
      extrasPending: json['extras_pending'] == true,
      transcriptPending: json['transcript_pending'] == true,
      commentsPending: json['comments_pending'] == true,
      commentsTries: asInt(json['comments_tries']),
      commentsAfter: switch (json['comments_after']) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
        _ => null,
      },
      commentsNote: json['comments_note'] as String?,
      timeCreateStamp: asInt(json['time_create_stamp']),
      timeUpdateStamp: asInt(json['time_update_stamp']),
    );
  }

  Map<String, dynamic> toJson() => {
    'format': format,
    'platform': platformId,
    'video_id': videoId,
    'title': title,
    'channel': channel,
    'channel_id': channelId,
    'cover': cover,
    'duration_ms': durationMs,
    'max_height': maxHeight,
    'stream_tag': streamTag,
    'stream_source': streamSource,
    'quality_label': quality,
    'total_bytes': totalBytes,
    'downloaded_bytes': downloadedBytes,
    'is_completed': isCompleted,
    'merged_path': mergedPath,
    'extras_pending': extrasPending,
    'transcript_pending': transcriptPending,
    if (commentsPending) 'comments_pending': true,
    if (commentsTries > 0) 'comments_tries': commentsTries,
    if (commentsAfter case final after?)
      'comments_after': after.millisecondsSinceEpoch,
    'comments_note': ?commentsNote,
    'time_create_stamp': timeCreateStamp,
    'time_update_stamp': timeUpdateStamp,
  };
}
