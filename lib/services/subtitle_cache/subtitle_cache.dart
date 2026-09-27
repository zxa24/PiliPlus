/// LibrePili: what on-device transcription and translation made, kept on
/// disk so it is never made twice (research/subtitle-switch-design-
/// 2026-09-26.md, 9B).
///
/// One entry per video part and recogniser: the transcript as its runs
/// left it — each segment with its time, language, weight and cues, and
/// how far each run got — and, beside it, the translations made of it, one
/// set per target language and translation model, kept the way a
/// translation session keeps them (by where a unit starts, with the text it
/// was made from). A session starting on a part with an entry is handed the
/// transcript first: what is known counts as known, and only the gaps are
/// transcribed; a translation takes what was translated of the same text.
///
/// Where: the app's cache directory (`tmpDirPath`), not beside the models in
/// the data directory — this is a cache, and the system may clear it. It is
/// bounded by the 字幕缓存上限 setting (0.5 GB unless changed): past it, the
/// entries used longest ago go. NewPipe and PipePipe keep their caches the
/// same way, in the cache directory and bounded.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/transcript_seams.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/translate/translation_layout.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

/// Which video part an entry is for.
///
/// A bilibili part is its cid, which is unique across the whole site: the
/// bvid adds nothing, and leaving it out lets a downloaded copy share the
/// entry of the video it was downloaded from (a download record keeps the
/// cid). A YouTube video is one part. A local file with no record is its
/// location and size.
@immutable
class SubtitleCacheKey {
  const SubtitleCacheKey._(this.id);

  factory SubtitleCacheKey.bilibili(int cid) => SubtitleCacheKey._('bili:$cid');

  factory SubtitleCacheKey.youtube(String videoId) =>
      SubtitleCacheKey._('yt:$videoId');

  /// [location] a path or a `content://` URI; [size] its length in bytes,
  /// read from the file when not given (a URI has none to read).
  factory SubtitleCacheKey.local(String location, {int? size}) {
    var bytes = size;
    if (bytes == null || bytes <= 0) {
      try {
        bytes = File(location).lengthSync();
      } catch (_) {
        bytes = 0;
      }
    }
    final where = location.startsWith('content://')
        ? location
        : path.normalize(path.absolute(location));
    return SubtitleCacheKey._('file:$where#$bytes');
  }

  /// `platform:part`, e.g. `bili:123456`, `yt:dQw4w9WgXcQ`.
  final String id;

  @override
  bool operator ==(Object other) => other is SubtitleCacheKey && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => id;
}

/// What produced a transcript: the recogniser's models, and the language it
/// was forced to, if it was. Another recogniser's text is another entry.
String subtitleRecogniserId({
  required String model,
  required String vad,
  String language = '',
}) => '$model+$vad${language.isEmpty ? '' : '@$language'}';

/// The translations of one entry kept under this: the language made into
/// and the model that made them.
String subtitleTranslationKey(String target, String model) => '$target|$model';

/// One entry, as it is in memory. Shared by the transcription and the
/// translation of the same part, each updating its own half.
class SubtitleCacheEntry {
  SubtitleCacheEntry(this.key, this.recogniser);

  final SubtitleCacheKey key;
  final String recogniser;

  /// The transcript's runs (see [TranscriptStore.restore]).
  List<RestoredRun> runs = const [];

  /// Where the media's audio ends, when a run found it.
  double? mediaEnd;

  /// Translations by [subtitleTranslationKey].
  final translations = <String, TranslationResults>{};

  /// The file name it is kept under.
  String get name => subtitleCacheFileName(key, recogniser);

  /// The cache it was opened from, which [save] writes it to.
  SubtitleCache? _store;

  /// Writes it to the cache it came from, as it is now (see
  /// [SubtitleCache.save]).
  Future<void> save() => _store?.save(this) ?? Future.value();

  bool get isEmpty =>
      runs.isEmpty && translations.values.every((t) => t.isEmpty);

  /// Seconds of media the transcript covers.
  double get coveredSeconds {
    final store = TranscriptStore()..restore(runs);
    return store.covered.fold(0.0, (sum, s) => sum + (s.to - s.from));
  }

  /// Takes the transcript from [store] as it stands. A run that has nothing
  /// — no segment, no stretch — is left out.
  void captureTranscript(TranscriptStore store, {double? mediaEnd}) {
    final kept = <RestoredRun>[];
    for (final run in store.runs) {
      if (run.segments.isEmpty && run.end <= run.start) continue;
      final counts = run.cueCounts;
      final segments = <SeamSegment>[];
      var at = 0;
      for (var i = 0; i < run.segments.length; i++) {
        final s = run.segments[i];
        final n = counts[i];
        segments.add((
          start: s.start,
          duration: s.duration,
          cues: List<AsrCue>.unmodifiable(run.cues.sublist(at, at + n)),
          language: s.language,
          weight: s.weight,
        ));
        at += n;
      }
      kept.add((start: run.start, end: run.end, segments: segments));
    }
    runs = kept;
    if (mediaEnd != null) this.mediaEnd = mediaEnd;
  }

