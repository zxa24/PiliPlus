import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/sponsor_block.dart';
import 'package:dio/dio.dart';
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

  group('a 404 on the prefix lookup', () {
    const server = 'https://sb.test';
    const bvid = 'BV1Yo3sz6EbG';
    late List<String> asked;

    /// Answers by URL: [byPrefix] for the prefix asked, [probe] for the
    /// fixed check (400: the malformed prefix refused, the lookup is there),
    /// 200 with no segments for the plain query.
    Future<Response> Function(String, Map<String, dynamic>?) answers({
      required int byPrefix,
      int probe = 400,
    }) => (url, query) async {
      asked.add(query == null ? url : '$url?videoID=${query['videoID']}');
      final status = query != null
          ? 200
          : url.endsWith('/${SponsorBlock.probePrefix}')
          ? probe
          : byPrefix;
      return Response(
        requestOptions: RequestOptions(path: url),
        statusCode: status,
        data: status == 200 ? const [] : 'Not Found',
      );
    };

    Future<LoadingState> look(
      String id,
      Future<Response> Function(String, Map<String, dynamic>?) get,
    ) => SponsorBlock.lookup(server: server, bvid: id, cid: 1, get: get);

    setUp(() {
      SponsorBlock.resetServers();
      asked = [];
    });

    // a BV id whose prefix is not the probe's
    const other = 'BV1other1111';

    test('the check asks a prefix that is not hex', () {
      expect(SponsorBlock.probePrefix, isNot(matches(RegExp(r'^[0-9a-f]+$'))));
    });

    test(
      'on a server that answered a prefix with 200, means no segments',
      () async {
        expect(SponsorBlock.hashPrefix(other), isNot(SponsorBlock.probePrefix));
        await look(bvid, answers(byPrefix: 200));
        asked.clear();
        final result = await look(other, answers(byPrefix: 404));
        expect(result, isA<Success>());
        expect(asked, [
          '$server/api/skipSegments/${SponsorBlock.hashPrefix(other)}',
        ]);
      },
    );

    test(
      'while support is unknown, asks the fixed prefix once, not the video',
      () async {
        final get = answers(byPrefix: 404);
        final first = await look(other, get);
        final second = await look(other, get);
        expect(first, isA<Success>());
        expect(second, isA<Success>());
        expect(asked.where((u) => u.contains('videoID')), isEmpty);
        expect(
          asked.where((u) => u.endsWith('/${SponsorBlock.probePrefix}')),
          hasLength(1),
        );
      },
    );

    test(
      'a server whose check answers 404 too is asked the plain way',
      () async {
        final result = await look(other, answers(byPrefix: 404, probe: 404));
        expect(result, isA<Success>());
        expect(asked.last, '$server/api/skipSegments?videoID=$other');
        asked.clear();
        await look(other, answers(byPrefix: 404, probe: 404));
        expect(asked, ['$server/api/skipSegments?videoID=$other']);
      },
    );

    test(
      'a failed check sends nothing of the video and is asked again',
      () async {
        for (final probe in [503, 200]) {
          final result = await look(
            other,
            answers(byPrefix: 404, probe: probe),
          );
          expect(result, isA<Error>());
          expect(asked.where((u) => u.contains('videoID')), isEmpty);
        }
        asked.clear();
        await look(other, answers(byPrefix: 404));
        expect(
          asked.where((u) => u.endsWith('/${SponsorBlock.probePrefix}')),
          hasLength(1),
        );
      },
    );

    test('a 400 on the real prefix is learnt the same way', () async {
      // known to have the lookup: nothing more is sent
      await look(bvid, answers(byPrefix: 200));
      asked.clear();
      expect(await look(other, answers(byPrefix: 400)), isA<Error>());
      expect(asked, [
        '$server/api/skipSegments/${SponsorBlock.hashPrefix(other)}',
      ]);

      // not known: the check says it has the lookup, nothing of the video
      SponsorBlock.resetServers();
      asked.clear();
      expect(await look(other, answers(byPrefix: 400)), isA<Error>());
      expect(asked.where((u) => u.contains('videoID')), isEmpty);

      // the check finds no such route: the plain query
      SponsorBlock.resetServers();
      asked.clear();
      await look(other, answers(byPrefix: 400, probe: 404));
      expect(asked.last, '$server/api/skipSegments?videoID=$other');

      // the check fails: nothing of the video, asked again next time
      SponsorBlock.resetServers();
      asked.clear();
      expect(
        await look(other, answers(byPrefix: 400, probe: 503)),
        isA<Error>(),
      );
      await look(other, answers(byPrefix: 400, probe: 503));
      expect(asked.where((u) => u.contains('videoID')), isEmpty);
      expect(
        asked.where((u) => u.endsWith('/${SponsorBlock.probePrefix}')),
        hasLength(2),
      );
    });
  });
}
