/// LibrePili: what a YouTube download saves beside its video
/// (feature-logs/download-platforms design §6, stage 4): `librepili.json`
/// (the record), `cover.jpg`, `<base>.intro.json`
/// (`librepili-yt-intro-1`), the subtitles as `<base>.<lang>.srt` /
/// `<base>.<lang>.<n>.srt` / `<base>.<lang>.auto.srt` with the on-device
/// transcript `<base>.asr.srt`, and `<base>.comments.json`
/// (`librepili-yt-comments-1`) with the avatars in `comments_images/`.
///
/// Every step is best-effort and on its own: one that fails records
/// `error: …` and the next one runs (as bilibili's, download_extras.dart).
/// Requests go through the YouTube sources or a bare [HttpClient] with
/// every hop checked ([YtCheckedHops]), never the app's Dio.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:PiliPlus/models/common/subtitle_source.dart';
import 'package:PiliPlus/models_new/download/yt_download_entry.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_files.dart';
import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:PiliPlus/services/download/download_progress.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/services/youtube/direct_source.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/services/youtube/stream_relay.dart';
import 'package:PiliPlus/services/youtube/video_source.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:PiliPlus/utils/atomic_text_file.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/subtitle_utils.dart';
import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

/// What the extras ask the network for. The live one is [YtExtrasLiveNet];
/// a test gives its own.
abstract class YtExtrasNet {
  /// The video's details (title, description, caption tracks), and the
  /// source that answered (its captions are asked of the same one).
  Future<YtRoutedResult<YtVideoDetail>> detail(String videoId);

  /// One caption track's text (WebVTT), from [source].
  Future<YtResult<String>> captionContent(
    YouTubeVideoSource? source,
    YtCaptionTrack track,
  );

  /// The `next` answer: the publish date, the channel's avatar and
  /// subscribers, and the comments' first token (design §6.2 p3#12).
  Future<YtResult<YtRelatedAndComments>> related(String videoId);

  /// One page of comments, or of a thread's replies.
  Future<YtResult<YtPage<YtComment>>> comments(String token);

  /// [uri]'s bytes, at most [maxBytes]; throws when it fails, is over
  /// the cap or goes 30 s without data.
  Future<List<int>> image(Uri uri, {required int maxBytes});

  /// The pause between comment requests.
  Future<void> pause(Duration duration);

  /// Whether [detail] may ask the direct source (not when its router goes
  /// to the fallback alone): the gap between exports comes before it then
  /// (review 2, P3).
  bool get detailAsksDirect;

  void close();
}

abstract final class YtExtras {
  static const introSuffix = DownloadExtras.introSuffix;
  static const commentsSuffix = DownloadExtras.commentsSuffix;
  static const introFormat = 'librepili-yt-intro-1';
  static const commentsFormat = 'librepili-yt-comments-1';

  /// Reply answers in a row that are not ok before the replies stop.
  static const maxReplyFailures = 3;

  /// How many times the comments a wall kept out are asked for again
  /// before they are given up (review 2, item 5).
  static const commentRetries = 3;

  /// At most this many subtitle tracks (§10-1).
  static const maxTracks = 10;

  /// An avatar's (or the intro's channel face's) byte cap (§6.4).
  static const imageMaxBytes = 64 * 1024;

  /// Between comment pages and between reply requests (design §6.3). 1 s,
  /// not the design's 200 ms: §9 probe 4 met no wall at 200 ms, but the
  /// IP was walled 11 min after a real download's 224 comment requests at
  /// 200 ms (report 2026-11-17), and the brief's rule for a wall is 1 s.
  /// The self test's `--comment-gap-ms` changes it.
  static Duration commentGap = const Duration(seconds: 1);

  /// Between two exports' traffic to the direct source (their `next`
  /// requests, and the details when they go there, review 2 P3): the
  /// backlog of a first launch (every stage-2 record at once) is spread out
  /// (review 1, l9; the 30 s is the user's, 2026-11-17).
  static Duration exportGap = const Duration(seconds: 30);

  /// An avatar's (or the intro's face's) whole fetch, redirects included
  /// (review 1, l10; as the cover's `coverDeadline`).
  static Duration imageDeadline = const Duration(seconds: 60);

  /// How often a running export looks at its `cancelled`: once it is true
  /// the export's network is closed, which ends what is in flight.
  static Duration cancelPoll = const Duration(milliseconds: 250);

  /// The comments' health, one table for every export of this app session
  /// (review 1, l9): a wall one export met holds for the next ones until it
  /// cools. Never the pages' [YtSourceRouter.sharedHealth].
  static final commentsHealth = <String, YtSourceHealth>{};

  /// When the last export's traffic to the direct source ended
  /// ([exportGap]).
  static DateTime? _lastDirectTraffic;

  /// Tests only: in place of [DateTime.now].
  static DateTime Function() clock = DateTime.now;

  /// Tests only: an app session's state forgotten.
  @visibleForTesting
  static void resetSessionForTest() {
    commentsHealth.clear();
    _lastDirectTraffic = null;
    clock = DateTime.now;
  }

  /// The direct source's known wall, as the reason to give; null: none.
  /// The pages' cooldown is read, never changed (review 1, l6); a wall the
  /// comments met this session holds too (l9).
  static String? directWall() {
    final now = clock();
    for (final (table, whose) in [
      (YtSourceRouter.sharedHealth, 'the pages'),
      (commentsHealth, 'the comments'),
    ]) {
      final until = table[_directId]?.cooldownUntil;
      if (until != null && now.isBefore(until)) {
        return 'direct source cooling down until '
            '${until.toIso8601String()} ($whose)';
      }
    }
    return null;
  }

