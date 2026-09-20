import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/utils/mp4_remux.dart';
import 'package:flutter_test/flutter_test.dart';

/// Writes bits MSB first, with Exp-Golomb helpers (for building an SPS).
class _Bits {
  final _out = <int>[];
  int _cur = 0;
  int _n = 0;

  void bit(int b) {
    _cur = (_cur << 1) | (b & 1);
    if (++_n == 8) {
      _out.add(_cur);
      _cur = 0;
      _n = 0;
    }
  }

  void bits(int v, int n) {
    for (var i = n - 1; i >= 0; i--) {
      bit((v >> i) & 1);
    }
  }

  void ue(int v) {
    final x = v + 1;
    final len = x.bitLength;
    bits(0, len - 1);
    bits(x, len);
  }

  List<int> rbsp() {
    bit(1); // rbsp_stop_one_bit
    while (_n != 0) {
      bit(0);
    }
    return _out;
  }
}

/// Baseline SPS for [widthMbs] x [heightMbs] macroblocks, optional bottom
/// crop (in crop units).
List<int> _sps(int widthMbs, int heightMbs, {int cropBottom = 0}) {
  final b = _Bits()
    ..bits(66, 8) // profile_idc baseline
    ..bits(0, 8) // constraint flags
    ..bits(30, 8) // level
    ..ue(0) // sps id
    ..ue(0) // log2_max_frame_num_minus4
    ..ue(2) // pic_order_cnt_type
    ..ue(1) // max_num_ref_frames
    ..bit(0) // gaps
    ..ue(widthMbs - 1)
    ..ue(heightMbs - 1)
    ..bit(1) // frame_mbs_only
    ..bit(1); // direct_8x8_inference
  if (cropBottom > 0) {
    b
      ..bit(1)
      ..ue(0)
      ..ue(0)
      ..ue(0)
      ..ue(cropBottom);
  } else {
    b.bit(0);
  }
  b.bit(0); // vui
  return [0x67, ...b.rbsp()];
}

List<int> _avcC(List<int> sps) => [
  1, sps[1], sps[2], sps[3], 0xFF, 0xE1, //
  sps.length >> 8, sps.length & 0xFF, ...sps,
  1, 0, 4, 0x68, 0xCE, 0x38, 0x80, // one PPS
];

// AAC LC, 44100 Hz, stereo
const _asc = [0x12, 0x10];

class _Flv {
  final _b = BytesBuilder()
    ..add('FLV'.codeUnits)
    ..add([1, 5, 0, 0, 0, 9, 0, 0, 0, 0]);

  void tag(int type, int ts, List<int> data) {
    final n = data.length;
    _b
      ..add([type, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF])
      ..add([ts >> 16 & 0xFF, ts >> 8 & 0xFF, ts & 0xFF, ts >> 24 & 0xFF])
      ..add([0, 0, 0])
      ..add(data);
    final size = n + 11;
    _b.add([
      size >> 24 & 0xFF,
      size >> 16 & 0xFF,
      size >> 8 & 0xFF,
      size & 0xFF,
    ]);
  }

  void avcHeader(List<int> avcC) => tag(9, 0, [0x17, 0, 0, 0, 0, ...avcC]);

  void video(int ts, List<int> payload, {bool key = false, int cts = 0}) =>
      tag(9, ts, [
        key ? 0x17 : 0x27,
        1,
        cts >> 16 & 0xFF,
        cts >> 8 & 0xFF,
        cts & 0xFF,
        ...payload,
      ]);

  void aacHeader() => tag(8, 0, [0xAF, 0, ..._asc]);

  void audio(int ts, List<int> payload) => tag(8, ts, [0xAF, 1, ...payload]);

  // script tag (onMetaData), ignored by the demuxer
  void script() => tag(18, 0, [2, 0, 10, ...'onMetaData'.codeUnits]);

  Uint8List get bytes => _b.toBytes();
}

