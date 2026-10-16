import 'dart:convert';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:fixnum/fixnum.dart';
import 'package:path/path.dart' as path;

/// A comment saved with a download, and the replies saved with it.
class LocalComment {
  const LocalComment(this.root, this.replies);

  /// As bilibili sent it in the list, with the few replies shown under it.
  final ReplyInfo root;

  /// Those fetched for it when it was saved (up to 每条评论保存回复数).
  final List<ReplyInfo> replies;
}

/// LibrePili: the comments saved with a download (`<base>.comments.json`,
/// format 2: DownloadExtras.replyToJson), as the online list has them —
/// each as bilibili sent it, so the online comment's own widget shows it.
///
/// Every image in them points at its saved copy, by absolute path
/// (ImageUtils.isLocalFile), or at nothing: avatar pendants, fan cards and
/// link icons were not saved, and are dropped rather than fetched.
class LocalComments {
  const LocalComments({
    required this.comments,
    required this.upMid,
    required this.fetchedAt,
  });

  final List<LocalComment> comments;
  final Int64? upMid;
  final DateTime? fetchedAt;

  /// Null for a file of format 1, which has the plain words only.
  static LocalComments? parse(Map<String, dynamic> json, String dir) {
    final list = (json['comments'] as List?)?.cast<Map>() ?? const [];
    if (list.isEmpty || list.any((c) => c['pb'] is! String)) return null;
    return LocalComments(
      comments: [
        for (final c in list)
          LocalComment(_restore(c, dir), [
            for (final r in ((c['replies'] as List?) ?? const []).cast<Map>())
              if (r['pb'] is String) _restore(r, dir),
          ]),
      ],
      upMid: switch (json['upMid']) {
        final int mid => Int64(mid),
        _ => null,
      },
      fetchedAt: DateTime.tryParse('${json['fetchedAt']}'),
    );
  }

  static ReplyInfo _restore(Map saved, String dir) {
    final files = ((saved['files'] as Map?) ?? const {}).cast<String, String>();
    final reply = ReplyInfo.fromBuffer(base64Decode(saved['pb'] as String));
    localize(
      reply,
      (url) => switch (files[url]) {
        final rel? => path.join(dir, rel),
        _ => '',
      },
    );
    return reply;
  }

  /// Points [reply]'s images, and those of the replies under it, at what
  /// [local] gives for each URL ('' for none).
  static void localize(ReplyInfo reply, String Function(String url) local) {
    // a message not sent is a frozen default: only those there are changed
    if (reply.hasMember()) {
      final member = reply.member;
      if (member.face.isNotEmpty) member.face = local(member.face);
      member.clearGarbPendantImage();
    }
    if (reply.hasMemberV2()) reply.memberV2.clearGarb();
    for (final p in reply.content.pictures) {
      p.imgSrc = local(p.imgSrc);
    }
    for (final e in reply.content.emotes.values) {
      e
        ..url = local(e.url)
        ..clearWebpUrl()
        ..clearGifUrl();
    }
    for (final u in reply.content.urls.values) {
      u.clearPrefixIcon();
    }
    for (final r in reply.replies) {
      localize(r, local);
    }
  }
}
