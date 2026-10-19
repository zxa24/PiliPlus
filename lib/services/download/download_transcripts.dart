/// LibrePili: a finished download transcribed to its end in the background,
/// and how far each download's transcript has got (user 2026-10-16:
/// 「下载完自动在后台把转录补完、下载列表里显示转录到了百分之多少」).
///
/// A download that finishes is marked (`transcript_pending` in its
/// entry.json) and transcribed from its file, one at a time, under its
/// part's cache key: what was transcribed before — while it was watched,
/// or by a run cut short — counts, only the gaps are made, and the cache
/// keeping it writes the files beside the video (TranscriptFiles). The mark
/// goes once the transcript reaches the end; a restart carries on with the
/// marked ones.
///
/// Only when nothing else has the recogniser: one job runs at a time
/// (AsrService.start takes the place of the one running), and a page's own
/// comes first — a page that starts one takes the place of this, which
/// goes on from the cache once the page lets go. Only with power to spare
/// (readAsrPower: a desktop, or a phone on its charger), as a session runs
/// to the end only then.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/asr/asr_schedule.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_files.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/model_bench/model_bench.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// How far a download's transcript has got, as the list shows it.
typedef TranscriptState = ({double fraction, bool running});

/// What the list says after a download's size: '' when it has no
/// transcript and is not waiting for one.
String transcriptLabel(TranscriptState? state, {bool pending = false}) {
  if (state == null) return '';
  final percent = (state.fraction * 100).floor();
  if (state.running) return '  转录中 $percent%';
  if (state.fraction >= 1) return '  已转录';
  if (pending && percent == 0) return '  等待转录';
  return '  转录 $percent%';
}

class DownloadTranscripts {
  DownloadTranscripts({
    required this.entries,
    required this.save,
  });

  /// The downloads, as the service has them.
  final List<BiliDownloadEntryInfo> Function() entries;

  /// Writes an entry's entry.json.
  final Future<void> Function(BiliDownloadEntryInfo entry) save;

  /// How far each part's transcript has got, by cid: 0..1 of its length.
  /// Only parts known to have one, or to be waiting for one.
  final progress = <int, double>{}.obs;

  /// The part transcribing now.
  final running = RxnInt();

  TranscriptState? stateOf(int cid) {
    final fraction = progress[cid];
    if (fraction == null) return null;
    return (fraction: fraction, running: running.value == cid);
  }

  AsrSession? _session;
  Timer? _retry;
  Timer? _watch;

  /// Failed runs per cid: past [_maxFailures] the part is given up on (its
  /// mark goes), so a file the recogniser cannot read is not tried for ever.
  final _failures = <int, int>{};
  static const _maxFailures = 3;

  /// How often a wait (another job, no power, no models) looks again.
  static const _again = Duration(seconds: 30);

  /// What the list shows of the downloads already there: read from the
  /// files beside them, in the background.
  Future<void> readKnown() async {
    for (final entry in entries()) {
      final merged = entry.mergedPath;
      if (!entry.isCompleted || merged == null) continue;
      final kept = await TranscriptFiles.read(
        merged,
        SubtitleCacheKey.bilibili(entry.cid),
        AsrService.recogniserId,
      );
      if (kept != null) {
        progress[entry.cid] = _fractionOf(
          entry,
          kept.coveredSeconds,
          kept.mediaEnd,
        );
      } else if (entry.transcriptPending && !_inSegments(entry)) {
        progress[entry.cid] = 0;
      }
    }
  }

  /// [entry] just finished: marked, and transcribed in its turn.
  Future<void> finished(BiliDownloadEntryInfo entry) async {
    if (!Pref.dlTranscribe || _inSegments(entry)) return;
    entry.transcriptPending = true;
    progress.putIfAbsent(entry.cid, () => 0);
    await save(entry);
    kick();
  }

  /// The cache kept [kept] of a part: the list shows how far it got.
  void kept(SubtitleCacheEntry kept, BiliDownloadEntryInfo entry) {
    progress[entry.cid] = _fractionOf(
      entry,
      kept.coveredSeconds,
      kept.mediaEnd,
    );
  }

  /// [cid]'s download was deleted: not transcribed any more.
  Future<void> forget(int cid) async {
    progress.remove(cid);
    _failures.remove(cid);
    if (running.value == cid) {
      final session = _session;
      _session = null;
      running.value = null;
      _watch?.cancel();
      if (session != null) await AsrService.to.stop(only: session);
      kick();
    }
  }

  static double _fractionOf(
    BiliDownloadEntryInfo entry,
    double covered,
    double? mediaEnd,
  ) {
    final length = mediaEnd ?? entry.totalTimeMilli / 1000;
    if (length <= 0) return covered > 0 ? 1 : 0;
    return math.min(1, covered / length);
  }

  /// Looks for the next part to transcribe, now or once what it waits for
  /// is there.
  void kick() {
    if (_session != null) return;
    _retry?.cancel();
    _retry = null;
    unawaited(_next());
  }

