import 'package:PiliPlus/http/sponsor_block.dart';
import 'package:flutter_test/flutter_test.dart';

/// SponsorBlock segments looked up by a prefix of the video's hash
/// (oct-pass3-D6): the server is told four hex digits, and the video's own
/// segments are picked out of the answer here.
void main() {
  test('the prefix is the start of the SHA-256 of the BV id as sent', () {
    // the default server lists this video under 0000 (probed 2026-10-19)
    expect(SponsorBlock.hashPrefix('BV1Yo3sz6EbG'), '0000');
    expect(SponsorBlock.hashPrefix('BV1Yo3sz6EbG'), hasLength(4));
  });

  Map<String, dynamic> segment(Object? cid, String uuid) => {
    'cid': cid,
    'category': 'sponsor',
    'actionType': 'skip',
    'segment': [30, 45.979],
    'UUID': uuid,
    'videoDuration': 141.233,
    'locked': 0,
    'votes': 0,
    'description': '',
  };

  final answer = [
    {
      'videoID': 'BV1other1111',
      'segments': [segment('1', 'x')],
    },
    {
      'videoID': 'BV1Yo3sz6EbG',
      'segments': [
        segment('30808542485', 'a'),
        segment('999', 'b'),
        segment(null, 'c'),
        segment('', 'd'),
      ],
    },
  ];

  List<String>? uuids(Object? data, {String bvid = 'BV1Yo3sz6EbG'}) =>
      SponsorBlock.pickSegments(
        data,
        bvid: bvid,
        cid: 30808542485,
      )?.map((s) => s['UUID'] as String).toList();

  test("the video's entry, and of it the part's segments and those of no "
      'part', () {
    expect(uuids(answer), ['a', 'c', 'd']);
  });

  test('a video not in the answer has none', () {
    expect(uuids(answer, bvid: 'BV1absent111'), isEmpty);
    expect(uuids(const []), isEmpty);
  });

  test('an answer of another shape is not one', () {
    expect(uuids({'message': 'Not Found'}), isNull);
    expect(
      uuids([
        {'videoID': 'BV1Yo3sz6EbG', 'segments': 'none'},
      ]),
      isNull,
    );
  });

  test('a cid sent as a number matches too', () {
    expect(
      uuids([
        {
          'videoID': 'BV1Yo3sz6EbG',
          'segments': [segment(30808542485, 'n')],
        },
      ]),
      ['n'],
    );
  });
}