  /// Until when the direct source's known wall lasts (the later of the
  /// two tables' cooldowns); null: none now.
  static DateTime? directWallUntil() {
    final now = clock();
    DateTime? out;
    for (final table in [YtSourceRouter.sharedHealth, commentsHealth]) {
      final until = table[_directId]?.cooldownUntil;
      if (until != null &&
          now.isBefore(until) &&
          (out == null || until.isAfter(out))) {
        out = until;
      }
    }
    return out;
  }

  static const _directId = 'direct';

  /// A wall the comments met: a cooldown in [commentsHealth] on the
  /// router's ladder, so the session's next exports leave it alone. One the
  /// router already started for it (a confirmed wall) is kept as it is:
  /// not a second step up the ladder (review 2, P4).
  static void _noteWall() {
    final h = commentsHealth.putIfAbsent(_directId, YtSourceHealth.new);
    if (h.cooldownUntil case final until? when clock().isBefore(until)) {
      return;
    }
    final step = math.min(h.cooldownStep, ytCooldownLadder.length - 1);
    h
      ..cooldownUntil = clock().add(ytCooldownLadder[step])
      ..cooldownStep = h.cooldownStep + 1;
  }

  /// Self tests only: told of every request the extras make.
  static void Function(String kind, YtVerdict verdict, Duration took)?
  onRequestForTest;

  /// Self tests only: told what an export wrote, as it ends.
  static void Function(String key, Map<String, Object?> written)?
  onWrittenForTest;

  /// The comment steps alone: the plan of [exportComments].
  static Map<String, int> commentsPlan() => {
    // their own steps: their first estimate is the 1 s pacing's (l12)
    if (Pref.dlSaveComments) ...{
      DownloadProgress.stepYtCommentList:
          (Pref.dlCommentCount / DownloadProgress.commentsPerPage).ceil(),
      DownloadProgress.stepYtComments: Pref.dlCommentCount,
    },
  };

  /// The step names, as bilibili's ([DownloadProgress]).
  static Map<String, int> plan() => DownloadProgress.extrasPlan(
    intro: true,
    cover: Pref.dlSaveCover,
    // danmaku and the preview sheet: not a YouTube download's (§6, user
    // 2026-11-16 「2A」)
    danmaku: false,
    subtitles: Pref.dlSaveSubtitle,
    comments: 0,
  )..addAll(commentsPlan());

  /// Writes the enabled extras of [entry] beside its export; returns what
  /// was written (for self tests). [cancelled] is looked at before every
  /// request and every [cancelPoll]: once true (the entry was deleted) [net]
  /// is closed, which ends what is in flight, and nothing more is fetched
  /// or written.
  static Future<Map<String, Object?>> export({
    required YtDownloadEntry entry,
    required String folder,
    required String base,
    required YtExtrasNet net,
    required SubtitleCacheKey transcriptKey,
    bool Function()? cancelled,
    DownloadProgress? progress,
  }) async {
    final written = <String, Object?>{};
    void check() {
      if (cancelled?.call() ?? false) throw const YtExtrasCancelled();
    }

    final watch = cancelled == null
        ? null
        : Timer.periodic(cancelPoll, (_) {
            if (cancelled()) net.close();
          });

    try {
      // the folder is the user's shareable copy: this device's paths left
      // out (as bilibili's, download_extras.dart)
      final info = entry.toJson()
        ..remove('merged_path')
        ..remove('merged_parts')
        ..remove('extras_pending')
        ..remove('transcript_pending')
        // this device's bookkeeping (review 2, item 5)
        ..remove('comments_pending')
        ..remove('comments_tries')
        ..remove('comments_after')
        ..remove('comments_note');
      await writeTextAtomic(
        File(path.join(folder, DownloadExtras.infoName)),
        const JsonEncoder.withIndent(' ').convert(info),
      );
    } catch (_) {}

    Future<void> step(
      String name,
      Future<Object?> Function() body, {
      String? shown,
    }) async {
      if (cancelled?.call() ?? false) return;
      progress?.extrasStart(shown ?? name);
      try {
        written[name] = await body();
      } catch (e) {
        written[name] = 'error: $e';
        if (kDebugMode) debugPrint('youtube extras $name: $e');
      } finally {
        progress?.extrasDone(shown ?? name);
      }
    }

    final calls = _Calls(net, check);
    YtCommentsUnavailable? unavailable;
    try {
      // always: small, and without it the offline page has no intro
      await step(
        DownloadProgress.stepIntro,
        () => _intro(entry, folder, base, calls),
      );
      if (Pref.dlSaveCover) {
        await step(DownloadProgress.stepCover, () async {
          final src = File(path.join(entry.entryDirPath, PathUtils.coverName));
          if (!src.existsSync()) return null;
          await src.copy(path.join(folder, DownloadExtras.coverName));
          return DownloadExtras.coverName;
        });
      }
      if (Pref.dlSaveSubtitle) {
        await step(
          DownloadProgress.stepSubtitles,
          () => _subtitles(entry, folder, base, calls, progress, transcriptKey),
        );
      }
      if (Pref.dlSaveComments) {
        await step(
          DownloadProgress.stepComments,
          () async {
            try {
              return await _comments(
                entry,
                folder,
                base,
                calls,
                cancelled,
                progress,
              );
            } on YtCommentsUnavailable catch (e) {
              unavailable = e;
              rethrow;
            }
          },
          shown: DownloadProgress.stepYtComments,
        );
      }
    } finally {
      watch?.cancel();
      if (calls.directAsked) _lastDirectTraffic = clock();
      net.close();
    }
    if (!(cancelled?.call() ?? false)) {
      // a wall kept them out: asked for again later; anything else (saved,
      // not for another reason, not wanted): nothing to ask (item 5)
      if (Pref.dlSaveComments && (unavailable?.walled ?? false)) {
        entry
          ..commentsPending = true
          ..commentsTries = 0
          ..commentsAfter = _retryAt(0)
          ..commentsNote = unavailable!.why;
      } else {
        _doneWithComments(entry, null);
      }
    }
    EventLog.add(
      'download',
      '${entry.logLabel}: extras ${calls.count} requests in '
          '${calls.clock.elapsed.inSeconds} s: '
          '${written.entries.map((e) => '${e.key}=${_short(e.value)}').join('; ')}',
    );
    onWrittenForTest?.call(entry.key, written);
    return written;
  }

