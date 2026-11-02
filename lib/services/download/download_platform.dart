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

/// What a merge is given of the export (stage-2 plan §2.5): [claim] picks
/// and creates the export's file (a folder of its own, claimed so that an
/// overlapping merge cannot write into it), [failed] removes what a failed
/// merge left of that file (and its folder, once empty), [release] lets the
/// folder go once the merge is over either way. A parameter of
/// [DownloadPlatform.merge], not a member of [DownloadHost].
typedef DownloadExport = ({
  Future<String> Function() claim,
  Future<void> Function(String output) failed,
  void Function(String output) release,
});

/// One or two streams' transfer as the service sees it: its status, its
/// cancel and its task (design §4.4). `DownloadManager` is one; a platform
/// outside the service's library brings its own through [DownloadHost].
abstract interface class DownloadTransfer {
  DownloadStatus get status;

  /// Completes once the transfer has stopped; none of its callbacks comes
  /// after it.
  Future<void> get task;

  Future<void> cancel({required bool isDelete});
}

/// The service's callbacks for a transfer attached through
/// [DownloadHost.attach]. The two streams' bytes come apart; [videoDone]
/// says the video stream alone is complete (it does not merge); [done] is
/// called once: with no error when both are complete, with the error when
/// one failed.
typedef DownloadTransferReport = ({
  void Function(int received, int total) video,
  void Function(int received, int total) audio,
  void Function() videoDone,
  void Function([Object? error]) done,
});

/// What the service hands a platform outside its library (stage-2 plan
/// §2.2, design §10-5 item 6): the comparison of a start's generation, the
/// transfer slot with its callbacks, and the record's save. Nothing else.
abstract interface class DownloadHost {
  /// Whether [gen] is still the start under way.
  bool isCurrent(int gen);

  /// While [gen] is current and [entry] is still the current download (the
  /// same object): calls [build] with the service's callbacks, puts the
  /// transfer it makes into the video slot at once (the audio slot emptied)
  /// and returns it. Otherwise [build] is not called and null is returned.
  ///
  /// One live transfer per start: while the slot holds a transfer that
  /// still moves bytes (`downloading` / `audioDownloading`), another attach
  /// is refused — an assertion in a debug build, null and an event-log line
  /// otherwise — and the running one is left as it is.
  ///
  /// Every callback first checks that the slot still holds this transfer
  /// and that its `done` has not come yet: a callback after `done`, or of a
  /// transfer paused, deleted or replaced, is dropped. [build] must not
  /// call any of them itself.
  DownloadTransfer? attach(
    int gen,
    DownloadEntry entry,
    DownloadTransfer Function(DownloadTransferReport report) build,
  );

  /// Saves [entry]'s record after the saves of it already under way — for
  /// [gen]'s start only: while [gen] is current, [entry] is the current
  /// download (the same object) and its folder is there. A stale save is
  /// dropped, checked now and again when its turn in the queue comes (a
  /// late save of a deleted download must not write over the record of
  /// one added again in the same folder).
  Future<void> save(int gen, DownloadEntry entry);

  /// Saves [entry]'s record after the saves of it already under way, once
  /// [attach] took its transfer (review 2e): what the start found is the
  /// record's from then on, whatever start comes next (another start
  /// bumps the generation and pauses this one without a save of its own).
  /// Only while the service still holds this entry object (in its queue or
  /// list) and its folder is there — checked now and again when the save's
  /// turn comes: never over a deleted download, nor over the record of one
  /// added again in the same folder.
  Future<void> saveTaken(DownloadEntry entry);
}

/// What [DownloadPlatform.resolve] found for one start (stage-2 plan §2.3).
abstract interface class DownloadPlan {
  /// The stream folder (under the entry folder) this start uses.
  String get streamTag;

  /// The expected bytes of both streams; null: the estimate stays.
  int? get mediaGuess;

  /// Whether an audio stream comes with the video.
  bool get expectAudio;
}