  void _later() {
    _retry?.cancel();
    _retry = Timer(_again, kick);
  }

  /// Kept as separate segments (no common MP4 mapping): the merged file is
  /// only the first of them, so a transcript of it would stop at its end
  /// and still read as complete (its length is that segment's). Not
  /// transcribed in the background.
  static bool _inSegments(BiliDownloadEntryInfo entry) =>
      entry.mergedParts != null;

  BiliDownloadEntryInfo? _pending() {
    for (final entry in entries()) {
      if (!entry.transcriptPending ||
          !entry.isCompleted ||
          _inSegments(entry)) {
        continue;
      }
      final merged = entry.mergedPath;
      if (merged != null && File(merged).existsSync()) return entry;
    }
    return null;
  }

  Future<void> _next() async {
    if (_session != null) return;
    final entry = _pending();
    if (entry == null) return;
    if (!Pref.dlTranscribe ||
        !Get.isRegistered<AsrService>() ||
        !AsrService.to.modelsReady ||
        AsrService.to.hasJob ||
        ModelBench.isRunning ||
        await readAsrPower() != AsrPower.unlimited) {
      _later();
      return;
    }
    final cid = entry.cid;
    // what is kept beside the video goes on where it was, as on the page,
    // rather than from the start when the cache has lost it
    try {
      final kept = await TranscriptFiles.read(
        entry.mergedPath!,
        SubtitleCacheKey.bilibili(cid),
        AsrService.recogniserId,
      );
      if (kept != null) await AsrService.to.cache.adopt(kept);
    } catch (_) {}
    // looked again after the waits above: a page may have started one
    if (_session != null || AsrService.to.hasJob || ModelBench.isRunning) {
      _later();
      return;
    }
    final session = _session = await AsrService.to.start(
      key: 'download:$cid',
      source: entry.mergedPath!,
      cache: SubtitleCacheKey.bilibili(cid),
    );
    running.value = cid;
    progress.putIfAbsent(cid, () => 0);
    EventLog.add('asr', 'transcribing download $cid in the background');
    _watch?.cancel();
    var looking = false;
    _watch = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (looking || !identical(_session, session)) return;
      looking = true;
      try {
        await _look(session, entry);
      } finally {
        looking = false;
      }
    });
  }

  Future<void> _look(AsrSession session, BiliDownloadEntryInfo entry) async {
    final fraction = progress[entry.cid] = _fractionOf(
      entry,
      session.coveredSeconds,
      session.duration,
    );
    final state = session.state.value;
    // a page's own took its place: [AsrService.start] marks it displaced,
    // one resting in standby too (it is stopped with a reason); and as a
    // second check, the service no longer has it for its key
    final displaced =
        session.wasDisplaced ||
        !identical(AsrService.to.sessionFor(session.key), session);
    // stopped by the model guard (the app went away): it carries on when
    // the app is back
    if (!displaced && session.isSuspended) return;
    if (state.isBusy || state.stage == AsrStage.idle) {
      // a phone taken off its charger: a run to the end waits for it
      if (await readAsrPower() == AsrPower.unlimited) return;
      if (!identical(_session, session)) return;
      EventLog.add('asr', 'background transcription paused: on battery');
      await _end(session, entry, outcome: _Outcome.paused);
      return;
    }
    await _end(
      session,
      entry,
      outcome: switch (state.stage) {
        AsrStage.done => _Outcome.done,
        _ when displaced => _Outcome.paused,
        // stood still short of the end (standby with no viewer to wait for):
        // what the transcript has is all there is, near enough
        AsrStage.standby when fraction >= 0.99 => _Outcome.done,
        _ => _Outcome.failed,
      },
    );
  }

  Future<void> _end(
    AsrSession session,
    BiliDownloadEntryInfo entry, {
    required _Outcome outcome,
  }) async {
    if (!identical(_session, session)) return;
    _watch?.cancel();
    _session = null;
    running.value = null;
    final cid = entry.cid;
    // displaced: a page's own took its place, and goes on from the cache
    if (session.wasDisplaced) {
      EventLog.add('asr', 'background transcription of $cid gave way');
    } else {
      await AsrService.to.stop(only: session);
    }
    if (outcome == _Outcome.done) {
      progress[cid] = 1;
      entry.transcriptPending = false;
      await save(entry);
      _failures.remove(cid);
      EventLog.add('asr', 'download $cid transcribed');
    } else if (outcome == _Outcome.failed) {
      final n = _failures[cid] = (_failures[cid] ?? 0) + 1;
      EventLog.add(
        'asr',
        'background transcription of $cid failed ($n): '
            '${session.state.value.message}',
      );
      if (n >= _maxFailures) {
        entry.transcriptPending = false;
        await save(entry);
      }
    }
    if (kDebugMode) debugPrint('download transcripts: $cid ${outcome.name}');
    // the next at once after one done; a wait before trying again otherwise
    outcome == _Outcome.done ? kick() : _later();
  }

  void dispose() {
    _retry?.cancel();
    _watch?.cancel();
  }
}

enum _Outcome { done, paused, failed }