  /// When comments a wall kept out are asked for again after [tries]
  /// tries: the cooldown ladder's step, or the wall's end when later.
  static DateTime _retryAt(int tries) {
    final at = clock().add(
      ytCooldownLadder[math.min(tries, ytCooldownLadder.length - 1)],
    );
    final wall = directWallUntil();
    return wall != null && wall.isAfter(at) ? wall : at;
  }

  /// Nothing more to ask for [entry]'s comments; [note]: why, when they
  /// were given up.
  static void _doneWithComments(YtDownloadEntry entry, String? note) {
    entry
      ..commentsPending = false
      ..commentsTries = 0
      ..commentsAfter = null
      ..commentsNote = note;
  }

  /// [entry]'s comments asked for again, nothing else written (review 2,
  /// item 5: a wall kept them out of its extras), with an export's pacing
  /// and gap; its retry state updated. Saved: nothing more to ask. The
  /// direct source still walled: asked for once the wall ends, not
  /// counted. Not saved: asked for again on the cooldown ladder, at most
  /// [commentRetries] times, then given up with the reason
  /// ([YtDownloadEntry.commentsNote]).
  static Future<Map<String, Object?>> exportComments({
    required YtDownloadEntry entry,
    required String folder,
    required String base,
    required YtExtrasNet net,
    bool Function()? cancelled,
    DownloadProgress? progress,
  }) async {
    final written = <String, Object?>{};
    final video = entry.mergedPath;
    final giveUp = !Pref.dlSaveComments
        ? 'comments are switched off'
        : video == null || !File(video).existsSync()
        ? 'the video is gone'
        : null;
    if (giveUp != null) {
      net.close();
      _doneWithComments(entry, 'not asked again: $giveUp');
      return written..['comments'] = 'not asked: $giveUp';
    }
    void check() {
      if (cancelled?.call() ?? false) throw const YtExtrasCancelled();
    }

    final watch = cancelled == null
        ? null
        : Timer.periodic(cancelPoll, (_) {
            if (cancelled()) net.close();
          });
    final calls = _Calls(net, check);
    YtCommentsUnavailable? unavailable;
    try {
      if (!(cancelled?.call() ?? false)) {
        progress?.extrasStart(DownloadProgress.stepYtComments);
        try {
          written['comments'] = await _comments(
            entry,
            folder,
            base,
            calls,
            cancelled,
            progress,
          );
        } catch (e) {
          written['comments'] = 'error: $e';
          if (e is YtCommentsUnavailable) unavailable = e;
        } finally {
          progress?.extrasDone(DownloadProgress.stepYtComments);
        }
      }
    } finally {
      watch?.cancel();
      if (calls.directAsked) _lastDirectTraffic = clock();
      net.close();
    }
    if (cancelled?.call() ?? false) return written;
    final result = written['comments'];
    if (result is String && !result.startsWith('error:')) {
      _doneWithComments(entry, null);
    } else if (unavailable case final u? when u.skipped) {
      // not asked: still walled
      entry
        ..commentsAfter = _retryAt(entry.commentsTries)
        ..commentsNote = u.why;
    } else {
      final why = unavailable?.why ?? '$result';
      final tries = entry.commentsTries + 1;
      if (tries >= commentRetries) {
        _doneWithComments(entry, 'given up after $tries tries: $why');
      } else {
        entry
          ..commentsTries = tries
          ..commentsAfter = _retryAt(tries)
          ..commentsNote = why;
      }
    }
    EventLog.add(
      'download',
      '${entry.logLabel}: comments asked again, ${calls.count} requests: '
          '${_short(result)}'
          '${entry.commentsPending ? '; again after ${entry.commentsAfter}' : entry.commentsNote == null ? '' : '; ${entry.commentsNote}'}',
    );
    onWrittenForTest?.call(entry.key, written);
    return written;
  }

