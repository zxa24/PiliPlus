import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

DanmakuElem _dm(
  int ms,
  String text, {
  int mode = 1,
  int size = 25,
  int color = 0xFFFFFF,
}) => DanmakuElem(
  id: Int64(1000 + ms),
  idStr: '${1000 + ms}',
  progress: ms,
  mode: mode,
  fontsize: size,
  color: color,
  midHash: 'abcd1234',
  content: text,
  ctime: Int64(1700000000),
  pool: 0,
  weight: 5,
);

void main() {
  group('danmakuToXml', () {
    test('header, p attribute order and escaping', () {
      final xml = DownloadExtras.danmakuToXml([
        _dm(1500, 'a<b>&"c"', color: 0xFF0000),
      ], cid: 42);
      expect(xml, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(xml, contains('<chatid>42</chatid>'));
      expect(xml, contains('<maxlimit>1</maxlimit>'));
      // time(s),mode,size,color,ctime,pool,midHash,dmid,weight
      expect(
        xml,
        contains(
          '<d p="1.50000,1,25,16711680,1700000000,0,abcd1234,2500,5">'
          'a&lt;b&gt;&amp;&quot;c&quot;</d>',
        ),
      );
      expect(xml.trimRight(), endsWith('</i>'));
    });
  });

  group('xmlToDanmaku', () {
    test('round-trips danmakuToXml', () {
      final src = [
        _dm(1500, 'a<b>&"c"', color: 0xFF0000, mode: 5, size: 18),
        _dm(62000, '第二条'),
      ];
      final back = DownloadExtras.xmlToDanmaku(
        DownloadExtras.danmakuToXml(src, cid: 1),
      );
      expect(back, hasLength(2));
      expect(back[0].progress, 1500);
      expect(back[0].mode, 5);
      expect(back[0].fontsize, 18);
      expect(back[0].color, 0xFF0000);
      expect(back[0].content, 'a<b>&"c"');
      expect(back[1].content, '第二条');
      expect(back[1].progress, 62000);
    });

    test('ignores malformed entries', () {
      final back = DownloadExtras.xmlToDanmaku(
        '<i><d p="x,1,25,1">bad</d><d p="1.0">short</d>'
        '<d p="2.5,1,25,16777215">ok</d></i>',
      );
      expect(back.map((e) => e.content), ['ok']);
    });

    test('other tools: extra attributes, single quotes, numeric entities', () {
      final back = DownloadExtras.xmlToDanmaku(
        '<i><d id="7" p=\'1.0,1,25,16777215\'>it&#39;s</d>'
        '<d p="2.0,1,25,16777215" user="u">&#x4E2D;&amp;lt;</d></i>',
      );
      expect(back.map((e) => e.content), ["it's", '中&lt;']);
      expect(back.map((e) => e.progress), [1000, 2000]);
    });
  });

  group('danmakuToAss', () {
    test('scroll line: time, move tag, color and escaping', () {
      final ass = DownloadExtras.danmakuToAss([
        _dm(61230, 'hi {x}', color: 0x112233),
      ], title: 't');
      expect(ass, contains('PlayResX: 1920'));
      expect(ass, contains('Style: Danmaku,'));
      final line = ass.split('\n').firstWhere((l) => l.startsWith('Dialogue:'));
      // 61.23s, 8s on screen
      expect(line, startsWith('Dialogue: 0,0:01:01.23,0:01:09.23,Danmaku,'));
      expect(line, contains(r'\move(1920,0,'));
      // RGB 0x112233 -> ASS &HBBGGRR&
      expect(line, contains(r'\c&H332211&'));
      // braces would start override blocks: must be replaced
      expect(line, endsWith('hi ｛x｝'));
    });

    test('top and bottom danmaku are centered and fixed for 4s', () {
      final ass = DownloadExtras.danmakuToAss([
        _dm(0, 'top', mode: 5),
        _dm(0, 'bottom', mode: 4),
      ]);
      final lines = ass
          .split('\n')
          .where((l) => l.startsWith('Dialogue:'))
          .toList();
      expect(lines, hasLength(2));
      expect(lines[0], contains(r'\an8\pos(960,0)'));
      expect(lines[0], contains('0:00:00.00,0:00:04.00'));
      expect(lines[1], contains(r'\an2\pos(960,1080)'));
    });

    test('overlapping scroll danmaku use different lanes', () {
      final ass = DownloadExtras.danmakuToAss([
        _dm(0, 'first long danmaku text'),
        _dm(100, 'second'),
      ]);
      final lines = ass
          .split('\n')
          .where((l) => l.startsWith('Dialogue:'))
          .toList();
      expect(lines[0], contains(r'\move(1920,0,'));
      expect(lines[1], isNot(contains(r'\move(1920,0,')));
    });

    test('scripted (mode 7) danmaku are skipped', () {
      final ass = DownloadExtras.danmakuToAss([_dm(0, '[x]', mode: 7)]);
      expect(ass.contains('Dialogue:'), isFalse);
    });
  });
}
