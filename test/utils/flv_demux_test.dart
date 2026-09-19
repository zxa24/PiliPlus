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

    test('differing codec configuration is not joined', () async {
      final s1 = await mp4Segment('c1', 1);
      final s2 = await mp4Segment('c2', 2, sps: _sps(120, 68, cropBottom: 4));
      expect(
        () => Mp4Remuxer.joinMp4(
          inputs: [s1, s2],
          output: '${dir.path}/never.mp4',
        ),
        throwsUnsupportedError,
      );
    });
  });
}
