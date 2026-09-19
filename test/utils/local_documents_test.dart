import 'package:PiliPlus/services/local_documents.dart';
import 'package:PiliPlus/services/local_player.dart';
import 'package:flutter_test/flutter_test.dart';

LocalDocument _f(String name, [int size = 1]) =>
    LocalDocument(name: name, uri: 'content://t/$name', size: size);

LocalDocument _d(String name) => LocalDocument(
  name: name,
  uri: 'content://t/$name',
  isDir: true,
  docId: 'id/$name',
);

LocalFolderMatch? _match(List<LocalDocument> children) =>
    LocalDocuments.match(children, isVideo: LocalPlayer.isVideo);

void main() {
  group('LocalDocuments.match', () {
    test('LibrePili export folder: video and all its side files', () {
      final m = _match([
        _f('lptest.mp4', 50000000),
        _f('lptest.danmaku.xml'),
        _f('lptest.danmaku.ass'),
        _f('lptest.zh-CN.srt'),
        _f('lptest.en-US.srt'),
        _f('lptest.comments.json'),
        _f('librepili.json'),
        _f('cover.jpg'),
        _d('comments_images'),
        _f('notes.txt'),
      ])!;
      expect(m.video.name, 'lptest.mp4');
      expect(m.sideFiles.map((e) => e.name).toSet(), {
        'lptest.danmaku.xml',
        'lptest.zh-CN.srt',
        'lptest.en-US.srt',
        'lptest.comments.json',
        'librepili.json',
        'cover.jpg',
      });
      expect(m.imagesDir?.docId, 'id/comments_images');
    });

    test('other tools: <base>.xml danmaku, no comments -> no images dir', () {
      final m = _match([
        _f('clip.mkv', 10),
        _f('clip.xml'),
        _d('comments_images'),
      ])!;
      expect(m.video.name, 'clip.mkv');
      expect(m.sideFiles.map((e) => e.name), ['clip.xml']);
      expect(m.imagesDir, isNull);
    });

    test('largest video wins; side files of other videos are ignored', () {
      final m = _match([
        _f('trailer.mp4', 10),
        _f('movie.MKV', 1000),
        _f('trailer.zh.srt'),
        _f('movie.zh.srt'),
      ])!;
      expect(m.video.name, 'movie.MKV');
      expect(m.sideFiles.map((e) => e.name), ['movie.zh.srt']);
    });

    test('provider names cannot escape the cache folder', () {
      expect(LocalDocument.safeName('a/b.mp4'), 'a_b.mp4');
      expect(LocalDocument.safeName(r'..\x.srt'), '.._x.srt');
      expect(LocalDocument.safeName('..'), '_');
      expect(LocalDocument.safeName('.'), '_');
      expect(LocalDocument.safeName(''), '_');
      expect(
        LocalDocument.fromMap({'name': '../evil', 'uri': 'content://x'}).name,
        '.._evil',
      );
    });

    test('no video, or only a folder named like one', () {
      expect(_match([_f('a.txt'), _d('b.mp4')]), isNull);
      expect(_match(const []), isNull);
    });
  });
}
