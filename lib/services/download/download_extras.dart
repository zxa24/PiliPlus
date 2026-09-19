import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

/// LibrePili: extra files written next to a downloaded video. Folder
/// convention, `base` being the video file name without extension:
/// `base.mp4`, `base.danmaku.xml`, `base.danmaku.ass`, `base.LANG.srt`,
/// `base.comments.json`, `cover.jpg`. Every part is best-effort: a failure
/// never affects the video itself.
abstract final class DownloadExtras {
  static const xmlSuffix = '.danmaku.xml';
  static const assSuffix = '.danmaku.ass';
  static const commentsSuffix = '.comments.json';
  static const coverName = 'cover.jpg';

  /// Writes the enabled extras; returns what was written (for self tests).
  static Future<Map<String, Object?>> export({
    required BiliDownloadEntryInfo entry,
    required String folder,
    required String base,
  }) async {
    final written = <String, Object?>{};
    Future<void> step(String name, Future<Object?> Function() body) async {
      try {
        written[name] = await body();
      } catch (e) {
        written[name] = 'error: $e';
        if (kDebugMode) debugPrint('download extras $name: $e');
      }
    }

    if (Pref.dlSaveCover) {
      await step('cover', () async {
        final src = File(path.join(entry.entryDirPath, PathUtils.coverName));
        if (!src.existsSync()) return null;
        await src.copy(path.join(folder, coverName));
        return coverName;
      });
    }

    if (Pref.dlSaveDanmakuXml || Pref.dlSaveDanmakuAss) {
      await step('danmaku', () async {
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
      await step('subtitles', () => _subtitles(entry, folder, base));
    }

    if (Pref.dlSaveComments) {
      await step('comments', () => _comments(entry, folder, base));
    }
    return written;
  }

  // ------------------------------------------------------------ subtitles

  static Future<List<String>> _subtitles(
    BiliDownloadEntryInfo entry,
    String folder,
    String base,
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
    for (final s in subtitles) {
      final srt = await VideoHttp.getSubtitles(s.url, format: .srt);
      if (srt == null) continue;
      final name = '$base.${_safe(s.lan)}.srt';
      await File(path.join(folder, name)).writeAsString(srt);
      written.add(name);
    }
    return written;
  }

  // ------------------------------------------------------------- comments

  static Future<String> _comments(
    BiliDownloadEntryInfo entry,
    String folder,
    String base,
  ) async {
    final maxRoots = Pref.dlCommentCount;
    final maxReplies = Pref.dlReplyCount;
    // bangumi episodes are commented on by aid as well
    final oid = entry.avid;
    final roots = <ReplyInfo>[];
    Int64? cursorNext;
    while (roots.length < maxRoots) {
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
      roots.addAll(page.replies);
      if (page.cursor.isEnd || page.replies.isEmpty) break;
      cursorNext = page.cursor.next;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (roots.length > maxRoots) roots.removeRange(maxRoots, roots.length);

    final items = <Map<String, Object?>>[];
    for (final root in roots) {
      var replies = root.replies.toList();
      final wanted = math.min(maxReplies, root.count.toInt());
      if (replies.length < wanted) {
        replies = await _replies(oid, root.id.toInt(), wanted);
      }
      items.add(
        replyToJson(root)
          ..['replies'] = [
            for (final r in replies.take(maxReplies)) replyToJson(r),
          ],
      );
    }

    final json = {
      'format': 'librepili-comments-1',
      'oid': oid,
      'bvid': entry.bvid,
      'title': entry.showTitle,
      'sort': 'hot',
      'fetchedAt': DateTime.now().toIso8601String(),
      'count': items.length,
      'comments': items,
    };
    await File(path.join(folder, '$base$commentsSuffix')).writeAsString(
      const JsonEncoder.withIndent(' ').convert(json),
    );
    return '${items.length} comments';
  }

  static Future<List<ReplyInfo>> _replies(int oid, int root, int wanted) async {
    final out = <ReplyInfo>[];
    String? offset;
    while (out.length < wanted) {
      await Future.delayed(const Duration(milliseconds: 200));
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

  static Map<String, Object?> replyToJson(ReplyInfo r) => {
    'rpid': r.id.toInt(),
    'mid': r.mid.toInt(),
    'uname': r.member.name,
    'avatar': r.member.face,
    'content': r.content.message,
    'ctime': r.ctime.toInt(),
    'like': r.like.toInt(),
    'replyCount': r.count.toInt(),
  };

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
