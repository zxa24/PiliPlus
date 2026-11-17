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

  void close();
}

abstract final class YtExtras {
  static const introSuffix = DownloadExtras.introSuffix;
  static const commentsSuffix = DownloadExtras.commentsSuffix;
  static const introFormat = 'librepili-yt-intro-1';
  static const commentsFormat = 'librepili-yt-comments-1';

  /// At most this many subtitle tracks (§10-1).
  static const maxTracks = 10;

  /// An avatar's (or the intro's channel face's) byte cap (§6.4).
  static const imageMaxBytes = 64 * 1024;

  /// Between comment pages and between reply requests (design §6.3; §9
  /// probe 4 decides whether it is enough). The self test's
  /// `--comment-gap-ms` changes it.
  static Duration commentGap = const Duration(milliseconds: 200);

  /// Self tests only: told of every request the extras make.
  static void Function(String kind, YtVerdict verdict, Duration took)?
  onRequestForTest;

  /// Self tests only: told what an export wrote, as it ends.
  static void Function(String key, Map<String, Object?> written)?
  onWrittenForTest;

  /// The step names, as bilibili's ([DownloadProgress]).
  static Map<String, int> plan() => DownloadProgress.extrasPlan(
    intro: true,
    cover: Pref.dlSaveCover,
    // danmaku and the preview sheet: not a YouTube download's (§6, user
    // 2026-11-16 「2A」)
    danmaku: false,
    subtitles: Pref.dlSaveSubtitle,
    comments: Pref.dlSaveComments ? Pref.dlCommentCount : 0,
  );

