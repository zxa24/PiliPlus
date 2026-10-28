import 'dart:io' show File;

import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/services/download/download_progress.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:material_ui/material_ui.dart' show ColorScheme, Widget;

/// What a merge gives back: the exported file (null: failed), the stream
/// files it read, and whether they were damaged (the entry is not complete)
/// or corrupt at their full size (they are removed and downloaded again).
typedef DownloadMergeResult = ({
  String? output,
  List<String> inputs,
  bool damaged,
  bool corrupt,
});

/// How [DownloadPlatform.prepare] tells the service where it is (the
/// service passes it on only while that start is the current one).
typedef DownloadReport = ({
  void Function(DownloadStatus status) status,
  void Function(int done, int total) progress,
});

/// One of a platform's own items in a long-press menu.
typedef DownloadMenuItem = ({String label, Future<void> Function() onTap});

/// A title line of a list row.
typedef DownloadTitleLine = ({String text, int maxLines});

/// What a failure means for the queue ([DownloadPlatform.classify]).
enum DownloadFailure {
  /// The network: started again once the app is back on screen.
  network,

  /// The server said no (403 / 404 / 410): no retry within the transfer,
  /// the entry's own retry; also started again when the app is back.
  refused,

  /// A range, total or overlap that does not match: downloaded from 0
  /// once more, failed the second time.
  range,

  /// Nothing this app can download: failed for good.
  noFormat,

  /// The rest: the entry's own retry, not started again on the return.
  other,
}

/// LibrePili: one platform's part of the downloads (feature-logs/
/// download-platforms design, §3.1). The queue, the list, the search, the
/// retries, the extras, the transcripts and the deletes are the service's
/// and the pages'; what differs between platforms is asked of the entry's
/// platform (`DownloadService.platformOf`) through these.
abstract interface class DownloadPlatform {
  /// [DownloadEntry.platform] of its entries.
  String get id;

  /// The record file in an entry folder.
  String get recordFile;

  /// The entry of a record; throws when it cannot be read (the service
  /// leaves it out and says so in `lastError`).
  DownloadEntry parse(Map<String, dynamic> json);

  /// Writes the record (the service keeps the saves of one entry apart).
  Future<void> save(DownloadEntry entry);

  /// Before the start's media: optional, a failure does not stop the
  /// video.
  Future<void> prepare(DownloadEntry entry, DownloadReport report);

  /// The rest of a start: the play URLs (resolve), the identity of the
  /// streams already on disk, the cover and the transfers. Phase 1:
  /// bilibili's resolve and transport are still the two halves of one
  /// function (design §3.3), [gen] the start's generation, checked after
  /// each of its awaits as before.
  Future<void> start(DownloadEntry entry, int gen);

  /// The progress bar's bytes before a start's first ones arrive:
  /// (received, total) of the video and, apart, of the audio.
  ({(int, int) video, (int, int)? audio}) initialBytes(DownloadEntry entry);

  /// The export's base name: the title part (cut to length by the
  /// service) and the quality after it (may be empty).
  ({String name, String suffix}) exportName(DownloadEntry entry);

  /// Merges the downloaded streams into the export (it finds its own input
  /// files).
  Future<DownloadMergeResult> merge(DownloadEntry entry);

  /// Writes the extras beside the export; returns what was written.
  Future<Map<String, Object?>> extras({
    required DownloadEntry entry,
    required String folder,
    required String base,
    bool Function()? cancelled,
    DownloadProgress? progress,
  });

  /// The extras switched on (DownloadProgress.planExtras).
  Map<String, int> extrasPlan();

  /// The subtitle cache's key of the entry's transcript.
  SubtitleCacheKey transcriptKey(DownloadEntry entry);

  /// The recogniser session's key of its background transcription.
  String transcriptSessionKey(DownloadEntry entry);

  DownloadFailure classify(Object error);

  /// The group row's type badge (a season type); null: none.
  int? groupBadge(DownloadEntry entry);

  /// A row's title lines: the first, then any below it.
  ({DownloadTitleLine first, List<DownloadTitleLine> more}) titleLines(
    DownloadEntry entry,
    bool showTitle,
  );

  /// Whether the cover is decoded by its width (a portrait video); null:
  /// by the image's own shape.
  bool? coverCacheWidth(DownloadEntry entry);

  /// A row's cover: the saved file, else this remote address (null: a
  /// placeholder, nothing is fetched).
  ({File? file, String? network}) localCover(DownloadEntry entry);

  /// The list's watch progress badge; null: none.
  ({int positionMs, bool finished})? progressOf(DownloadEntry entry);

  /// The platform's items of an entry's long-press menu, and of a group's.
  List<DownloadMenuItem> menu(DownloadEntry entry);
  List<DownloadMenuItem> groupMenu(List<DownloadEntry> entries);

  /// The 「更多」 button.
  Widget actions(DownloadEntry entry, ColorScheme colorScheme);

  /// [entries] were deleted from the list: the platform's own offline
  /// state of them goes.
  Future<void> onDeleted(List<DownloadEntry> entries);

  /// Plays a complete entry offline; completes once its page is left.
  Future<void> openOffline(DownloadEntry entry);
}
