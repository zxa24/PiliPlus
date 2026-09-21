import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps one URL per host, in order', () {
    expect(
      VideoUtils.cdnCandidates([
        'https://upos-sz-estghw.bilivideo.com/a.m4s?x=1',
        'https://upos-sz-mirrorcos.bilivideo.com/a.m4s?x=2',
        'https://upos-sz-estghw.bilivideo.com/a.m4s?x=3',
      ]),
      [
        'https://upos-sz-estghw.bilivideo.com/a.m4s?x=1',
        'https://upos-sz-mirrorcos.bilivideo.com/a.m4s?x=2',
      ],
    );
  });

  test('drops empty and unparseable entries', () {
    expect(
      VideoUtils.cdnCandidates([
        '',
        'not a url',
        'https://cdn.example.com/a.m4s',
      ]),
      ['https://cdn.example.com/a.m4s'],
    );
  });

  test('an empty list yields nothing to fall back to', () {
    expect(VideoUtils.cdnCandidates(const []), isEmpty);
  });

  test('a single host yields a single candidate', () {
    expect(
      VideoUtils.cdnCandidates([
        'https://one.example.com/a?e=1',
        'https://one.example.com/a?e=2',
      ]),
      hasLength(1),
    );
  });
}