  /// Writes the enabled extras of [entry] beside its export; returns what
  /// was written (for self tests). [cancelled] is polled before every
  /// request: once true (the entry was deleted) nothing more is fetched or
  /// written.
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
      if (cancelled?.call() ?? false) throw const _Cancelled();
    }

    try {
      // the folder is the user's shareable copy: this device's paths left
      // out (as bilibili's, download_extras.dart)
      final info = entry.toJson()
        ..remove('merged_path')
        ..remove('merged_parts')
        ..remove('extras_pending')
        ..remove('transcript_pending');
      await File(path.join(folder, DownloadExtras.infoName)).writeAsString(
        const JsonEncoder.withIndent(' ').convert(info),
      );
    } catch (_) {}

    Future<void> step(String name, Future<Object?> Function() body) async {
      if (cancelled?.call() ?? false) return;
      progress?.extrasStart(name);
      try {
        written[name] = await body();
      } catch (e) {
        written[name] = 'error: $e';
        if (kDebugMode) debugPrint('youtube extras $name: $e');
      } finally {
        progress?.extrasDone(name);
      }
    }

    final calls = _Calls(net, check);
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
          () => _comments(entry, folder, base, calls, cancelled, progress),
        );
      }
    } finally {
      net.close();
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
        } on _Cancelled {
          rethrow;
        } catch (e) {
          if (kDebugMode) debugPrint('youtube extras face: $e');
        }
      }
    }
    calls.check();
    await File(path.join(folder, '$base$introSuffix')).writeAsString(
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
    for (final (i, p) in picked.indexed) {
      progress?.extras(DownloadProgress.stepSubtitles, 1 + i, 1 + picked.length);
      final r = await calls.caption(detail.source, p.track);
      final srt = r.ok ? vttToSrt(r.value!) : null;
      if (srt == null) {
        failed.add('${p.name}: ${r.ok ? 'no cues' : r.verdict}');
        continue;
      }
      calls.check();
      await File(path.join(folder, p.name)).writeAsString(srt);
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
    if (!fileName.startsWith('$base.') || !fileName.endsWith('.srt')) {
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
    final related = await calls.related(entry.videoId);
    String? token = related.ok ? related.value!.commentsToken : null;
    if (token == null) {
      throw StateError(
        'comments unavailable '
        '(${related.ok ? 'no token' : related.verdict})',
      );
    }
    // a wall met stops this step; what was taken is written (§6.3)
    YtVerdict? blocked;
    final roots = <YtComment>[];
    var pages = 0;
    final pagesPlanned = (maxRoots / DownloadProgress.commentsPerPage).ceil();
    while (roots.length < maxRoots && token != null) {
      if (pages > 0) await calls.pause();
      progress?.extras(
        DownloadProgress.stepCommentList,
        pages,
        math.max(pagesPlanned, pages + 1),
      );
      final r = await calls.comments(token);
      if (!r.ok) {
        if (r.verdict.cause == YtCause.ipBlocked) {
          blocked = r.verdict;
        } else if (roots.isEmpty) {
          throw StateError('comments: ${r.verdict}');
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
    progress?.extrasDone(DownloadProgress.stepCommentList);

    final images = YtCommentImages(folder, calls.net, cancelled: cancelled);
    final List<Map<String, Object?>> items;
    var replyCount = 0;
    try {
      final pending = <Future<Map<String, Object?>>>[];
      for (final (i, root) in roots.indexed) {
        calls.check();
        progress?.extras(DownloadProgress.stepComments, i, roots.length);
        final replies = <YtComment>[];
        var next = root.replyToken;
        while (blocked == null &&
            maxReplies > 0 &&
            next != null &&
            replies.length < maxReplies) {
          await calls.pause();
          final r = await calls.comments(next);
          if (!r.ok) {
            if (r.verdict.cause == YtCause.ipBlocked) blocked = r.verdict;
            break;
          }
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
    calls.check();
    await File(path.join(folder, '$base$commentsSuffix')).writeAsString(
      const JsonEncoder.withIndent(' ').convert({
        'format': commentsFormat,
        'videoId': entry.videoId,
        'title': entry.title,
        // the order the video's own first token gives (YouTube's 「Top」)
        'sort': 'top',
        'fetchedAt': DateTime.now().toIso8601String(),
        'count': items.length,
        'stoppedBy': ?blocked?.toString(),
        'comments': items,
      }),
    );
    if (blocked != null) {
      EventLog.add(
        'download',
        '${entry.logLabel}: comments stopped by $blocked after '
            '${items.length} comments',
      );
    }
    return '${items.length} comments, $replyCount replies, '
        '${images.saved} images'
        '${blocked == null ? '' : ', stopped: $blocked'}';
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

  Future<YtRoutedResult<YtVideoDetail>>? _detail;
  Future<YtResult<YtRelatedAndComments>>? _related;

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
    return r;
  }

  Future<YtRoutedResult<YtVideoDetail>> detail(String id) => _detail ??=
      _timed('detail', () => net.detail(id), (r) => r.verdict);

  Future<YtResult<YtRelatedAndComments>> related(String id) => _related ??=
      _timed('related', () => net.related(id), (r) => r.verdict);

  Future<YtResult<String>> caption(
    YouTubeVideoSource? source,
    YtCaptionTrack track,
  ) => _timed(
    'caption',
    () => net.captionContent(source, track),
    (r) => r.verdict,
  );

  Future<YtResult<YtPage<YtComment>>> comments(String token) =>
      _timed('comments', () => net.comments(token), (r) => r.verdict);

  Future<void> pause() => net.pause(YtExtras.commentGap);
}

class _Cancelled implements Exception {
  const _Cancelled();

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
/// `router`), so a cooldown the comments meet stays theirs; images over a
/// bare [HttpClient] with every hop checked.
class YtExtrasLiveNet implements YtExtrasNet {
  YtExtrasLiveNet({required this.play, HttpClient Function()? httpClient})
    : _direct = YtDirectSource.create(),
      _client = (httpClient ?? HttpClient.new)()
        ..idleTimeout = const Duration(seconds: 30)
        ..connectionTimeout = const Duration(seconds: 30) {
    _comments = YtSourceRouter(_direct);
    _hops = YtCheckedHops(_client);
  }

  final YtSourceRouter play;
  final YtDirectSource _direct;
  late final YtSourceRouter _comments;
  final HttpClient _client;
  late final YtCheckedHops _hops;

  /// The comments' own health (tests and the probe read it).
  Map<String, YtSourceHealth> get commentsHealth => _comments.health;

  @override
  Future<YtRoutedResult<YtVideoDetail>> detail(String videoId) =>
      play.run((s) => s.detail(videoId));

  @override
  Future<YtResult<String>> captionContent(
    YouTubeVideoSource? source,
    YtCaptionTrack track,
  ) => (source ?? play.direct).captionContent(track);

  @override
  Future<YtResult<YtRelatedAndComments>> related(String videoId) async =>
      (await _comments.run((s) => (s as YtDirectSource).related(videoId)))
          .result;

  @override
  Future<YtResult<YtPage<YtComment>>> comments(String token) async =>
      (await _comments.run((s) => (s as YtDirectSource).comments(token)))
          .result;

  @override
  Future<List<int>> image(Uri uri, {required int maxBytes}) async {
    final (_, response) = await _hops.send(
      'GET',
      uri,
      timeout: const Duration(seconds: 30),
      allow: YtExtras.isImageHost,
      drainTimeout: const Duration(seconds: 10),
      connectTimeout: const Duration(seconds: 30),
    );
    if (response.statusCode != HttpStatus.ok) {
      await response
          .drain<void>()
          .timeout(const Duration(seconds: 10))
          .catchError((_) {});
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final bytes = BytesBuilder(copy: false);
    final done = Completer<List<int>>();
    late final StreamSubscription<List<int>> sub;
    sub = response
        .timeout(const Duration(seconds: 30))
        .listen(
          (chunk) {
            bytes.add(chunk);
            if (bytes.length > maxBytes && !done.isCompleted) {
              sub.cancel();
              done.completeError(
                HttpException('over $maxBytes bytes', uri: uri),
              );
            }
          },
          onError: (Object e) {
            if (!done.isCompleted) done.completeError(e);
          },
          onDone: () {
            if (!done.isCompleted) done.complete(bytes.takeBytes());
          },
          cancelOnError: true,
        );
    return done.future;
  }

  @override
  Future<void> pause(Duration duration) => Future.delayed(duration);

  @override
  void close() {
    _direct.close();
    _client.close(force: true);
  }
}