  /// The translations kept under [key], for a translation session to start
  /// with. A copy: the session adds to its own.
  TranslationResults translationsFor(String key) => {...?translations[key]};

  /// Keeps [results] under [key]: those with a translation (a failure is
  /// not kept — it may work next time), and only where [units] (unit key →
  /// source text, as the session last cut them) does not say the text has
  /// changed since.
  void captureTranslations(
    String key,
    TranslationResults results,
    Map<int, String> units,
  ) {
    translations[key] = {
      for (final e in results.entries)
        if (e.value.text != null &&
            (units[e.key] == null || units[e.key] == e.value.source))
          e.key: e.value,
    };
  }

  Map<String, Object?> toJson() => {
    'format': SubtitleCache.format,
    'key': key.id,
    'recogniser': recogniser,
    'mediaEnd': mediaEnd,
    'runs': [
      for (final run in runs)
        {
          'start': run.start,
          'end': run.end,
          'segments': [
            for (final s in run.segments)
              {
                'start': s.start,
                'duration': s.duration,
                'language': s.language,
                'weight': s.weight,
                'cues': [
                  for (final c in s.cues) [c.from, c.to, c.content],
                ],
              },
          ],
        },
    ],
    'translations': {
      for (final t in translations.entries)
        t.key: {
          for (final r in t.value.entries)
            '${r.key}': {
              'source': r.value.source,
              'text': r.value.text,
              if (r.value.passed) 'passed': true,
            },
        },
    },
  };

  /// Null when [json] is not an entry of this [SubtitleCache.format].
  static SubtitleCacheEntry? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    if (json['format'] != SubtitleCache.format) return null;
    try {
      final entry =
          SubtitleCacheEntry(
              SubtitleCacheKey._(json['key']! as String),
              json['recogniser']! as String,
            )
            ..mediaEnd = (json['mediaEnd'] as num?)?.toDouble()
            ..runs = [
              for (final run in json['runs']! as List)
                (
                  start: ((run as Map)['start'] as num).toDouble(),
                  end: (run['end'] as num).toDouble(),
                  segments: [
                    for (final s in run['segments'] as List)
                      (
                        start: ((s as Map)['start'] as num).toDouble(),
                        duration: (s['duration'] as num).toDouble(),
                        language: s['language'] as String,
                        weight: s['weight'] as int,
                        cues: List<AsrCue>.unmodifiable([
                          for (final c in s['cues'] as List)
                            AsrCue(
                              from: ((c as List)[0] as num).toDouble(),
                              to: (c[1] as num).toDouble(),
                              content: c[2] as String,
                            ),
                        ]),
                      ),
                  ],
                ),
            ];
      for (final t in (json['translations']! as Map).entries) {
        entry.translations[t.key as String] = {
          for (final r in (t.value as Map).entries)
            int.parse(r.key as String): (
              source: (r.value as Map)['source'] as String,
              text: r.value['text'] as String?,
              passed: r.value['passed'] == true,
            ),
        };
      }
      return entry;
    } catch (_) {
      return null;
    }
  }
}

/// The name an entry's file has: a hash of what it is for, which may hold
/// any character a path cannot.
String subtitleCacheFileName(SubtitleCacheKey key, String recogniser) =>
    '${sha1.convert(utf8.encode('${key.id}\n$recogniser'))}.json';

/// The entries on disk.
class SubtitleCache {
  SubtitleCache(this.dir, {int Function()? limitBytes})
    : _limitBytes = limitBytes ?? (() => Pref.subtitleCacheLimitMb << 20);

  /// The app's: in its cache directory, which a self-test profile has its
  /// own of (see appTempDirectory).
  static SubtitleCache get instance =>
      _instance ??= SubtitleCache(Directory(path.join(tmpDirPath, dirName)));
  static SubtitleCache? _instance;

  @visibleForTesting
  static set debugInstance(SubtitleCache? cache) => _instance = cache;

  static const dirName = 'subtitle_cache';

  /// The layout of an entry. An entry of another is not read — it is
  /// deleted — so a change to what is kept, or to how cues are made from
  /// what the recogniser says, bumps this.
  ///
  /// 2: segments cut after 1 s of silence rather than 0.5 s, and decoded
  /// with padding (SpeechPadding) — a transcript kept from before is cut
  /// differently and recognised worse.
  static const format = 2;

  final Directory dir;
  final int Function() _limitBytes;

  /// Entries read or written this run, by file name: the transcription and
  /// the translation of one part share one, and a session started again
  /// reads what the last one kept even while it is still being written.
  final _entries = <String, SubtitleCacheEntry>{};

  /// The files, by name: size and last use. Built by the first scan.
  Map<String, ({int size, DateTime used})>? _index;
  Future<void>? _scanning;

  /// Writes, one after another per file.
  final _writes = <String, Future<void>>{};
  var _tmpSerial = 0;

  /// Bytes the entries take, once known.
  int? get usage => _index?.values.fold<int>(0, (sum, e) => sum + e.size);