  static String _short(Object? v) {
    final s = v is List ? '${v.length} files' : '$v';
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  // ------------------------------------------------------------ the intro

  static Future<String> _intro(
    YtDownloadEntry entry,
    String folder,
    String base,
    _Calls calls,
  ) async {
    final detail = await calls.detail(entry.videoId);
    final related = await calls.related(entry.videoId);
    if (related.verdict.cause == YtCause.ipBlocked) _noteWall();
    final d = detail.ok ? detail.value : null;
    final extra = related.ok ? related.value!.extra : null;
    final faces = <String, String>{};
    final avatar = extra?.ownerAvatar?.url;
    if (avatar != null && avatar.isNotEmpty) {
      final url = smallAvatar(avatar);
      final uri = Uri.tryParse(url);
      if (uri != null && isImageHost(uri)) {
        try {
          calls.check();
          faces[avatar] = base64Encode(
            await calls.net.image(uri, maxBytes: imageMaxBytes),
          );
        } on YtExtrasCancelled {
          rethrow;
        } catch (e) {
          if (kDebugMode) debugPrint('youtube extras face: $e');
        }
      }
    }
    calls.check();
    await writeTextAtomic(
      File(path.join(folder, '$base$introSuffix')),
      const JsonEncoder.withIndent(' ').convert({
        'format': introFormat,
        'fetchedAt': DateTime.now().toIso8601String(),
        'videoId': entry.videoId,
        'title': d?.title ?? entry.title,
        'channel': d?.author ?? entry.channel,
        'channelId': d?.channelId ?? entry.channelId,
        'durationSeconds': d?.duration.inSeconds ?? entry.durationMs ~/ 1000,
        'description': ?d?.description,
        'viewCount': ?d?.viewCount,
        'viewCountText': ?extra?.viewCountText,
        'published': ?extra?.dateText,
        'publishedRelative': ?extra?.relativeDateText,
        'subscriberText': ?extra?.subscriberText,
        'channelAvatar': ?avatar,
        'faces': faces,
        // likes and tags: none of the sources' answers the app reads carry
        // them (design §6.2 「有则存」)
      }),
    );
    return [
      '${faces.length} faces',
      if (d == null) 'no detail (${detail.verdict})',
      if (extra == null) 'no extra (${related.verdict})',
    ].join(', ');
  }

  // ------------------------------------------------------------ subtitles

  static Future<Map<String, Object?>> _subtitles(
    YtDownloadEntry entry,
    String folder,
    String base,
    _Calls calls,
    DownloadProgress? progress,
    SubtitleCacheKey transcriptKey,
  ) async {
    final files = <String>[];
    final failed = <String>[];
    final detail = await calls.detail(entry.videoId);
    final picked = detail.ok
        ? pickTracks(detail.value!.captionTracks, base)
        : const <({YtCaptionTrack track, String name})>[];
    if (!detail.ok) failed.add('captions: no detail (${detail.verdict})');
    // a picked track is written only where no file of its name is: a
    // subtitle file is never written over and never deleted, whoever wrote
    // it (review 3). A run again after one cut off can leave the earlier
    // pick's other tracks beside this pick's: subtitles of the same video
    for (final (i, p) in picked.indexed) {
      progress?.extras(DownloadProgress.stepSubtitles, 1 + i, 1 + picked.length);
      final file = File(path.join(folder, p.name));
      if (file.existsSync()) {
        files.add(p.name);
        continue;
      }
      final r = await calls.caption(detail.source, p.track);
      final srt = r.ok ? vttToSrt(r.value!) : null;
      if (srt == null) {
        failed.add('${p.name}: ${r.ok ? 'no cues' : r.verdict}');
        continue;
      }
      calls.check();
      try {
        // false: a file of that name came meanwhile, and stays
        await writeTextAtomic(file, srt, replace: false);
      } catch (e) {
        failed.add('${p.name}: $e');
        if (file.existsSync()) files.add(p.name);
        continue;
      }
      files.add(p.name);
    }
    // what the device transcribed of the video, written beside it (as
    // bilibili's: what it transcribes later is written as the cache keeps
    // it)
    try {
      final video = entry.mergedPath ?? path.join(folder, '$base.mp4');
      final kept = await SubtitleCache.instance.open(
        transcriptKey,
        AsrService.recogniserId,
      );
      if (await TranscriptFiles.write(kept, video)) {
        files.add('$base${TranscriptFiles.srtSuffix}');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('youtube extras transcript: $e');
    }
    return {'files': files, if (failed.isNotEmpty) 'failed': failed};
  }

  /// WebVTT as SRT; null when it has no cues.
  static String? vttToSrt(String vtt) {
    final cues = SubtitleUtils.vtt2Json(vtt);
    return cues.isEmpty ? null : SubtitleUtils.json2Srt(cues);
  }

  /// The primary subtag of a language code: `en-GB` → `en` (user
  /// 2026-11-16 「1B」: a regional variant counts as its language).
  static String primary(String code) => code.split('-').first.toLowerCase();

  /// The tracks a download keeps and their file names (design §6.2,
  /// §10-1): the original language's own tracks, then Chinese ones, then
  /// the original language's automatic track, then the others in the
  /// order listed; at most [maxTracks]. The original language is the
  /// automatic track's (YouTube makes it from the video's speech; nothing
  /// else in the answers names it): with no automatic track there is none,
  /// and the order starts at the Chinese tracks.
  static List<({YtCaptionTrack track, String name})> pickTracks(
    List<YtCaptionTrack> tracks,
    String base,
  ) {
    final auto = tracks.where((t) => t.isAutomatic).firstOrNull;
    final original = auto == null ? null : primary(auto.languageCode);
    final authored = tracks.where((t) => !t.isAutomatic).toList();
    final kept = LinkedHashSet<YtCaptionTrack>.identity()
      ..addAll(authored.where((t) => primary(t.languageCode) == original))
      ..addAll(authored.where((t) => primary(t.languageCode) == 'zh'));
    if (auto != null) kept.add(auto);
    kept.addAll(authored);
    final counts = <String, int>{};
    return [
      for (final t in kept.take(maxTracks))
        (track: t, name: _fileName(t, base, counts)),
    ];
  }

  static String _fileName(
    YtCaptionTrack t,
    String base,
    Map<String, int> counts,
  ) {
    final lang = safeLang(t.languageCode);
    if (t.isAutomatic) return '$base.$lang.auto.srt';
    final n = counts[lang] = (counts[lang] ?? 0) + 1;
    return n == 1 ? '$base.$lang.srt' : '$base.$lang.$n.srt';
  }

  /// A language code as a file name's part: bilibili's cleaning, and `.`
  /// (the parts' separator) as `_` (design §6.2 「文件名」). `asr` would be
  /// the transcript's name: never one, kept apart all the same.
  static String safeLang(String code) {
    var s = code.replaceAll(RegExp(r'[\\/:*?"<>|\s.]'), '_');
    if (s.isEmpty) s = 'und';
    return s == 'asr' ? 'asr_' : s;
  }

  /// What the offline page reads back from a subtitle file's name beside
  /// `<base>.mp4` (design §6.2, §7.1): the language and who made it; null
  /// for the transcript (`<base>.asr.srt`) and for a name that is not one
  /// of these.
  static ({String lang, SubtitleSource source})? trackOfFile(
    String fileName,
    String base,
  ) {
    // `<base>.srt` has no language part (and nothing between the two)
    if (!fileName.startsWith('$base.') ||
        !fileName.endsWith('.srt') ||
        fileName.length <= base.length + 5) {
      return null;
    }
    if (fileName == '$base${TranscriptFiles.srtSuffix}') return null;
    final parts = fileName
        .substring(base.length + 1, fileName.length - 4)
        .split('.');
    if (parts.first.isEmpty || parts.length > 2) return null;
    if (parts.length == 1) {
      return (lang: parts.first, source: SubtitleSource.author);
    }
    if (parts[1] == 'auto') {
      return (lang: parts.first, source: SubtitleSource.platform);
    }
    return int.tryParse(parts[1]) == null
        ? null
        : (lang: parts.first, source: SubtitleSource.author);
  }

  // ------------------------------------------------------------- comments

  static Future<String> _comments(
    YtDownloadEntry entry,
    String folder,
    String base,
    _Calls calls,
    bool Function()? cancelled,
    DownloadProgress? progress,
  ) async {
    final maxRoots = Pref.dlCommentCount;
    final maxReplies = Pref.dlReplyCount;
    // a known wall: not asked at all (review 1, l6); asked for again once
    // it is over (review 2, item 5)
    if (directWall() case final wall?) {
      throw YtCommentsUnavailable(
        'skipped, stoppedBy: $wall',
        walled: true,
        skipped: true,
      );
    }
    final related = await calls.related(entry.videoId);
    String? token = related.ok ? related.value!.commentsToken : null;
    if (token == null) {
      throw YtCommentsUnavailable(
        related.ok ? 'no token' : '${related.verdict}',
        walled:
            !related.ok &&
            (related.verdict.cause == YtCause.ipBlocked ||
                related.verdict.signal == _Calls.directWallSignal),
      );
    }
    // a wall met stops this step; what was taken is written (§6.3)
    YtVerdict? blocked;
    final roots = <YtComment>[];
    var pages = 0;
    final pagesPlanned = (maxRoots / DownloadProgress.commentsPerPage).ceil();
    while (roots.length < maxRoots && token != null) {
      // before every request, the first page's too (review 1, l7)
      await calls.pause();
      progress?.extras(
        DownloadProgress.stepYtCommentList,
        pages,
        math.max(pagesPlanned, pages + 1),
      );
      final r = await calls.comments(token);
      if (!r.ok) {
        if (r.verdict.cause == YtCause.ipBlocked) {
          blocked = r.verdict;
          _noteWall();
        }
        // nothing came: no file, so the offline page says 「未保存评论」
        // (review 1, l1)
        if (roots.isEmpty) {
          throw YtCommentsUnavailable(
            '${r.verdict}',
            walled: r.verdict.cause == YtCause.ipBlocked,
          );
        }
        break;
      }
      pages++;
      final page = r.value!;
      roots.addAll(page.items);
      token = page.continuation;
      if (page.items.isEmpty) break;
    }
    if (roots.length > maxRoots) roots.removeRange(maxRoots, roots.length);
    progress?.extrasDone(DownloadProgress.stepYtCommentList);

    final images = YtCommentImages(folder, calls.net, cancelled: cancelled);
    final List<Map<String, Object?>> items;
    var replyCount = 0;
    // three reply answers in a row that are not ok end the replies: a
    // network gone bad is not asked 200 times more (review 1, l2)
    var replyFailures = 0;
    String? repliesStopped;
    try {
      final pending = <Future<Map<String, Object?>>>[];
      for (final (i, root) in roots.indexed) {
        calls.check();
        progress?.extras(DownloadProgress.stepYtComments, i, roots.length);
        final replies = <YtComment>[];
        var next = root.replyToken;
        while (blocked == null &&
            repliesStopped == null &&
            maxReplies > 0 &&
            next != null &&
            replies.length < maxReplies) {
          await calls.pause();
          final r = await calls.comments(next);
          if (!r.ok) {
            if (r.verdict.cause == YtCause.ipBlocked) {
              blocked = r.verdict;
              _noteWall();
            } else if (++replyFailures >= maxReplyFailures) {
              repliesStopped =
                  'replies: $replyFailures failures in a row, last ${r.verdict}';
            }
            break;
          }
          replyFailures = 0;
          replies.addAll(r.value!.items);
          next = r.value!.continuation;
          if (r.value!.items.isEmpty) break;
        }
        final kept = replies.take(maxReplies).toList();
        replyCount += kept.length;
        // its avatars are fetched while the next ones' replies are asked
        pending.add(_withReplies(root, kept, images));
      }
      items = await Future.wait(pending);
    } finally {
      // a cancelled export leaves nothing being written into the folder
      await images.settled();
    }
    final stoppedBy = blocked?.toString() ?? repliesStopped;
    calls.check();
    await writeTextAtomic(
      File(path.join(folder, '$base$commentsSuffix')),
      const JsonEncoder.withIndent(' ').convert({
        'format': commentsFormat,
        'videoId': entry.videoId,
        'title': entry.title,
        // the order the video's own first token gives (YouTube's 「Top」)
        'sort': 'top',
        'fetchedAt': DateTime.now().toIso8601String(),
        'count': items.length,
        'stoppedBy': ?stoppedBy,
        'comments': items,
      }),
    );
    if (stoppedBy != null) {
      EventLog.add(
        'download',
        '${entry.logLabel}: comments stopped by $stoppedBy after '
            '${items.length} comments',
      );
    }
    return '${items.length} comments, $replyCount replies, '
        '${images.saved} images'
        '${stoppedBy == null ? '' : ', stopped: $stoppedBy'}';
  }

  static Future<Map<String, Object?>> _withReplies(
    YtComment root,
    List<YtComment> replies,
    YtCommentImages images,
  ) async {
    final json = commentToJson(root, images);
    final saved = Future.wait([for (final r in replies) commentToJson(r, images)]);
    return (await json)..['replies'] = await saved;
  }

  /// One comment as the file keeps it (`YtComment`'s fields, design §6.2),
  /// its avatar saved by [images] (the path relative to the file).
  static Future<Map<String, Object?>> commentToJson(
    YtComment c, [
    YtCommentImages? images,
  ]) async {
    final avatar = c.authorAvatar?.url;
    final file = avatar == null || images == null
        ? null
        : await images.save(avatar);
    return {
      'id': c.commentId,
      'author': c.author,
      'authorChannelId': ?c.authorChannelId,
      'avatar': ?avatar,
      'avatarFile': ?file,
      'content': c.content,
      'likeCountText': ?c.likeCountText,
      'publishedText': ?c.publishedText,
      'replyCount': c.replyCount,
      'replyCountText': ?c.replyCountText,
      'isPinned': c.isPinned,
      'authorIsUploader': c.authorIsUploader,
    };
  }

  // --------------------------------------------------------------- images

  /// The hosts YouTube's avatars come from (§6.4).
  static bool isImageHost(Uri uri) {
    if (uri.scheme != 'https') return false;
    final h = uri.host.toLowerCase();
    bool under(String d) => h == d || h.endsWith('.$d');
    return under('ggpht.com') ||
        under('ytimg.com') ||
        under('googleusercontent.com');
  }

  static final _size = RegExp(r'=s(\d+)(?=[-?&]|$)');

  /// An avatar URL asking for at most 88 px (§6.4: the smallest size the
  /// app shows): `=s<n>` above 88 becomes `=s88`; other URLs as they are.
  static String smallAvatar(String url) => url.replaceFirstMapped(
    _size,
    (m) => int.parse(m[1]!) > 88 ? '=s88' : m[0]!,
  );
}

/// The requests one export makes, counted and told to the self test;
/// [detail] and [related] asked once and shared by the steps (§6.2 p3#12).
class _Calls {
  _Calls(this.net, this.check);

  final YtExtrasNet net;
  final void Function() check;
  final clock = Stopwatch()..start();
  var count = 0;

  /// Whether the direct source was asked (`next`, a comment page, a detail
  /// that may go there): the session's [YtExtras.exportGap] counts from
  /// this export's end then.
  var directAsked = false;

  Future<YtRoutedResult<YtVideoDetail>>? _detail;
  Future<YtResult<YtRelatedAndComments>>? _related;
  Future<void>? _gap;

  Future<T> _timed<T>(
    String kind,
    Future<T> Function() call,
    YtVerdict Function(T) verdictOf,
  ) async {
    check();
    count++;
    final watch = Stopwatch()..start();
    final r = await call();
    YtExtras.onRequestForTest?.call(kind, verdictOf(r), watch.elapsed);
    // a delete that closed the network ended this one: said as such
    check();
    return r;
  }

  Future<YtRoutedResult<YtVideoDetail>> detail(String id) =>
      _detail ??= _detailOnce(id);

  Future<YtRoutedResult<YtVideoDetail>> _detailOnce(String id) async {
    if (net.detailAsksDirect) await _beforeDirect();
    return _timed('detail', () => net.detail(id), (r) => r.verdict);
  }

  Future<YtResult<YtRelatedAndComments>> related(String id) =>
      _related ??= _relatedOnce(id);

  /// The signal of a `next` not asked because the direct source is walled.
  static const directWallSignal = 'direct-wall';

  Future<YtResult<YtRelatedAndComments>> _relatedOnce(String id) async {
    // the direct source alone answers it: not asked while it is walled
    if (YtExtras.directWall() case final wall?) {
      return YtResult.failed(YtVerdict(YtCause.transient, directWallSignal, wall));
    }
    await _beforeDirect();
    return _timed('related', () => net.related(id), (r) => r.verdict);
  }

  /// Once, before this export's first request to the direct source: the
  /// previous export's traffic there is [YtExtras.exportGap] behind (review
  /// 1, l9; the details too, review 2 P3).
  Future<void> _beforeDirect() => _gap ??= _exportGap();

  Future<void> _exportGap() async {
    if (YtExtras._lastDirectTraffic case final last?) {
      final wait = YtExtras.exportGap - YtExtras.clock().difference(last);
      if (wait > Duration.zero) {
        await net.pause(wait);
        check();
      }
    }
    directAsked = true;
  }

  Future<YtResult<String>> caption(
    YouTubeVideoSource? source,
    YtCaptionTrack track,
  ) => _timed(
    'caption',
    () => net.captionContent(source, track),
    (r) => r.verdict,
  );

  Future<YtResult<YtPage<YtComment>>> comments(String token) {
    directAsked = true;
    return _timed('comments', () => net.comments(token), (r) => r.verdict);
  }

  /// [YtExtras.commentGap], then whether the export was cancelled meanwhile.
  Future<void> pause() async {
    await net.pause(YtExtras.commentGap);
    check();
  }
}

/// The comment step saved nothing: `comments unavailable (<why>)`, the
/// step's error as design §6.2 has it; there is no comments file, so the
/// offline page says 「未保存评论」. [walled]: because the direct source is
/// walled, so they are asked for again later (review 2, item 5);
/// [skipped]: not asked at all, the wall known before.
class YtCommentsUnavailable implements Exception {
  const YtCommentsUnavailable(
    this.why, {
    this.walled = false,
    this.skipped = false,
  });

  final String why;
  final bool walled;
  final bool skipped;

  @override
  String toString() => 'comments unavailable ($why)';
}

/// An export stopped because its entry was deleted.
class YtExtrasCancelled implements Exception {
  const YtExtrasCancelled();

  @override
  String toString() => 'cancelled';
}

/// The avatars of saved comments, once per URL in `comments_images/` next
/// to the comments file (as bilibili's `CommentImages`, design §6.4):
/// [parallel] at a time, through [YtExtrasNet.image] (a checked bare
/// client, [YtExtras.imageMaxBytes] each), written as `.part` and renamed.
/// A failure only leaves that comment without an avatar file.
class YtCommentImages {
  YtCommentImages(this.folder, this.net, {this.cancelled});

  static const dirName = 'comments_images';
  static const parallel = 6;

  final String folder;
  final YtExtrasNet net;
  final bool Function()? cancelled;

  final _done = <String, Future<String?>>{};
  int saved = 0;

  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  /// The path relative to [folder]; null when it is not saved.
  Future<String?> save(String url) {
    if (url.isEmpty) return Future.value();
    url = YtExtras.smallAvatar(url);
    return _done[url] ??= _save(url);
  }

  /// Until every save asked for so far is done: nothing is written into the
  /// folder after it.
  Future<void> settled() => Future.wait(_done.values);

  Future<String?> _save(String url) async {
    if (_running < parallel) {
      _running++;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      // [_running] is handed over, not given back
      await turn.future;
    }
    try {
      if (cancelled?.call() ?? false) return null;
      return await _fetch(url);
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }

  Future<String?> _fetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !YtExtras.isImageHost(uri)) return null;
    final name = '${md5.convert(utf8.encode(url))}${_ext(uri)}';
    final file = File(path.join(folder, dirName, name));
    final part = File('${file.path}.part');
    try {
      if (!file.existsSync()) {
        // not recursive: the export folder deleted meanwhile fails rather
        // than being made again
        await file.parent.create();
        final bytes = await net.image(uri, maxBytes: YtExtras.imageMaxBytes);
        if (cancelled?.call() ?? false) return null;
        await part.writeAsBytes(bytes, flush: true);
        await part.rename(file.path);
        saved++;
      }
      return '$dirName/$name';
    } catch (e) {
      try {
        if (part.existsSync()) await part.delete();
      } catch (_) {}
      if (kDebugMode) debugPrint('youtube comment image $url: $e');
      return null;
    }
  }

  static String _ext(Uri uri) {
    final ext = path.extension(uri.path).toLowerCase();
    return ext.isEmpty || ext.length > 5 || ext.contains('=') ? '.jpg' : ext;
  }
}

/// The network the extras use (design §6.2, §6.3): the video's details and
/// captions from [play] (the download's own router: its own health table,
/// never the pages' shared one); `next` and the comment pages from a router
/// of their own that holds the direct source alone (as the video page's
/// `router`), its health [YtExtras.commentsHealth], one table for the app
/// session; images over a bare [HttpClient] with every hop checked.
///
/// [cancelled] is looked at inside every source call, a router's retry's
/// too (review 1, c2); [close] ends what is in flight and any pause: the
/// comments' source and the images' client are closed, [play]'s sources by
/// [closeSources] (the export's own, review 2 P2), and a detail or caption
/// request still under way is answered at once with [YtExtrasCancelled].
class YtExtrasLiveNet implements YtExtrasNet {
  YtExtrasLiveNet({
    required this.play,
    HttpClient Function()? httpClient,
    YtDirectSource? direct,
    this.cancelled,
    this.closeSources,
    @visibleForTesting this.sleepForTest,
  }) : _direct = direct ?? YtDirectSource.create(),
       _client = (httpClient ?? HttpClient.new)()
         ..idleTimeout = const Duration(seconds: 30)
         ..connectionTimeout = const Duration(seconds: 30) {
    _comments = YtSourceRouter(
      _direct,
      health: YtExtras.commentsHealth,
      // the cooldowns it starts and [YtExtras.directWall] on one clock
      clock: () => YtExtras.clock(),
      // a retry waits at least the pacing (review 1, l8)
      sleep: (d) => pause(d < YtExtras.commentGap ? YtExtras.commentGap : d),
    );
    _hops = YtCheckedHops(_client);
  }