/// An AVCC sample: 4-byte length + NAL unit filled with [fill].
List<int> _nal(int size, int fill) => [
  0, 0, 0, size + 1, 0x65, //
  ...List.filled(size, fill),
];

int _u32(Uint8List b, int i) => ByteData.sublistView(b).getUint32(i);

/// Top-level MP4 boxes as (type, offset, size).
List<(String, int, int)> _boxes(Uint8List b) {
  final out = <(String, int, int)>[];
  var p = 0;
  while (p + 8 <= b.length) {
    final size = _u32(b, p);
    out.add((String.fromCharCodes(b, p + 4, p + 8), p, size));
    p += size;
  }
  return out;
}

int _indexOf(Uint8List hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

bool _contains(Uint8List hay, List<int> needle) => _indexOf(hay, needle) != -1;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('flv_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  String write(String name, Uint8List bytes) {
    final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return f.path;
  }

  Uint8List basicFlv() {
    final flv = _Flv()
      ..script()
      ..avcHeader(_avcC(_sps(20, 15))) // 320x240
      ..aacHeader()
      ..video(0, _nal(100, 1), key: true)
      ..audio(0, List.filled(30, 7))
      ..audio(23, List.filled(31, 8))
      ..video(40, _nal(50, 2), cts: 80)
      ..audio(46, List.filled(32, 9))
      ..video(80, _nal(60, 3));
    return flv.bytes;
  }

  test('demuxes H.264 + AAC samples, timing and sync flags', () {
    final tracks = Mp4Remuxer.debugFlvTracks([write('a.flv', basicFlv())]);
    expect(tracks, hasLength(2));

    final v = tracks[0];
    expect(v['type'], 'avc1');
    expect(v['timescale'], 1000);
    expect(v['sizes'], [105, 55, 65]); // payload after the 5-byte tag header
    expect(v['durations'], [40, 40, 40]);
    expect(v['ctos'], [0, 80, 0]);
    expect(v['syncs'], [true, false, false]);
    final tail = v['tkhdTail']! as Uint8List;
    expect(_u32(tail, tail.length - 8) >> 16, 320);
    expect(_u32(tail, tail.length - 4) >> 16, 240);
    expect(_contains(v['stsd']! as Uint8List, 'avcC'.codeUnits), isTrue);

    final a = tracks[1];
    expect(a['type'], 'mp4a');
    expect(a['timescale'], 44100);
    expect(a['sizes'], [30, 31, 32]);
    // 23 ms steps in the 44100 Hz timescale
    expect((a['durations']! as List).first, 1014);
    expect(_contains(a['stsd']! as Uint8List, 'esds'.codeUnits), isTrue);
    expect(v['edits'], isEmpty);
    expect(a['edits'], isEmpty);
  });

  test('SPS frame cropping gives 1920x1080', () {
    final flv = _Flv()
      ..avcHeader(_avcC(_sps(120, 68, cropBottom: 4)))
      ..video(0, _nal(10, 1), key: true);
    final v = Mp4Remuxer.debugFlvTracks([write('c.flv', flv.bytes)]).single;
    final tail = v['tkhdTail']! as Uint8List;
    expect(_u32(tail, tail.length - 8) >> 16, 1920);
    expect(_u32(tail, tail.length - 4) >> 16, 1080);
  });

  test('joins segments in timeline order when timestamps restart', () {
    List<int> seg(int fill) {
      final flv = _Flv()
        ..avcHeader(_avcC(_sps(20, 15)))
        ..video(0, _nal(10, fill), key: true)
        ..video(40, _nal(10, fill))
        ..video(80, _nal(10, fill));
      return flv.bytes;
    }

    final v = Mp4Remuxer.debugFlvTracks([
      write('s1.flv', Uint8List.fromList(seg(1))),
      write('s2.flv', Uint8List.fromList(seg(2))),
    ]).single;
    expect(v['sizes'], hasLength(6));
    // second segment placed right after the first: no jump back, no gap
    expect(v['durations'], [40, 40, 40, 40, 40, 40]);
  });

  test('a later video start becomes an empty edit (A/V sync)', () {
    final flv = _Flv()
      ..avcHeader(_avcC(_sps(20, 15)))
      ..aacHeader()
      ..audio(0, List.filled(10, 1))
      ..audio(23, List.filled(10, 1))
      ..video(100, _nal(10, 1), key: true)
      ..video(140, _nal(10, 1));
    final tracks = Mp4Remuxer.debugFlvTracks([write('e.flv', flv.bytes)]);
    expect(tracks[0]['edits'], [
      [100, -1],
      [0, 0],
    ]);
    expect(tracks[1]['edits'], isEmpty);
  });

  test('unsupported codecs throw UnsupportedError', () {
    final h263 = _Flv()..tag(9, 0, [0x12, 1, 2, 3]);
    expect(
      () => Mp4Remuxer.debugFlvTracks([write('h.flv', h263.bytes)]),
      throwsUnsupportedError,
    );
    final mp3 = _Flv()..tag(8, 0, [0x2F, 1, 2, 3]);
    expect(
      () => Mp4Remuxer.debugFlvTracks([write('m.flv', mp3.bytes)]),
      throwsUnsupportedError,
    );
  });

  test('remuxFlv writes a progressive mp4 holding every sample', () async {
    final input = write('in.flv', basicFlv());
    final output = '${dir.path}/out.mp4';
    expect(Mp4Remuxer.isFlv(input), isTrue);
    await Mp4Remuxer.remuxFlv(inputs: [input], output: output);
    final mp4 = File(output).readAsBytesSync();
    expect(Mp4Remuxer.isMp4(output), isTrue);

    final boxes = _boxes(mp4);
    expect(boxes.map((e) => e.$1), ['ftyp', 'moov', 'mdat']);
    final (_, mdatAt, mdatSize) = boxes[2];
    // video 105 + 55 + 65, audio 30 + 31 + 32
    expect(mdatSize - 8, 105 + 55 + 65 + 30 + 31 + 32);
    final mdat = Uint8List.sublistView(mp4, mdatAt + 8, mdatAt + mdatSize);
    expect(_contains(mdat, _nal(100, 1)), isTrue);
    expect(_contains(mdat, List.filled(32, 9)), isTrue);

    final moov = Uint8List.sublistView(
      mp4,
      boxes[1].$2,
      boxes[1].$2 + boxes[1].$3,
    );
    for (final box in ['avcC', 'esds', 'ctts', 'stss', 'stco']) {
      expect(_contains(moov, box.codeUnits), isTrue, reason: box);
    }
    expect(File('$output.part').existsSync(), isFalse);
  });

  group('joinMp4 (multi-segment progressive MP4)', () {
    /// A progressive MP4 segment (H.264 + AAC), built via remuxFlv.
    Future<String> mp4Segment(String name, int fill, {List<int>? sps}) async {
      final flv = _Flv()
        ..avcHeader(_avcC(sps ?? _sps(20, 15)))
        ..aacHeader()
        ..video(0, _nal(100, fill), key: true)
        ..audio(0, List.filled(30, fill))
        ..audio(23, List.filled(31, fill))
        ..video(40, _nal(50, fill), cts: 80)
        ..audio(46, List.filled(32, fill))
        ..video(80, _nal(60, fill));
      final out = '${dir.path}/$name.mp4';
      await Mp4Remuxer.remuxFlv(
        inputs: [write('$name.flv', flv.bytes)],
        output: out,
      );
      return out;
    }

    test('reads a progressive mp4 back sample for sample', () async {
      final seg = await mp4Segment('one', 1);
      final tracks = Mp4Remuxer.debugMp4JoinTracks([seg]);
      expect(tracks.map((t) => t['type']), ['avc1', 'mp4a']);
      expect(tracks[0]['sizes'], [105, 55, 65]);
      expect(tracks[0]['durations'], [40, 40, 40]);
      expect(tracks[0]['ctos'], [0, 80, 0]);
      expect(tracks[0]['syncs'], [true, false, false]);
      expect(tracks[1]['sizes'], [30, 31, 32]);
    });

    test('joins segments in timeline order into one mp4', () async {
      final s1 = await mp4Segment('s1', 1);
      final s2 = await mp4Segment('s2', 2);
      final output = '${dir.path}/joined.mp4';
      await Mp4Remuxer.joinMp4(inputs: [s1, s2], output: output);

      final tracks = Mp4Remuxer.debugMp4JoinTracks([output]);
      final v = tracks[0];
      final a = tracks[1];
      expect(v['sizes'], [105, 55, 65, 105, 55, 65]);
      expect(v['durations'], [40, 40, 40, 40, 40, 40]);
      expect(v['ctos'], [0, 80, 0, 0, 80, 0]);
      expect(v['syncs'], [true, false, false, true, false, false]);
      expect(a['sizes'], [30, 31, 32, 30, 31, 32]);
      // the second segment's audio starts where its video does (120 ms)
      final audioFirst = (a['durations']! as List<int>).take(3);
      expect(audioFirst.reduce((x, y) => x + y), 44100 * 120 ~/ 1000);

      final mp4 = File(output).readAsBytesSync();
      final boxes = _boxes(mp4);
      expect(boxes.map((e) => e.$1), ['ftyp', 'moov', 'mdat']);
      final (_, at, size) = boxes[2];
      final mdat = Uint8List.sublistView(mp4, at + 8, at + size);
      expect(size - 8, 2 * (105 + 55 + 65 + 30 + 31 + 32));
      // segment 1's samples come before segment 2's
      final first = _indexOf(mdat, _nal(100, 1));
      final second = _indexOf(mdat, _nal(100, 2));
      expect(first, isNot(-1));
      expect(second, greaterThan(first));
    });

    test('joined segments: every sample lies where its table says', () async {
      final s1 = await mp4Segment('p1', 1);
      final s2 = await mp4Segment('p2', 2);
      final output = '${dir.path}/placed.mp4';
      await Mp4Remuxer.joinMp4(inputs: [s1, s2], output: output);
      final mp4 = File(output).readAsBytesSync();
      final tracks = Mp4Remuxer.debugMp4JoinTracks([output]);

      // the sample the segment built, per track, in timeline order
      final expected = {
        0: [
          for (final fill in [1, 2]) ...[
            _nal(100, fill),
            _nal(50, fill),
            _nal(60, fill),
          ],
        ],
        1: [
          for (final fill in [1, 2]) ...[
            List.filled(30, fill),
            List.filled(31, fill),
            List.filled(32, fill),
          ],
        ],
      };

      for (final ti in [0, 1]) {
        final t = tracks[ti];
        final sizes = t['sizes']! as List<int>;
        final counts = t['sampleCounts']! as List<int>;
        final offsets = t['chunkOffsets']! as List<int>;
        final want = expected[ti]!;

        expect(sizes, hasLength(want.length), reason: 'sample count (t$ti)');
        expect(
          counts.reduce((a, b) => a + b),
          want.length,
          reason: 'samples across chunks (t$ti)',
        );
        expect(offsets, hasLength(counts.length));

        // walk the chunks: every sample's bytes must be at chunk offset plus
        // the sizes of the samples before it in that chunk
        var s = 0;
        for (var ci = 0; ci < counts.length; ci++) {
          var at = offsets[ci];
          for (var k = 0; k < counts[ci]; k++, s++) {
            expect(
              sizes[s],
              want[s].length,
              reason: 'size of sample $s (t$ti)',
            );
            expect(
              mp4.sublist(at, at + sizes[s]),
              want[s],
              reason: 'bytes of sample $s (t$ti)',
            );
            at += sizes[s];
          }
        }
        expect(s, want.length);
      }

      // timing carried over for both segments
      expect(tracks[0]['durations'], [40, 40, 40, 40, 40, 40]);
      expect(tracks[0]['ctos'], [0, 80, 0, 0, 80, 0]);
      expect(tracks[0]['syncs'], [true, false, false, true, false, false]);
    });

    test('segments whose track sets differ are not joined', () async {
      final s1 = await mp4Segment('t1', 1);
      // video only: no aacHeader, no audio tags
      final videoOnly = _Flv()
        ..avcHeader(_avcC(_sps(20, 15)))
        ..video(0, _nal(100, 2), key: true)
        ..video(40, _nal(50, 2));
      final s2 = '${dir.path}/t2.mp4';
      await Mp4Remuxer.remuxFlv(
        inputs: [write('t2.flv', videoOnly.bytes)],
        output: s2,
      );
      expect(
        () => Mp4Remuxer.joinMp4(
          inputs: [s1, s2],
          output: '${dir.path}/never2.mp4',
        ),
        throwsUnsupportedError,
      );
    });

    test('differing codec configuration: one sample entry each', () async {
      final s1 = await mp4Segment('c1', 1);
      final s2 = await mp4Segment('c2', 2, sps: _sps(120, 68, cropBottom: 4));
      final s3 = await mp4Segment('c3', 3); // back to the first config
      final output = '${dir.path}/multi.mp4';
      await Mp4Remuxer.joinMp4(inputs: [s1, s2, s3], output: output);

      final v = Mp4Remuxer.debugMp4JoinTracks([output])[0];
      expect(v['sizes'], hasLength(9));
      // stsc: segment 2's chunks use entry 2, segment 3 reuses entry 1
      final desc = v['descIndexes']! as List<int>;
      expect(desc.toSet(), {1, 2});
      expect(desc.first, 1);
      expect(desc.last, 1);
      expect(desc.where((d) => d == 2), isNotEmpty);
      final stsd = v['stsd']! as Uint8List;
      expect(_u32(stsd, 12), 2); // entry count
      // both SPS are present (320x240 and 1920x1088)
      expect(_contains(stsd, _sps(20, 15)), isTrue);
      expect(_contains(stsd, _sps(120, 68, cropBottom: 4)), isTrue);
    });

    test('differing audio sample rate: rescaled, second entry', () async {
      final s1 = await mp4Segment('r1', 1);
      final flv = _Flv()
        ..avcHeader(_avcC(_sps(20, 15)))
        ..tag(8, 0, [0xAF, 0, ..._asc48k])
        ..video(0, _nal(100, 2), key: true)
        ..audio(0, List.filled(30, 2))
        ..audio(23, List.filled(31, 2))
        ..video(40, _nal(50, 2))
        ..video(80, _nal(60, 2));
      final s2 = '${dir.path}/r2.mp4';
      await Mp4Remuxer.remuxFlv(
        inputs: [write('r2.flv', flv.bytes)],
        output: s2,
      );
      final output = '${dir.path}/rates.mp4';
      await Mp4Remuxer.joinMp4(inputs: [s1, s2], output: output);
      final a = Mp4Remuxer.debugMp4JoinTracks([output])[1];
      expect(a['timescale'], 44100);
      expect(_u32(a['stsd']! as Uint8List, 12), 2);
      expect(a['descIndexes'], contains(2));
      expect(a['sizes'], [30, 31, 32, 30, 31]);
      // 23 ms at 48 kHz converted to the 44.1 kHz timescale
      expect((a['durations']! as List<int>)[3], 1014);
    });

    test('a different codec is still not joined', () async {
      final s1 = await mp4Segment('k1', 1);
      final hevc = _Flv()
        ..tag(9, 0, [0x1C, 0, 0, 0, 0, ..._hvcC])
        ..tag(9, 0, [0x1C, 1, 0, 0, 0, ..._nal(10, 1)]);
      final s2 = '${dir.path}/k2.mp4';
      await Mp4Remuxer.remuxFlv(
        inputs: [write('k2.flv', hevc.bytes)],
        output: s2,
      );
      expect(
        () => Mp4Remuxer.joinMp4(
          inputs: [s1, s2],
          output: '${dir.path}/never.mp4',
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('codec configuration changes in FLV', () {
    test('mid-stream SPS change becomes a second sample entry', () {
      final flv = _Flv()
        ..avcHeader(_avcC(_sps(20, 15)))
        ..video(0, _nal(10, 1), key: true)
        ..video(40, _nal(10, 1))
        ..avcHeader(_avcC(_sps(120, 68, cropBottom: 4)))
        ..video(80, _nal(10, 2), key: true)
        ..avcHeader(_avcC(_sps(20, 15))) // back: reuses entry 1
        ..video(120, _nal(10, 3), key: true);
      final v = Mp4Remuxer.debugFlvTracks([write('mid.flv', flv.bytes)]).single;
      expect(v['sampleEntries'], 2);
      // samples are grouped into chunks, and a chunk holds one description:
      // 2 samples on entry 1, then one each on 2 and 1
      expect(v['descIndexes'], [1, 2, 1]);
      expect(v['sampleCounts'], [2, 1, 1]);
      final stsd = v['stsd']! as Uint8List;
      expect(_u32(stsd, 12), 2);
      // the track header keeps the first configuration's size
      final tail = v['tkhdTail']! as Uint8List;
      expect(_u32(tail, tail.length - 8) >> 16, 320);
    });

    test('segments with different AAC configs: two entries', () {
      final s1 = _Flv()
        ..aacHeader()
        ..audio(0, List.filled(10, 1))
        ..audio(23, List.filled(10, 1));
      final s2 = _Flv()
        ..tag(8, 0, [0xAF, 0, ..._asc48k])
        ..audio(0, List.filled(10, 2))
        ..audio(21, List.filled(10, 2));
      final a = Mp4Remuxer.debugFlvTracks([
        write('a1.flv', s1.bytes),
        write('a2.flv', s2.bytes),
      ]).single;
      expect(a['sampleEntries'], 2);
      // one chunk per segment: both its samples on that segment's entry
      expect(a['descIndexes'], [1, 2]);
      expect(a['sampleCounts'], [2, 2]);
      expect(a['timescale'], 44100);
    });

    test('remuxFlv writes both entries and the stsc indexes', () async {
      final flv = _Flv()
        ..avcHeader(_avcC(_sps(20, 15)))
        ..video(0, _nal(10, 1), key: true)
        ..avcHeader(_avcC(_sps(40, 30)))
        ..video(40, _nal(10, 2), key: true);
      final output = '${dir.path}/two.mp4';
      await Mp4Remuxer.remuxFlv(
        inputs: [write('two.flv', flv.bytes)],
        output: output,
      );
      // read back by the MP4 joiner: the stsc sample description indexes
      final v = Mp4Remuxer.debugMp4JoinTracks([output]).single;
      expect(v['sampleEntries'], 1); // single file: stsd kept verbatim
      expect(v['descIndexes'], [1, 2]);
      expect(_u32(v['stsd']! as Uint8List, 12), 2);
    });
  });

  group('HEVC in FLV', () {
    test('legacy codec id 12', () {
      final flv = _Flv()
        ..tag(9, 0, [0x1C, 0, 0, 0, 0, ..._hvcC])
        ..tag(9, 0, [0x1C, 1, 0, 0, 0, ..._nal(10, 1)])
        ..tag(9, 40, [0x2C, 1, 0, 0, 40, ..._nal(20, 2)]);
      final v = Mp4Remuxer.debugFlvTracks([write('h12.flv', flv.bytes)]).single;
      expect(v['type'], 'hvc1');
      expect(v['sizes'], [15, 25]);
      expect(v['ctos'], [0, 40]);
      expect(v['syncs'], [true, false]);
      expect(_contains(v['stsd']! as Uint8List, 'hvcC'.codeUnits), isTrue);
      expect(_contains(v['stsd']! as Uint8List, _hvcC), isTrue);
    });

    test('enhanced FLV (hvc1 FourCC): CodedFrames and CodedFramesX', () {
      final fourcc = 'hvc1'.codeUnits;
      final flv = _Flv()
        ..tag(9, 0, [0x90, ...fourcc, ..._hvcC]) // key, SequenceStart
        ..tag(9, 0, [0x91, ...fourcc, 0, 0, 80, ..._nal(10, 1)])
        ..tag(9, 40, [0xA3, ...fourcc, ..._nal(20, 2)]) // inter, X
        ..tag(9, 80, [0xA2, ...fourcc]); // SequenceEnd
      final v = Mp4Remuxer.debugFlvTracks([write('eh.flv', flv.bytes)]).single;
      expect(v['type'], 'hvc1');
      expect(v['sizes'], [15, 25]);
      expect(v['ctos'], [80, 0]);
      expect(v['syncs'], [true, false]);
    });

    test('enhanced FLV with an unmapped codec (av01) is unsupported', () {
      final flv = _Flv()..tag(9, 0, [0x90, ...'av01'.codeUnits, 1, 2, 3]);
      expect(
        () => Mp4Remuxer.debugFlvTracks([write('av1.flv', flv.bytes)]),
        throwsUnsupportedError,
      );
    });
  });

  group('checkSegment (damaged downloads)', () {
    test('complete FLV is fine, a cut-off tag is not', () {
      final bytes = basicFlv();
      expect(Mp4Remuxer.checkSegment(write('ok.flv', bytes)), isTrue);
      final cut = Uint8List.sublistView(bytes, 0, bytes.length - 20);
      expect(Mp4Remuxer.checkSegment(write('cut.flv', cut)), isFalse);
    });

    test('MP4 whose samples run past the end is not fine', () async {
      final input = write('m.flv', basicFlv());
      final output = '${dir.path}/m.mp4';
      await Mp4Remuxer.remuxFlv(inputs: [input], output: output);
      expect(Mp4Remuxer.checkSegment(output), isTrue);
      final bytes = File(output).readAsBytesSync();
      final cut = write(
        'mcut.mp4',
        Uint8List.sublistView(bytes, 0, bytes.length - 40),
      );
      expect(Mp4Remuxer.checkSegment(cut), isFalse);
    });

    test('FLV cut inside a tag header is not fine', () {
      final bytes = basicFlv();
      // whole file plus the first 6 bytes of another tag header
      final cut = Uint8List.fromList([...bytes, 9, 0, 0, 10, 0, 0]);
      expect(Mp4Remuxer.checkSegment(write('hdr.flv', cut)), isFalse);
    });

    test('MP4 ending in a cut 64-bit box header is not fine', () async {
      final input = write('b.flv', basicFlv());
      final output = '${dir.path}/b.mp4';
      await Mp4Remuxer.remuxFlv(inputs: [input], output: output);
      final bytes = File(output).readAsBytesSync();
      // size == 1 (64-bit size follows), but only 4 of its 8 bytes arrived
      final cut = write(
        'bcut.mp4',
        Uint8List.fromList([...bytes, 0, 0, 0, 1, ...'free'.codeUnits, 0, 0]),
      );
      expect(Mp4Remuxer.checkSegment(cut), isFalse);
    });

    test('a missing file is neither format (and does not throw)', () {
      final missing = '${dir.path}/gone.mp4';
      expect(Mp4Remuxer.isMp4(missing), isFalse);
      expect(Mp4Remuxer.isFlv(missing), isFalse);
    });
  });

  group('HEVC parameter sets', () {
    test('picture size comes from the SPS in the hvcC', () {
      final flv = _Flv()
        ..tag(9, 0, [0x1C, 0, 0, 0, 0, ..._hvcCWith(_spsHevc320)])
        ..tag(9, 0, [0x1C, 1, 0, 0, 0, ..._nal(10, 1)]);
      final v = Mp4Remuxer.debugFlvTracks([write('hs.flv', flv.bytes)]).single;
      final tail = v['tkhdTail']! as Uint8List;
      expect(_u32(tail, tail.length - 8) >> 16, 320);
      expect(_u32(tail, tail.length - 4) >> 16, 240);
    });

    test('a configuration switch carries its parameter sets in-band', () async {
      List<int> seg(int level, int fill) =>
          (_Flv()
                ..tag(9, 0, [
                  0x1C,
                  0,
                  0,
                  0,
                  0,
                  ..._hvcCWith(_spsHevc320, level: level),
                ])
                ..tag(9, 0, [0x1C, 1, 0, 0, 0, ..._nal(10, fill)])
                ..tag(9, 40, [0x2C, 1, 0, 0, 0, ..._nal(10, fill)]))
              .bytes;
      final output = '${dir.path}/switch.mp4';
      await Mp4Remuxer.remuxFlv(
        inputs: [
          write('h1.flv', Uint8List.fromList(seg(0x3c, 1))),
          write('h2.flv', Uint8List.fromList(seg(0x5d, 2))),
        ],
        output: output,
      );
      final v = Mp4Remuxer.debugMp4JoinTracks([output]).single;
      // hev1: parameter sets may also be in-band
      expect(v['type'], 'hev1');
      // one chunk per segment (2 samples each), on its own sample entry
      expect(v['descIndexes'], [1, 2]);
      expect(v['sampleCounts'], [2, 2]);
      // the first sample after the switch grew by one length-prefixed SPS
      final inband = [0, 0, 0, _spsHevc320.length, ..._spsHevc320];
      expect(v['sizes'], [15, 15, 15 + inband.length, 15]);
      final mp4 = File(output).readAsBytesSync();
      final at = _indexOf(mp4, [...inband, ..._nal(10, 2)]);
      expect(at, isNot(-1));
    });

    test('a single configuration stays hvc1 with nothing in-band', () async {
      final flv = _Flv()
        ..tag(9, 0, [0x1C, 0, 0, 0, 0, ..._hvcCWith(_spsHevc320)])
        ..tag(9, 0, [0x1C, 1, 0, 0, 0, ..._nal(10, 1)]);
      final output = '${dir.path}/one.mp4';
      await Mp4Remuxer.remuxFlv(
        inputs: [write('one.flv', flv.bytes)],
        output: output,
      );
      final v = Mp4Remuxer.debugMp4JoinTracks([output]).single;
      expect(v['type'], 'hvc1');
      expect(v['sizes'], [15]);
    });
  });
}

// AAC LC, 48000 Hz, stereo
const _asc48k = [0x11, 0x90];

/// A real x265 SPS (320x240, Main profile).
const _spsHevc320 = [
  0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, //
  0x03, 0x00, 0x00, 0x03, 0x00, 0x3c, 0xa0, 0x0a, 0x08, 0x0f, 0x16, 0x59,
  0x59, 0xa4, 0x93, 0x2b, 0xc0, 0x5a, 0x02, 0x00, 0x00, 0x03, 0x00, 0x02,
  0x00, 0x00, 0x03, 0x00, 0x32, 0x10,
];

/// An HEVCDecoderConfigurationRecord holding [sps] (4-byte NAL lengths);
/// [level] varies the record so two configurations differ.
List<int> _hvcCWith(List<int> sps, {int level = 0x3c}) => [
  1, 1, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, level, 0xf0, 0x00, 0xfc, //
  0xfd, 0xf8, 0xf8, 0x00, 0x00, 0x0f, // lengthSizeMinusOne = 3
  1, // one array: SPS
  0xa1, 0, 1, sps.length >> 8, sps.length & 0xFF, ...sps,
];

/// An HEVCDecoderConfigurationRecord stand-in (the demuxer copies it as is).
const _hvcC = [1, 1, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 0x5D, 0xF0];