/// A failed [DownloadPlatform.resolve] as a platform reports it, with what
/// it means (bilibili's resolve never throws one).
class DownloadResolveFailure implements Exception {
  const DownloadResolveFailure(this.kind, this.message);

  final DownloadFailure kind;
  final String message;

  @override
  String toString() => message;
}

/// A platform's own action on a failed entry of the list.
typedef DownloadFailureAction = ({
  String label,
  void Function(DownloadEntry entry) apply,
});

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

  /// The quality chosen is not on offer now (no source has it): the
  /// entry's own retry; also started again when the app is back.
  qualityUnavailable,

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

  /// [entry]'s folder still holds its record, as the list would read it:
  /// the start's orphan check (a download deleted while its cover was
  /// written) removes only a folder without one.
  bool hasRecord(DownloadEntry entry);

  /// The entry of a record; throws when it cannot be read (the service
  /// leaves it out and says so in `lastError`).
  DownloadEntry parse(Map<String, dynamic> json);

  /// Writes the record (the service keeps the saves of one entry apart).
  Future<void> save(DownloadEntry entry);

  /// Before the start's media: optional, a failure does not stop the
  /// video.
  Future<void> prepare(DownloadEntry entry, DownloadReport report);

  // The rest of a start comes in steps; the service checks the start's
  // generation between them (stage-2 plan §2.3): [resolve], the stream
  // folder and its identity, [cover], [transport].

  /// The streams on disk are complete: the start skips [resolve] and
  /// [cover] and goes straight to [transport], with no plan.
  bool streamsComplete(DownloadEntry entry);

  /// This start's play URLs and the stream folder they go into.
  Future<DownloadPlan> resolve(DownloadEntry entry);

  /// The identity of [plan]'s streams, compared with [readStreamKey]'s:
  /// another one empties the stream folder. Null: not compared.
  String? streamKey(DownloadPlan plan);

  /// The identity of the streams in the stream folder; null, or a throw:
  /// not known, the bytes are kept.
  Future<String?> readStreamKey(DownloadEntry entry);

  /// Writes [plan]'s identity into the stream folder.
  Future<void> writeStreamKey(DownloadEntry entry, DownloadPlan plan);

  /// Saves the cover in the entry folder; a failure does not stop the
  /// video.
  Future<bool> cover(DownloadEntry entry);

  /// Starts the transfers; [plan] is null when [streamsComplete]. [gen] is
  /// the start's generation.
  ///
  /// It returns once they are started, never awaiting a transfer's task:
  /// the service holds its start lock until it returns, and a pause, a
  /// delete or the next start (and the merge after the transfer) wait on
  /// that lock.
  Future<void> transport(DownloadEntry entry, DownloadPlan? plan, int gen);

  /// A failed start before the transfers counts as the network's whatever
  /// the error was (a failure off screen is started again on the return).
  bool get playUrlFailuresAreNetwork;

  /// The extras (comments, subtitles ...) are saved after the video.
  bool get extrasEnabled;

  /// Before the entry's own retry, and before a start again on the app's
  /// return, after a failure of [kind] (null: none recorded).
  void beforeRetry(DownloadEntry entry, DownloadFailure? kind);

  /// The progress bar's bytes before a start's first ones arrive:
  /// (received, total) of the video and, apart, of the audio; and, for a
  /// start whose streams are complete, the expected size and whether an
  /// audio stream comes (null: as they are).
  ({(int, int) video, (int, int)? audio, int? mediaGuess, bool? expectAudio})
  initialBytes(DownloadEntry entry);

  /// The export's base name: the title part (cut to length by the
  /// service) and the quality after it (may be empty).
  ({String name, String suffix}) exportName(DownloadEntry entry);

  /// Merges the downloaded streams into the export (it finds its own input
  /// files; [export] is the service's export folder).
  Future<DownloadMergeResult> merge(DownloadEntry entry, DownloadExport export);

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

  /// The platform's badge on a row's cover; null: none.
  String? platformBadge(DownloadEntry entry);

  /// The platform's action on a failed entry of the list; null: none.
  DownloadFailureAction? failureAction(DownloadEntry entry);

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
