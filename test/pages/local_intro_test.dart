import 'dart:convert';

import 'package:PiliPlus/pages/video/introduction/local/local_intro.dart';
import 'package:PiliPlus/services/download/download_progress.dart';
import 'package:flutter_test/flutter_test.dart';

/// The intro saved with a download (`<base>.intro.json`), read back for the
/// offline page.
void main() {
  test('read with the online models, avatars by their URL', () {
    final intro = LocalIntro.parse({
      'format': 'librepili-intro-1',
      'fetchedAt': '2026-10-16T12:00:00.000',
      'view': {
        'bvid': 'BV1xx411c7mD',
        'title': '标题',
        'pubdate': 1700000000,
        'owner': {'mid': 1, 'name': 'UP'},
        'stat': {'view': 12345, 'danmaku': 6, 'like': 7, 'coin': 8},
        'desc_v2': [
          {'raw_text': '看 01:23', 'type': 1, 'biz_id': 0},
        ],
      },
      'tags': [
        {'tag_id': 3, 'tag_name': '知识', 'tag_type': 'old_channel'},
      ],
      'card': {
        'card': {'mid': '1', 'name': 'UP', 'face': 'https://i0/face.jpg'},
        'follower': 1000,
        'archive_count': 20,
      },
      'faces': {
        'https://i0/face.jpg': base64Encode([1, 2, 3]),
      },
    })!;
    expect(intro.view.title, '标题');
    expect(intro.view.stat?.view, 12345);
    expect(intro.view.descV2?.single.rawText, '看 01:23');
    expect(intro.tags.single.tagName, '知识');
    expect(intro.card?.follower, 1000);
    expect(intro.face(intro.card?.card?.face), [1, 2, 3]);
    expect(intro.face('https://elsewhere'), isNull);
    expect(intro.fetchedAt, DateTime(2026, 10, 16, 12));
  });

  test('a video with staff has no card', () {
    final intro = LocalIntro.parse({
      'format': 'librepili-intro-1',
      'view': {
        'title': 't',
        'staff': [
          {'mid': 1, 'name': 'a', 'title': 'UP主', 'face': 'u'},
        ],
      },
    })!;
    expect(intro.card, isNull);
    expect(intro.tags, isEmpty);
    expect(intro.view.staff?.single.name, 'a');
    expect(intro.fetchedAt, isNull);
  });

  test('anything else is not an intro', () {
    expect(LocalIntro.parse(null), isNull);
    expect(LocalIntro.parse({'format': 'librepili-comments-1'}), isNull);
    expect(LocalIntro.parse({'format': 'librepili-intro-1'}), isNull);
  });

  test('the intro is one step of the extras when asked for', () {
    expect(
      DownloadProgress.extrasPlan(
        intro: true,
        cover: false,
        danmaku: false,
        subtitles: false,
        comments: 0,
      ),
      {DownloadProgress.stepIntro: 1},
    );
    expect(
      DownloadProgress.extrasPlan(
        cover: false,
        danmaku: false,
        subtitles: false,
        comments: 0,
      ),
      isEmpty,
    );
  });
}
