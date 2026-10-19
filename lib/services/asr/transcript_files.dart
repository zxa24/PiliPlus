/// LibrePili: a downloaded video's on-device transcript, kept beside the
/// video (user 2026-10-16: 「转录存成 .asr.srt 放进下载文件夹」).
///
/// The transcript otherwise lives only in the subtitle cache: in the cache
/// directory, bounded, cleared by the system or the 字幕缓存上限 setting,
/// and never in a folder that is copied to another device. Two files go next
/// to `base.mp4`:
/// - `base.asr.srt`: the transcript as the player shows it, for people and
///   other players. The app does not read it back: [entrySuffix] has more.
/// - `base.asr.json`: the cache entry itself. An SRT says what was heard, not
///   what was listened to — a stretch with no lines can be silence or not
///   yet transcribed — so only the entry lets the app go on where it was,
///   transcribing just the gaps; it is put back into the cache when the
///   video is opened and the cache knows less.
///
/// Written whenever the cache keeps the transcript of a part with a finished
/// download, and when a download finishes on a part already transcribed. A
/// file covering more than what would replace it is left as it is: a copy
/// brought from another device is not overwritten by the little this one
/// has made of it before reading it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/asr_schedule.dart';
import 'package:PiliPlus/services/asr/subtitle_punctuation.dart';
import 'package:PiliPlus/services/asr/transcriber.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

abstract final class TranscriptFiles {
  static const srtSuffix = '.asr.srt';
  static const entrySuffix = '.asr.json';

  static String srtPath(String videoPath) => _beside(videoPath, srtSuffix);

  static String entryPath(String videoPath) => _beside(videoPath, entrySuffix);

  static String _beside(String videoPath, String suffix) => path.join(
    path.dirname(videoPath),
    '${path.basenameWithoutExtension(videoPath)}$suffix',
  );

  /// [entry]'s transcript as the player shows it (AsrSession.forDisplay):
  /// each line punctuated by the language of its own speech, the language
  /// voted from its segments where a line's cannot be trusted.
  static List<AsrCue> displayed(SubtitleCacheEntry entry) {
    final store = TranscriptStore()..restore(entry.runs);
    final segments = [for (final run in store.runs) ...run.segments]
      ..sort((a, b) => a.start.compareTo(b.start));
    final vote = AsrLanguageVote();
    for (final s in segments) {
      vote.add(s.language, s.weight);
    }
    final language = vote.winner;
    return store.cues.forDisplayBySpeech(
      speechSpansOf(segments, fallback: language),
      language,
    );
  }

  /// Writes [entry]'s transcript beside the video at [videoPath]; false when
  /// there is none, or the files there cover more already. One video's
  /// writes go one after another.
  static Future<bool> write(SubtitleCacheEntry entry, String videoPath) {
    final key = entryPath(videoPath);
    final write = (_writes[key] ?? Future.value()).then(
      (_) => _write(entry, videoPath),
    );
    final settled = write.then<void>((_) {}, onError: (_) {});
    _writes[key] = settled;
    unawaited(
      settled.whenComplete(() {
        if (identical(_writes[key], settled)) _writes.remove(key);
      }),
    );
    return write;
  }

  static final _writes = <String, Future<void>>{};

  /// Until every write asked for so far is done: before the app ends. One
  /// it ended in the middle of left its scratch file in the folder.
  static Future<void> flush() => Future.wait(_writes.values.toList());

  static Future<bool> _write(SubtitleCacheEntry entry, String videoPath) async {
    if (entry.runs.isEmpty) return false;
    final covered = entry.coveredSeconds;
    if (covered <= 0) return false;
    final there = await _read(videoPath);
    if (there != null) {
      if (there.key == entry.key && there.coveredSeconds > covered) {
        return false;
      }
    } else if (_besideExists(videoPath) && !_coversWhole(entry)) {
      // files this version cannot read (another format: the app was
      // updated, and opening the video dropped the cache entry) are not
      // replaced by the little made since, until it is the whole media
      return false;
    }
    await _replace(srtPath(videoPath), displayed(entry).toSrt());
    await _replace(entryPath(videoPath), jsonEncode(entry.toJson()));
    return true;
  }

  /// The entry kept beside the video at [videoPath], when it is [key]'s and
  /// [recogniser]'s, of this app's format, and has a transcript.
  static Future<SubtitleCacheEntry?> read(
    String videoPath,
    SubtitleCacheKey key,
    String recogniser,
  ) async {
    final entry = await _read(videoPath);
    if (entry == null ||
        entry.key != key ||
        entry.recogniser != recogniser ||
        entry.runs.isEmpty) {
      return null;
    }
    return entry;
  }

  static Future<SubtitleCacheEntry?> _read(String videoPath) async {
    final file = File(entryPath(videoPath));
    try {
      if (!file.existsSync()) return null;
      return SubtitleCacheEntry.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  /// Whether a transcript file is beside the video at [videoPath].
  static bool _besideExists(String videoPath) {
    try {
      return File(entryPath(videoPath)).existsSync() ||
          File(srtPath(videoPath)).existsSync();
    } catch (_) {
      return true;
    }
  }

  /// Whether [entry] covers the whole media, as a session finds it done
  /// (isCoveredWhole): only then is it sure to have all the files had.
  static bool _coversWhole(SubtitleCacheEntry entry) {
    final end = entry.mediaEnd;
    if (end == null) return false;
    final store = TranscriptStore()..restore(entry.runs);
    return isCoveredWhole(store.covered, end);
  }

  static var _serial = 0;

  /// Scratch files of [target] an earlier write left (the app ended before
  /// the rename): the writes of one video go one at a time, so none is in
  /// use.
  static void _dropScratch(String target) {
    final prefix = '${path.basename(target)}.';
    try {
      for (final f in Directory(path.dirname(target)).listSync()) {
        final name = path.basename(f.path);
        if (f is File && name.startsWith(prefix) && name.endsWith('.tmp')) {
          f.deleteSync();
        }
      }
    } catch (_) {}
  }

  /// [text] at [target], through a scratch file renamed over it: a player
  /// reading the folder never finds half a file.
  static Future<void> _replace(String target, String text) async {
    _dropScratch(target);
    final scratch = File('$target.${pid}_${_serial++}.tmp');
    try {
      await scratch.writeAsString(text, flush: true);
      await scratch.rename(target);
    } catch (e) {
      if (kDebugMode) debugPrint('transcript files: $target: $e');
      try {
        if (scratch.existsSync()) await scratch.delete();
      } catch (_) {}
    }
  }
}
