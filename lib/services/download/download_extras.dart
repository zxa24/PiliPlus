import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/transcript_files.dart';
import 'package:PiliPlus/services/download/download_progress.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/wbi_sign.dart';
import 'package:crypto/crypto.dart' show md5;
import 'package:dio/dio.dart' show Options, ResponseType;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

/// LibrePili: extra files written next to a downloaded video. Folder
/// convention, `base` being the video file name without extension:
/// `base.mp4`, `base.danmaku.xml`, `base.danmaku.ass`, `base.LANG.srt`,
/// `base.asr.srt` and `base.asr.json` (the on-device transcript, see
/// TranscriptFiles), `base.comments.json`, `base.intro.json` (the intro
/// page's data, see [introSuffix]), `cover.jpg`. Every part is best-effort:
/// a failure never affects the video itself.
abstract final class DownloadExtras {
  static const xmlSuffix = '.danmaku.xml';
  static const assSuffix = '.danmaku.ass';
  static const commentsSuffix = '.comments.json';

  /// What the intro page shows of a video, as it was when downloaded
  /// (format `librepili-intro-1`): bilibili's own answers kept as they came
  /// — `view` (the video: title, description, numbers, staff), `tags`,
  /// `card` (the uploader: name, followers, videos) — and `faces`, the
  /// avatars as base64 by their URL, so the offline page shows them without
  /// a request and the folder stays one file per kind.
  static const introSuffix = '.intro.json';
  static const coverName = 'cover.jpg';

  /// The download record, so a folder opened later (local player / drag and
  /// drop) restores title, ids and quality.
  static const infoName = 'librepili.json';

  /// The extras switched on, as [DownloadProgress.planExtras] counts them.
  static Map<String, int> plan() => DownloadProgress.extrasPlan(
    intro: true,
    cover: Pref.dlSaveCover,
    danmaku: Pref.dlSaveDanmakuXml || Pref.dlSaveDanmakuAss,
    subtitles: Pref.dlSaveSubtitle,
    comments: Pref.dlSaveComments ? Pref.dlCommentCount : 0,
  );

  /// Writes the enabled extras; returns what was written (for self tests).
  /// [cancelled] is polled between steps and requests: once it returns true
  /// (the entry was deleted) nothing more is fetched or written. [progress]
  /// is told how far each step is.
  static Future<Map<String, Object?>> export({
    required BiliDownloadEntryInfo entry,
    required String folder,
    required String base,
    bool Function()? cancelled,
    DownloadProgress? progress,
  }) async {
    final written = <String, Object?>{};
    void check() {
      if (cancelled?.call() ?? false) throw const _Cancelled();
    }

    try {
      // this folder is the user's shareable copy: the absolute paths of this
      // device (they hold the account / user name) are left out. The reader
      // ([LocalPlayer]) resolves the video file locally anyway.
      final info = entry.toJson()
        ..remove('merged_path')
        ..remove('merged_parts')
        ..remove('extras_pending')
        ..remove('transcript_pending');
      await File(path.join(folder, infoName)).writeAsString(
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
        if (kDebugMode) debugPrint('download extras $name: $e');
      } finally {
        progress?.extrasDone(name);
      }
    }

    // always: it is small, and without it the offline page has no intro
    await step(
      DownloadProgress.stepIntro,
      () => _intro(entry, folder, base, check),
    );

    if (Pref.dlSaveCover) {
      await step(DownloadProgress.stepCover, () async {
        final src = File(path.join(entry.entryDirPath, PathUtils.coverName));
        if (!src.existsSync()) return null;
        await src.copy(path.join(folder, coverName));
        return coverName;
      });
    }

    if (Pref.dlSaveDanmakuXml || Pref.dlSaveDanmakuAss) {
      await step(DownloadProgress.stepDanmaku, () async {
        final pb = File(path.join(entry.entryDirPath, PathUtils.danmakuName));
        if (!pb.existsSync()) return null;
        final elems = DmSegMobileReply.fromBuffer(await pb.readAsBytes()).elems
          ..sort((a, b) => a.progress.compareTo(b.progress));
        final out = <String>[];
        if (Pref.dlSaveDanmakuXml) {
          await File(path.join(folder, '$base$xmlSuffix'))
              .writeAsString(danmakuToXml(elems, cid: entry.cid));
          out.add(xmlSuffix);
        }
        if (Pref.dlSaveDanmakuAss) {
          await File(path.join(folder, '$base$assSuffix'))
              .writeAsString(danmakuToAss(elems, title: entry.showTitle));
          out.add(assSuffix);
        }
        return '${elems.length} items -> ${out.join(', ')}';
      });
    }

    if (Pref.dlSaveSubtitle) {
      await step(
        DownloadProgress.stepSubtitles,
        () => _subtitles(entry, folder, base, check, progress),
      );
    }

    if (Pref.dlSaveComments) {
      await step(
        DownloadProgress.stepComments,
        () => _comments(entry, folder, base, check, cancelled, progress),
      );
    }
    return written;
  }

