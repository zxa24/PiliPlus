import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/models_new/member_card_info/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_tag/data.dart';
import 'package:flutter/foundation.dart';

/// LibrePili: a downloaded video's intro as it was when downloaded
/// (`<base>.intro.json`, written by DownloadExtras._intro): read with the
/// same models as the online page.
class LocalIntro {
  const LocalIntro({
    required this.view,
    required this.tags,
    required this.card,
    required this.faces,
    required this.fetchedAt,
  });

  final VideoDetailData view;
  final List<VideoTagItem> tags;

  /// The uploader with followers and videos; null for a video with staff.
  final MemberCardInfoData? card;

  /// Avatars by their URL.
  final Map<String, Uint8List> faces;
  final DateTime? fetchedAt;

  Uint8List? face(String? url) => url == null ? null : faces[url];

  /// Null when there is none, or it cannot be read.
  static Future<LocalIntro?> read(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      return parse(jsonDecode(await file.readAsString()));
    } catch (e) {
      if (kDebugMode) debugPrint('local intro $path: $e');
      return null;
    }
  }

  static LocalIntro? parse(Object? json) {
    if (json is! Map<String, dynamic> ||
        json['format'] != 'librepili-intro-1' ||
        json['view'] is! Map<String, dynamic>) {
      return null;
    }
    return LocalIntro(
      view: VideoDetailData.fromJson(json['view']),
      tags: [
        for (final t in (json['tags'] as List?) ?? const [])
          if (t is Map<String, dynamic>) VideoTagItem.fromJson(t),
      ],
      card: json['card'] is Map<String, dynamic>
          ? MemberCardInfoData.fromJson(json['card'])
          : null,
      faces: {
        for (final MapEntry(:key, :value)
            in ((json['faces'] as Map?) ?? const {}).entries)
          if (value is String) '$key': base64Decode(value),
      },
      fetchedAt: DateTime.tryParse('${json['fetchedAt']}'),
    );
  }
}