  final YtSourceRouter play;
  final YtDirectSource _direct;
  final bool Function()? cancelled;

  /// Closes [play]'s sources, when they are the export's own.
  final void Function()? closeSources;

  @override
  bool get detailAsksDirect => play.mode != YtSourceMode.fallbackOnly;

  /// Tests only: in place of the pauses (and the router's waits).
  final Future<void> Function(Duration)? sleepForTest;
  late final YtSourceRouter _comments;
  final HttpClient _client;
  late final YtCheckedHops _hops;
  final _closed = Completer<void>();

  /// The comments' health (the session's, [YtExtras.commentsHealth]).
  Map<String, YtSourceHealth> get commentsHealth => _comments.health;

  void _check() {
    if (_closed.isCompleted || (cancelled?.call() ?? false)) {
      throw const YtExtrasCancelled();
    }
  }

  /// [request], or [YtExtrasCancelled] as soon as the net is closed: a
  /// request that does not end when its source is closed holds nothing up.
  Future<T> _untilClosed<T>(Future<T> request) {
    if (_closed.isCompleted) {
      // its answer, or its error, is not waited for
      request.ignore();
      return Future.error(const YtExtrasCancelled());
    }
    return Future.any([
      request,
      _closed.future.then<T>((_) => throw const YtExtrasCancelled()),
    ]);
  }