  // ------------------------------------------------------------ subtitles

  static Future<List<String>> _subtitles(
    BiliDownloadEntryInfo entry,
    String folder,
    String base,
    void Function() check,
    DownloadProgress? progress,
  ) async {
    final res = await VideoHttp.playInfo(
      bvid: entry.bvid,
      cid: entry.cid,
      seasonId: entry.seasonId,
      epId: entry.ep?.episodeId,
    );
    var subtitles = <({String lan, String url})>[
      for (final s in res.dataOrNull?.subtitle?.subtitles ?? const <Subtitle>[])
        if (s.subtitleUrl case final url? when url.isNotEmpty)
          (lan: s.lan, url: url),
    ];
    if (subtitles.isEmpty) {
      // anonymous playInfo omits subtitles; the player falls back to DmView
      final view = await DmGrpc.dmView(entry.avid, entry.cid);
      if (view case Success(:final response) when response.hasSubtitle()) {
        subtitles = [
          for (final s in response.subtitle.subtitles)
            if (s.subtitleUrl.isNotEmpty)
              (
                lan: s.lan,
                url: s.subtitleUrl.replaceFirst(RegExp('^https?:'), ''),
              ),
        ];
      }
    }
    final written = <String>[];
    // the list, then one request per language
    for (final (i, s) in subtitles.indexed) {
      check();
      progress?.extras(
        DownloadProgress.stepSubtitles,
        1 + i,
        1 + subtitles.length,
      );
      final srt = await VideoHttp.getSubtitles(s.url, format: .srt);
      if (srt == null) continue;
      final name = '$base.${_safe(s.lan)}.srt';
      await File(path.join(folder, name)).writeAsString(srt);
      written.add(name);
    }
    // what the device transcribed of this part before it was downloaded;
    // what it transcribes later is written as the cache keeps it
    // (DownloadService._keepTranscript)
    try {
      final video = entry.mergedPath ?? path.join(folder, '$base.mp4');
      final kept = await SubtitleCache.instance.open(
        SubtitleCacheKey.bilibili(entry.cid),
        AsrService.recogniserId,
      );
      if (await TranscriptFiles.write(kept, video)) {
        written.add('$base${TranscriptFiles.srtSuffix}');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('download extras transcript: $e');
    }
    return written;
  }

  // ---------------------------------------------------------------- intro

  /// Writes `base.intro.json`. Bangumi episodes have a page of their own
  /// (not this one): none for them yet.
  static Future<String?> _intro(
    BiliDownloadEntryInfo entry,
    String folder,
    String base,
    void Function() check,
  ) async {
    if (entry.ep != null) return null;
    final view = await _data(
      Api.videoIntro,
      await WbiSign.makSign({'bvid': entry.bvid}),
    );
    if (view is! Map<String, dynamic>) throw StateError('view: $view');
    // the whole season's episodes: large, and not shown offline
    view.remove('ugc_season');
    check();
    final tags = await _data(Api.videoTags, {
      'bvid': entry.bvid,
      'cid': entry.cid,
    });
    final mid = (view['owner'] as Map?)?['mid'];
    final staff = (view['staff'] as List?)?.cast<Map>() ?? const [];
    Object? card;
    if (mid != null && staff.isEmpty) {
      check();
      card = await _data(Api.memberCardInfo, {'mid': mid, 'photo': false});
    }
    final faces = <String, String>{};
    for (final url in {
      if (card case {'card': {'face': final String face}})
        face
      // the card refused: the uploader's face from the video's own answer
      else if (view['owner']
          case {
            'face': final String face,
          }
          when staff.isEmpty)
        face,
      for (final s in staff)
        if (s['face'] case final String face) face,
    }) {
      check();
      try {
        // a thumbnail: the original can be a few hundred KB, shown at 35 px
        final res = await Request.dio.get<List<int>>(
          '${url.http2https}@120w_120h_1c.webp',
          options: Options(responseType: ResponseType.bytes),
        );
        if (res.data case final bytes?) faces[url] = base64Encode(bytes);
      } catch (e) {
        if (kDebugMode) debugPrint('download extras face $url: $e');
      }
    }
    check();
    await File(path.join(folder, '$base$introSuffix')).writeAsString(
      jsonEncode({
        'format': 'librepili-intro-1',
        'fetchedAt': DateTime.now().toIso8601String(),
        'view': view,
        'tags': ?tags,
        'card': ?card,
        'faces': faces,
      }),
    );
    return '${faces.length} faces';
  }

  /// The `data` of a bilibili API answer; null when it says no.
  static Future<Object?> _data(String url, Map<String, dynamic> query) async {
    final res = await Request().get(url, queryParameters: query);
    if (res.data case {'code': 0, 'data': final data}) return data;
    return null;
  }

  // ------------------------------------------------------------- comments

  static Future<String> _comments(
    BiliDownloadEntryInfo entry,
    String folder,
    String base,
    void Function() check,
    bool Function()? cancelled,
    DownloadProgress? progress,
  ) async {
    final maxRoots = Pref.dlCommentCount;
    final maxReplies = Pref.dlReplyCount;
    // bangumi episodes are commented on by aid as well
    final oid = entry.avid;
    final roots = <ReplyInfo>[];
    Int64? cursorNext;
    var pages = 0;
    final pagesPlanned = (maxRoots / DownloadProgress.commentsPerPage).ceil();
    while (roots.length < maxRoots) {
      check();
      progress?.extras(
        DownloadProgress.stepCommentList,
        pages,
        math.max(pagesPlanned, pages + 1),
      );
      final res = await ReplyGrpc.mainList(
        oid: oid,
        mode: Mode.MAIN_LIST_HOT,
        offset: null,
        cursorNext: cursorNext,
      );
      if (res is! Success<MainListReply>) {
        if (roots.isEmpty) throw StateError('$res');
        break;
      }
      final page = res.response;
      pages++;
      roots.addAll(page.replies);
      if (page.cursor.isEnd || page.replies.isEmpty) break;
      cursorNext = page.cursor.next;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (roots.length > maxRoots) roots.removeRange(maxRoots, roots.length);
    progress?.extrasDone(DownloadProgress.stepCommentList);

    final images = CommentImages(folder, cancelled: cancelled);
    final List<Map<String, Object?>> items;
    try {
      final pending = <Future<Map<String, Object?>>>[];
      for (final (i, root) in roots.indexed) {
        check();
        progress?.extras(DownloadProgress.stepComments, i, roots.length);
        var replies = root.replies.toList();
        final wanted = math.min(maxReplies, root.count.toInt());
        if (replies.length < wanted) {
          replies = await _replies(oid, root.id.toInt(), wanted, check);
        }
        // its pictures are fetched while the next ones' replies are asked
        pending.add(_withReplies(root, replies.take(maxReplies), images));
      }
      items = await Future.wait(pending);
    } finally {
      // a cancelled export leaves nothing being written into the folder
      await images.settled();
    }

    final json = {
      // 2: 1 with `pb`, `files`, `avatarFile` and `upMid` (readers of 1
      // read it as before)
      'format': 'librepili-comments-2',
      'oid': oid,
      'bvid': entry.bvid,
      'upMid': ?entry.ownerId,
      'title': entry.showTitle,
      'sort': 'hot',
      'fetchedAt': DateTime.now().toIso8601String(),
      'count': items.length,
      'comments': items,
    };
    check();
    await File(path.join(folder, '$base$commentsSuffix')).writeAsString(
      const JsonEncoder.withIndent(' ').convert(json),
    );
    return '${items.length} comments, ${images.saved} images';
  }

  static Future<Map<String, Object?>> _withReplies(
    ReplyInfo root,
    Iterable<ReplyInfo> replies,
    CommentImages images,
  ) async {
    final json = replyToJson(root, images);
    final saved = Future.wait([
      for (final r in replies) replyToJson(r, images),
    ]);
    return (await json)..['replies'] = await saved;
  }

  static Future<List<ReplyInfo>> _replies(
    int oid,
    int root,
    int wanted,
    void Function() check,
  ) async {
    final out = <ReplyInfo>[];
    String? offset;
    while (out.length < wanted) {
      await Future.delayed(const Duration(milliseconds: 200));
      check();
      final res = await ReplyGrpc.detailList(
        oid: oid,
        root: root,
        rpid: 0,
        mode: Mode.MAIN_LIST_HOT,
        offset: offset,
      );
      if (res is! Success<DetailListReply>) break;
      final page = res.response;
      out.addAll(page.root.replies);
      offset = page.paginationReply.nextOffset;
      if (page.root.replies.isEmpty || offset.isEmpty) break;
    }
    return out;
  }

  /// [images] saves the comment's avatar (a thumbnail), pictures and emotes
  /// next to the video; their paths (relative to the comments file) are
  /// recorded, so the offline panel shows them without any network request.
  ///
  /// `pb` is the comment as bilibili sent it (ReplyInfo, base64), which the
  /// offline panel shows with the online comment's own widget; `files` maps
  /// the URLs in it to the saved copies. The other fields are the same
  /// comment in plain words, for people and other tools.
  static Future<Map<String, Object?>> replyToJson(
    ReplyInfo r, [
    CommentImages? images,
  ]) async {
    final pictures = <String>[];
    final emotes = <String, String>{};
    final files = <String, String>{};
    String? avatar;
    if (images != null) {
      Future<String?> keep(String url, {String? fetch}) async {
        if (url.isEmpty) return null;
        final local = await images.save(fetch ?? url);
        if (local != null) files[url] = local;
        return local;
      }

      // all asked for at once ([CommentImages.parallel] at a time), then
      // collected in order
      final face = r.member.face;
      // shown at 34 px: the original can be a few hundred KB
      final faceJob = keep(face, fetch: '${face.http2https}@96w_96h_1c.webp');
      final pictureJobs = [for (final p in r.content.pictures) keep(p.imgSrc)];
      final emoteJobs = {
        for (final e in r.content.emotes.entries) e.key: keep(e.value.url),
      };
      // the replies shown under it in the list: their emotes too
      final previewJobs = [
        for (final c in r.replies)
          for (final e in c.content.emotes.values) keep(e.url),
      ];
      avatar = await faceJob;
      for (final job in pictureJobs) {
        if (await job case final local?) pictures.add(local);
      }
      for (final MapEntry(:key, :value) in emoteJobs.entries) {
        if (await value case final local?) emotes[key] = local;
      }
      await Future.wait(previewJobs);
    }
    return {
      'rpid': r.id.toInt(),
      'mid': r.mid.toInt(),
      'uname': r.member.name,
      'avatar': r.member.face,
      'content': r.content.message,
      'ctime': r.ctime.toInt(),
      'like': r.like.toInt(),
      'replyCount': r.count.toInt(),
      if (pictures.isNotEmpty) 'pictures': pictures,
      if (emotes.isNotEmpty) 'emotes': emotes,
      'avatarFile': ?avatar,
      if (files.isNotEmpty) 'files': files,
      'pb': base64Encode(
        (r.deepCopy()
              ..unknownFields.clear()
              ..clearTrackInfo())
            .writeToBuffer(),
      ),
    };
  }

  // ------------------------------------------------------------ danmaku

  /// Bilibili XML danmaku format (as served by comment.bilibili.com).
  static String danmakuToXml(List<DanmakuElem> elems, {required int cid}) {
    final b = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8"?>\n<i>')
      ..write('<chatserver>chat.bilibili.com</chatserver>')
      ..write('<chatid>$cid</chatid><mission>0</mission>')
      ..write('<maxlimit>${elems.length}</maxlimit><state>0</state>')
      ..write('<real_name>0</real_name><source>k-v</source>\n');
    for (final e in elems) {
      final p = [
        (e.progress / 1000).toStringAsFixed(5),
        e.mode,
        e.fontsize,
        e.color,
        e.ctime,
        e.pool,
        e.midHash,
        e.idStr.isNotEmpty ? e.idStr : e.id,
        e.weight,
      ].join(',');
      b.write('<d p="$p">${_xmlEscape(e.content)}</d>\n');
    }
    b.write('</i>\n');
    return b.toString();
  }

  /// `<d ... p="..." ...>text</d>`; other tools may add attributes before
  /// or after `p` and quote it with ' instead of ".
  static final _xmlDanmaku = RegExp(
    r'''<d\s[^>]*?\bp\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)</d>''',
  );

  /// Parses Bilibili XML danmaku (as written by [danmakuToXml] or saved by
  /// other tools) back into elements for the player.
  static List<DanmakuElem> xmlToDanmaku(String xml) {
    final out = <DanmakuElem>[];
    for (final m in _xmlDanmaku.allMatches(xml)) {
      final p = (m.group(1) ?? m.group(2)!).split(',');
      if (p.length < 4) continue;
      final seconds = double.tryParse(p[0]);
      if (seconds == null) continue;
      out.add(
        DanmakuElem(
          progress: (seconds * 1000).round(),
          mode: int.tryParse(p[1]) ?? 1,
          fontsize: int.tryParse(p[2]) ?? 25,
          color: int.tryParse(p[3]) ?? 0xFFFFFF,
          ctime: p.length > 4 ? Int64(int.tryParse(p[4]) ?? 0) : null,
          pool: p.length > 5 ? int.tryParse(p[5]) : null,
          midHash: p.length > 6 ? p[6] : null,
          idStr: p.length > 7 ? p[7] : null,
          weight: p.length > 8 ? int.tryParse(p[8]) : null,
          content: _xmlUnescape(m.group(3)!),
        ),
      );
    }
    return out;
  }

  static final _xmlEntity = RegExp(r'&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-z]+);');

  /// Named and numeric (`&#39;`, `&#x27;`) entities, in one pass so an
  /// escaped `&amp;lt;` stays `&lt;`.
  static String _xmlUnescape(String s) => s.replaceAllMapped(_xmlEntity, (m) {
    final e = m[1]!;
    if (e.startsWith('#')) {
      final code = e.length > 1 && (e[1] == 'x' || e[1] == 'X')
          ? int.tryParse(e.substring(2), radix: 16)
          : int.tryParse(e.substring(1));
      return code != null && code >= 0 && code <= 0x10FFFF
          ? String.fromCharCode(code)
          : m[0]!;
    }
    return switch (e) {
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      'amp' => '&',
      _ => m[0]!,
    };
  });

  static const _assW = 1920;
  static const _assH = 1080;
  static const _scrollSec = 8.0;
  static const _fixedSec = 4.0;

  /// ASS subtitles with a fixed default style, for external players.
  static String danmakuToAss(List<DanmakuElem> elems, {String title = ''}) {
    final b = StringBuffer()
      ..writeln('[Script Info]')
      ..writeln('Title: ${title.replaceAll('\n', ' ')}')
      ..writeln('ScriptType: v4.00+')
      ..writeln('PlayResX: $_assW')
      ..writeln('PlayResY: $_assH')
      ..writeln('WrapStyle: 2')
      ..writeln('ScaledBorderAndShadow: yes')
      ..writeln()
      ..writeln('[V4+ Styles]')
      ..writeln(
        'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
        'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
        'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
        'Alignment, MarginL, MarginR, MarginV, Encoding',
      )
      ..writeln(
        'Style: Danmaku,Microsoft YaHei,50,&H00FFFFFF,&H00FFFFFF,'
        '&H80000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,7,0,0,0,1',
      )
      ..writeln()
      ..writeln('[Events]')
      ..writeln(
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, '
        'MarginV, Effect, Text',
      );

    const lineGap = 6;
    final scrollFree = <double>[]; // per lane: time the lane frees up
    final topFree = <double>[];
    final bottomFree = <double>[];

    int lane(List<double> free, double t, int maxLanes) {
      for (var i = 0; i < free.length; i++) {
        if (free[i] <= t) return i;
      }
      if (free.length < maxLanes) {
        free.add(0);
        return free.length - 1;
      }
      // all busy: reuse the one that frees up first
      var best = 0;
      for (var i = 1; i < free.length; i++) {
        if (free[i] < free[best]) best = i;
      }
      return best;
    }

    for (final e in elems) {
      final text = e.content.trim();
      if (text.isEmpty) continue;
      final mode = e.mode;
      if (mode == 7 || mode == 8 || mode == 9) continue; // scripted/advanced
      final size = _fontPx(e.fontsize);
      final lineH = size + lineGap;
      final maxLanes = math.max(1, (_assH * 0.85 / lineH).floor());
      final w = _textWidth(text, size);
      final t = e.progress / 1000;
      final color = e.color == 0xFFFFFF || e.color == 0
          ? ''
          : '\\c${_assColor(e.color)}';
      final sizeTag = size == 50 ? '' : '\\fs$size';
      final String tags;
      final double end;
      if (mode == 4 || mode == 5) {
        end = t + _fixedSec;
        if (mode == 5) {
          final l = lane(topFree, t, maxLanes);
          topFree[l] = end;
          tags = '\\an8\\pos(${_assW ~/ 2},${l * lineH})';
        } else {
          final l = lane(bottomFree, t, maxLanes);
          bottomFree[l] = end;
          tags = '\\an2\\pos(${_assW ~/ 2},${_assH - l * lineH})';
        }
      } else {
        end = t + _scrollSec;
        final l = lane(scrollFree, t, maxLanes);
        // lane is free again once this item has fully entered the screen
        scrollFree[l] = t + (w + 40) * _scrollSec / (_assW + w);
        tags = '\\move($_assW,${l * lineH},${-w},${l * lineH})';
      }
      b.writeln(
        'Dialogue: 0,${_assTime(t)},${_assTime(end)},Danmaku,,0,0,0,,'
        '{$tags$color$sizeTag}${_assEscape(text)}',
      );
    }
    return b.toString();
  }

  static int _fontPx(int fontsize) => switch (fontsize) {
    <= 18 => 38,
    >= 36 => 68,
    _ => 50,
  };

  static int _textWidth(String s, int size) {
    var w = 0.0;
    for (final r in s.runes) {
      w += r < 0x2E80 ? size * 0.55 : size.toDouble();
    }
    return w.ceil();
  }

  static String _assColor(int rgb) {
    final r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF;
    String h(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
    return '&H${h(b)}${h(g)}${h(r)}&';
  }

  static String _assTime(double s) {
    final cs = (s * 100).round();
    final h = cs ~/ 360000;
    final m = (cs % 360000) ~/ 6000;
    final sec = (cs % 6000) ~/ 100;
    final c = cs % 100;
    String two(int v) => v.toString().padLeft(2, '0');
    return '$h:${two(m)}:${two(sec)}.${two(c)}';
  }

  static String _assEscape(String s) => s
      .replaceAll('{', '｛')
      .replaceAll('}', '｝')
      .replaceAll('\\', '＼')
      .replaceAll('\r', '')
      .replaceAll('\n', '\\N');

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

  static String _safe(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');
}

class _Cancelled implements Exception {
  const _Cancelled();

  @override
  String toString() => 'cancelled';
}

/// Pictures and emotes of saved comments, stored once per URL in
/// `comments_images/` next to the comments file.
///
/// [parallel] at a time: they come from bilibili's image servers, not its
/// API (the comment requests themselves stay one at a time), and one after
/// another they were most of the time comments took — hundreds of avatars
/// and emotes for 200 comments.
class CommentImages {
  CommentImages(this.folder, {this.cancelled});

  static const dirName = 'comments_images';

  static const parallel = 6;

  final String folder;

  /// Once true (the entry was deleted), the ones still waiting are not
  /// fetched.
  final bool Function()? cancelled;

  final _done = <String, Future<String?>>{};
  int saved = 0;

  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  /// Returns the path relative to [folder], or null if it failed.
  Future<String?> save(String url) {
    if (url.isEmpty) return Future.value();
    url = url.http2https;
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
    String? result;
    try {
      var ext = path.extension(Uri.parse(url).path).toLowerCase();
      if (ext.isEmpty || ext.length > 5) ext = '.jpg';
      final name = '${md5.convert(utf8.encode(url))}$ext';
      final file = File(path.join(folder, dirName, name));
      if (!file.existsSync()) {
        // not recursive: if the video folder was deleted meanwhile, fail
        // instead of recreating it as an orphan
        await file.parent.create();
        final part = '${file.path}.part';
        await Request.dio.download(url, part);
        await File(part).rename(file.path);
        saved++;
      }
      result = '$dirName/$name';
    } catch (e) {
      if (kDebugMode) debugPrint('comment image $url: $e');
    }
    return result;
  }
}
