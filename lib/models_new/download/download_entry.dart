import 'package:PiliPlus/pages/common/multi_select/base.dart'
    show MultiSelectData;
import 'package:PiliPlus/services/download/download_progress.dart';

/// LibrePili: what a download is known by across platforms,
/// `<platform>:<id>` — `bili:<cid>`, later `yt:<videoId>`
/// (feature-logs/download-platforms design, §2.1). The queue, the list,
/// the retries, the extras and the transcripts keep their state by it.
typedef DownloadKey = String;

/// LibrePili: a download as the queue, the list, the retries, the extras,
/// the transcripts and the deletes see it, whatever its platform. What
/// only one platform has (bilibili's cid, its pages and episodes) stays on
/// that platform's entry (`BiliDownloadEntryInfo`) and its adapter
/// (`DownloadPlatform`).
abstract class DownloadEntry with MultiSelectData {
  /// [DownloadKey]: equal keys are the same download.
  DownloadKey get key;

  /// The platform's id (`DownloadPlatform.id`).
  String get platform;

  /// The entry in the event log's lines: bilibili's is the cid, as the logs
  /// (and the self tests reading them) have always had it.
  String get logLabel;

  /// The list's group: one video's parts, one season's episodes.
  String get groupId;
  String get groupTitle;
  int get sortKey;

  String get title;
  String get showTitle;

  /// The remote cover, kept as a record only.
  String get cover;
  String? get ownerName;
  int get totalTimeMilli;

  /// The quality badge's text; null: none.
  String? get qualityLabel;
  int get timeUpdateStamp;

  abstract int totalBytes;
  abstract int downloadedBytes;
  abstract bool isCompleted;

  /// Absolute path of the merged single-file video.
  abstract String? mergedPath;

  /// The other exported files when the streams were kept as separate
  /// parts: [mergedPath] is then only the first of them.
  abstract List<String>? mergedParts;

  /// The video is complete, the extras next to it are not saved yet.
  abstract bool extrasPending;

  /// The video is complete, its transcript is not.
  abstract bool transcriptPending;

  /// Where this download stands over all of its parts. Not saved.
  late final progress = DownloadProgress();

  late String pageDirPath;
  late String entryDirPath;
  late DownloadStatus status = .wait;

  /// The stream sub-folder of [entryDirPath] in use.
  String get streamTypeTag;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is DownloadEntry) {
      return key == other.key;
    }
    return false;
  }

  @override
  int get hashCode => key.hashCode;
}

enum DownloadStatus {
  downloading('正在下载'),
  audioDownloading('正在下载音频'),
  getDanmaku('获取弹幕'),
  getPlayUrl('获取播放地址'),
  merging('合并音视频'),
  //
  completed('下载完成'),
  failDownload('下载失败'),
  failDownloadAudio('音频下载失败'),
  failDanmaku('获取弹幕失败'),
  failPlayUrl('获取播放地址失败'),
  failMerge('合并音视频失败'),
  pause('暂停中'),
  wait('等待中'),
  // LibrePili: the video is complete, the extras next to it are not
  extrasWait('等待保存评论等'),
  savingExtras('保存评论等'),
  // LibrePili: failed, started again on its own in a while
  retryWait('下载失败，稍后自动重试'),
  ;

  final String message;
  const DownloadStatus(this.message);

  bool get isDownloading => index <= 4;

  /// LibrePili: stopped by a failure (the danmaku's is not one: the video
  /// goes on without it). The queue passes over these (`nextDownload` of
  /// the download service).
  bool get isFailed => switch (this) {
    failDownload || failDownloadAudio || failPlayUrl || failMerge => true,
    _ => false,
  };
}