  Future<Map<String, ({int size, DateTime used})>> _indexed() async {
    final index = _index;
    if (index != null) return index;
    await (_scanning ??= _scan());
    return _index!;
  }

  Future<void> _scan() async {
    final index = <String, ({int size, DateTime used})>{};
    try {
      if (dir.existsSync()) {
        final now = DateTime.now();
        await for (final item in dir.list()) {
          if (item is! File) continue;
          final name = path.basename(item.path);
          final stat = item.statSync();
          if (name.endsWith('.json')) {
            index[name] = (size: stat.size, used: stat.modified);
          } else if (name.endsWith('.tmp') &&
              now.difference(stat.modified) > const Duration(minutes: 10)) {
            // a write cut short by the app ending
            await _delete(item);
          }
        }
      }
    } catch (_) {}
    _index = index;
  }

  /// The entry for [key] made by [recogniser]: the one in memory, the one
  /// on disk, or a new empty one. Reading one counts as using it.
  Future<SubtitleCacheEntry> open(
    SubtitleCacheKey key,
    String recogniser,
  ) async {
    final name = subtitleCacheFileName(key, recogniser);
    final held = _entries[name];
    if (held != null) {
      unawaited(_touch(name));
      return held.._store = this;
    }
    final index = await _indexed();
    // a write under way ends first
    await _writes[name];
    final again = _entries[name];
    if (again != null) return again;
    var entry = SubtitleCacheEntry(key, recogniser);
    final file = File(path.join(dir.path, name));
    if (index.containsKey(name)) {
      SubtitleCacheEntry? read;
      try {
        read = SubtitleCacheEntry.fromJson(
          jsonDecode(await file.readAsString()),
        );
      } catch (_) {}
      if (read == null) {
        // unreadable, or of another format: of no use to anyone
        index.remove(name);
        await _delete(file);
      } else if (read.key == key && read.recogniser == recogniser) {
        entry = read;
        await _touch(name);
      }
    }
    return (_entries[name] ??= entry).._store = this;
  }

  Future<void> _touch(String name) async {
    final now = DateTime.now();
    final index = _index;
    final known = index?[name];
    if (index == null || known == null) return;
    index[name] = (size: known.size, used: now);
    try {
      await File(path.join(dir.path, name)).setLastModified(now);
    } catch (_) {}
  }

  /// Writes [entry] as it is now — taken at once, written in the
  /// background after any earlier write of it — to a scratch file first,
  /// renamed over the old one, so a reader never finds half an entry. Then
  /// the least recently used entries go until all fit in the limit.
  Future<void> save(SubtitleCacheEntry entry) {
    final name = entry.name;
    _entries[name] = entry;
    entry._store = this;
    if (entry.isEmpty) return _writes[name] ?? Future.value();
    final text = jsonEncode(entry.toJson());
    final write = (_writes[name] ?? Future.value()).then(
      (_) => _write(name, text),
    );
    _writes[name] = write;
    unawaited(
      write.whenComplete(() {
        if (identical(_writes[name], write)) _writes.remove(name);
      }),
    );
    return write;
  }

  Future<void> _write(String name, String text) async {
    try {
      final index = await _indexed();
      await dir.create(recursive: true);
      final target = File(path.join(dir.path, name));
      final scratch = File('${target.path}.${pid}_${_tmpSerial++}.tmp');
      await scratch.writeAsString(text, flush: true);
      await scratch.rename(target.path);
      final stat = target.statSync();
      index[name] = (size: stat.size, used: stat.modified);
      await evict(keep: name);
    } catch (e) {
      if (kDebugMode) debugPrint('subtitle cache: write failed: $e');
    }
  }

  /// Deletes the least recently used entries until the rest fit in the
  /// limit; never [keep] (the one just written).
  Future<void> evict({String? keep}) async {
    final index = await _indexed();
    final limit = _limitBytes();
    var total = index.values.fold<int>(0, (sum, e) => sum + e.size);
    if (total <= limit) return;
    final oldest = index.entries.toList()
      ..sort((a, b) => a.value.used.compareTo(b.value.used));
    for (final e in oldest) {
      if (total <= limit) break;
      if (e.key == keep) continue;
      await _writes[e.key];
      index.remove(e.key);
      _entries.remove(e.key);
      total -= e.value.size;
      await _delete(File(path.join(dir.path, e.key)));
    }
  }

  /// Deletes every entry (清除字幕缓存, 重置所有数据). A session still going
  /// writes its own again when it next saves.
  Future<void> clear() async {
    final index = await _indexed();
    await Future.wait(_writes.values.toList());
    _entries.clear();
    index.clear();
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Until every write asked for so far has reached the disk: before the
  /// app ends, which does not wait for anything.
  Future<void> flush() => Future.wait(_writes.values.toList());

  /// Bytes the entries take, scanning the directory if not yet known.
  Future<int> measure() async {
    await _indexed();
    return usage ?? 0;
  }

  static Future<void> _delete(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }
}