  @override
  Future<YtRoutedResult<YtVideoDetail>> detail(String videoId) {
    _check();
    return _untilClosed(
      play.run((s) {
        _check();
        return s.detail(videoId);
      }),
    );
  }

  @override
  Future<YtResult<String>> captionContent(
    YouTubeVideoSource? source,
    YtCaptionTrack track,
  ) {
    _check();
    return _untilClosed((source ?? play.direct).captionContent(track));
  }

  @override
  Future<YtResult<YtRelatedAndComments>> related(String videoId) async =>
      (await _comments.run((s) {
        _check();
        return (s as YtDirectSource).related(videoId);
      })).result;

  @override
  Future<YtResult<YtPage<YtComment>>> comments(String token) async =>
      (await _comments.run((s) {
        _check();
        return (s as YtDirectSource).comments(token);
      })).result;

  @override
  Future<List<int>> image(Uri uri, {required int maxBytes}) async {
    _check();
    HttpClientRequest? request;
    StreamSubscription<List<int>>? sub;
    final done = Completer<List<int>>();
    void fail(Object e) {
      if (done.isCompleted) return;
      request?.abort(e);
      sub?.cancel();
      done.completeError(e);
    }

    // the whole fetch, redirects included (review 1, l10)
    final deadline = Timer(
      YtExtras.imageDeadline,
      () => fail(TimeoutException('image over its deadline', YtExtras.imageDeadline)),
    );
    unawaited(() async {
      try {
        final (_, response) = await _hops.send(
          'GET',
          uri,
          timeout: const Duration(seconds: 30),
          onRequest: (r) => request = r,
          allow: YtExtras.isImageHost,
          drainTimeout: const Duration(seconds: 10),
          connectTimeout: const Duration(seconds: 30),
        );
        if (done.isCompleted) return;
        if (response.statusCode != HttpStatus.ok) {
          await response
              .drain<void>()
              .timeout(const Duration(seconds: 10))
              .catchError((_) {});
          fail(HttpException('HTTP ${response.statusCode}', uri: uri));
          return;
        }
        final bytes = BytesBuilder(copy: false);
        sub = response
            .timeout(const Duration(seconds: 30))
            .listen(
              (chunk) {
                bytes.add(chunk);
                if (bytes.length > maxBytes) {
                  fail(HttpException('over $maxBytes bytes', uri: uri));
                }
              },
              onError: fail,
              onDone: () {
                if (!done.isCompleted) done.complete(bytes.takeBytes());
              },
              cancelOnError: true,
            );
      } catch (e) {
        fail(e);
      }
    }());
    try {
      return await done.future;
    } finally {
      deadline.cancel();
    }
  }

  /// [duration], over at once when the net is closed.
  @override
  Future<void> pause(Duration duration) {
    if (sleepForTest case final sleep?) return sleep(duration);
    if (_closed.isCompleted) return Future.value();
    return Future.any([Future<void>.delayed(duration), _closed.future]);
  }

  @override
  void close() {
    if (_closed.isCompleted) return;
    _closed.complete();
    _direct.close();
    _client.close(force: true);
    closeSources?.call();
  }
}
