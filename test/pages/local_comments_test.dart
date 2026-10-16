import 'dart:convert';

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/pages/video/reply/local_comments.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// The comments saved with a download, read back as the online list has
/// them, every image pointing at its saved copy or at nothing.
void main() {
  String pb(ReplyInfo r) => base64Encode(r.writeToBuffer());

  ReplyInfo reply(int id, String face, {List<ReplyInfo> replies = const []}) =>
      ReplyInfo(
        id: Int64(id),
        member: Member(face: face, garbPendantImage: 'https://p/pendant.png'),
        content: Content(
          message: '好[笑]',
          emotes: {
            '[笑]': Emote(
              url: 'https://e/laugh.png',
              webpUrl: 'https://e/laugh.webp',
            ),
          }.entries,
          pictures: [Picture(imgSrc: 'https://i/pic.jpg')],
          urls: {
            'BV1': Url(title: '视频', prefixIcon: 'https://u/icon.png'),
          }.entries,
        ),
        replies: replies,
      );

  const dir = '/downloads/video';

  test('format 2: restored, images local or dropped', () {
    final preview = reply(2, 'https://f/preview.jpg');
    final saved = reply(3, 'https://f/reply.jpg');
    final local = LocalComments.parse({
      'format': 'librepili-comments-2',
      'upMid': 42,
      'fetchedAt': '2026-10-16T12:00:00.000',
      'comments': [
        {
          'uname': 'a',
          'pb': pb(reply(1, 'https://f/root.jpg', replies: [preview])),
          'files': {
            'https://f/root.jpg': 'comments_images/root.webp',
            'https://e/laugh.png': 'comments_images/laugh.png',
            'https://i/pic.jpg': 'comments_images/pic.jpg',
          },
          'replies': [
            {
              'pb': pb(saved),
              'files': {'https://f/reply.jpg': 'comments_images/reply.webp'},
            },
          ],
        },
      ],
    }, dir)!;
    expect(local.upMid, Int64(42));
    expect(local.fetchedAt, DateTime(2026, 10, 16, 12));
    final comment = local.comments.single;
    final root = comment.root;
    expect(root.id, Int64(1));
    expect(
      root.member.face,
      path.join(dir, 'comments_images/root.webp'),
    );
    expect(root.member.hasGarbPendantImage(), isFalse);
    final emote = root.content.emotes['[笑]']!;
    expect(emote.url, path.join(dir, 'comments_images/laugh.png'));
    expect(emote.hasWebpUrl(), isFalse);
    expect(
      root.content.pictures.single.imgSrc,
      path.join(dir, 'comments_images/pic.jpg'),
    );
    expect(root.content.urls['BV1']!.hasPrefixIcon(), isFalse);
    // the preview reply: its emote from the comment's files, no avatar saved
    final shown = root.replies.single;
    expect(shown.member.face, '');
    expect(
      shown.content.emotes['[笑]']!.url,
      path.join(dir, 'comments_images/laugh.png'),
    );
    // a saved reply: its own files; what is not among them, nothing
    final r = comment.replies.single;
    expect(r.member.face, path.join(dir, 'comments_images/reply.webp'));
    expect(r.content.emotes['[笑]']!.url, '');
    expect(r.content.pictures.single.imgSrc, '');
  });

  test('format 1 (plain words only) is left to the plain list', () {
    expect(
      LocalComments.parse({
        'format': 'librepili-comments-1',
        'comments': [
          {'uname': 'a', 'content': 'b'},
        ],
      }, dir),
      isNull,
    );
    expect(LocalComments.parse({'comments': []}, dir), isNull);
  });

  test('a path on the device is not a URL', () {
    expect(ImageUtils.isLocalFile(r'C:\Users\x\a.webp'), isTrue);
    expect(ImageUtils.isLocalFile('C:/Users/x/a.webp'), isTrue);
    expect(ImageUtils.isLocalFile('/storage/emulated/0/a.webp'), isTrue);
    expect(ImageUtils.isLocalFile('//i0.hdslb.com/bfs/face/a.jpg'), isFalse);
    expect(ImageUtils.isLocalFile('https://i0.hdslb.com/a.jpg'), isFalse);
    expect(ImageUtils.isLocalFile(''), isFalse);
    expect(ImageUtils.isLocalFile(null), isFalse);
  });
}
