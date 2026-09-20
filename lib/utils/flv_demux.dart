part of 'mp4_remux.dart';

/// LibrePili: pure-Dart FLV demuxer feeding [Mp4Remuxer]'s progressive MP4
/// writer, for the old single-URL (durl) downloads.
///
/// FLV AVC payloads are already length-prefixed NAL units and AAC payloads
/// raw frames, which is exactly what MP4 samples hold, so sample bytes are
/// never decoded: every sample becomes a chunk pointing into its FLV file and
/// is copied byte-for-byte. H.264 / HEVC video (legacy codec id 7 / 12, or
/// enhanced FLV with the `avc1` / `hvc1` FourCC) and AAC audio are
/// supported; a codec configuration that changes mid-stream or between
/// segments becomes another sample entry. Anything else throws
/// [UnsupportedError].
abstract final class _FlvDemuxer {
  /// A segment starting more than this before the end of what came earlier
  /// restarted its clock and is placed after it; a continuing segment starts
  /// within about a frame of that end.
  static const _restartToleranceMs = 100;

  /// [strict]: a tag cut off by the end of the file throws
  /// [FormatException] (a damaged download) instead of being dropped.
  static List<_Track> demux(List<String> inputs, {bool strict = false}) {
    final video = _FlvTrackBuilder(isVideo: true);
    final audio = _FlvTrackBuilder(isVideo: false);
    for (final input in inputs) {
      final raf = File(input).openSync();
      try {
        final r = _FileReader(raf);
        final header = r.read(0, 9);
        if (String.fromCharCodes(header, 0, 3) != 'FLV') {
          throw FormatException('not an FLV file: $input');
        }
        // header, then PreviousTagSize0
        var pos = ByteData.sublistView(header).getUint32(5) + 4;
        int? offset; // ms added to this segment's timestamps
        while (pos + 11 <= r.length) {
          final h = r.read(pos, 11);
          final type = h[0];
          final dataSize = (h[1] << 16) | (h[2] << 8) | h[3];
          final ts = ((h[7] << 24) | (h[4] << 16) | (h[5] << 8) | h[6])
              .toSigned(32);
          final dataPos = pos + 11;
          if (dataPos + dataSize > r.length) {
            if (strict) throw FormatException('truncated FLV tag in $input');
            break; // truncated last tag
          }
          pos = dataPos + dataSize + 4; // + PreviousTagSize
          final kind = type & 0x1F;
          if ((kind != 8 && kind != 9) || dataSize == 0) continue;
          if (type & 0x20 != 0) throw UnsupportedError('encrypted FLV');
          if (offset == null) {
            final end = max(video.endMs, audio.endMs);
            offset = end - ts > _restartToleranceMs ? end - ts : 0;
          }
          final head = r.read(dataPos, min(dataSize, 5));
          final time = ts + offset;
          if (kind == 9) {
            video.addVideoTag(input, dataPos, dataSize, head, time, r);
          } else {
            audio.addAudioTag(input, dataPos, dataSize, head, time, r);
          }
        }
        // a whole file ends exactly after the last PreviousTagSize; less
        // (a cut tag header or size field) means the transfer stopped early
        if (strict && pos != r.length) {
          throw FormatException('FLV cut off at $pos of ${r.length}: $input');
        }
      } finally {
        raf.closeSync();
      }
    }
    final starts = [
      for (final b in [video, audio])
        if (b.times.isNotEmpty) b.times.first,
    ];
    if (starts.isEmpty) throw const FormatException('no audio/video in FLV');
    final base = starts.reduce(min);
    final tracks = <_Track>[];
    for (final b in [video, audio]) {
      if (b.build(base) case final t?) tracks.add(t..index = tracks.length);
    }
    return tracks;
  }
}

class _FlvTrackBuilder {
  _FlvTrackBuilder({required this.isVideo});

  final bool isVideo;

  /// Video: 'avc1' or 'hvc1' (sample entry type); one codec per track.
  String? codec;

  /// AVCDecoderConfigurationRecord / HEVCDecoderConfigurationRecord /
  /// AudioSpecificConfig, each distinct one seen; [_current] is in use.
  final configs = <Uint8List>[];
  int _current = -1;

  // per sample, in decode order
  final configIndex = <int>[];
  final times = <int>[]; // ms
  final ctsMs = <int>[];
  final keys = <bool>[];
  final paths = <String>[];
  final offsets = <int>[];
  final sizes = <int>[];

  int get _defaultDurationMs => isVideo ? 40 : 23;

  int get _lastDurationMs => times.length < 2
      ? _defaultDurationMs
      : times.last - times[times.length - 2];

  /// Where the next sample of a following segment would start.
  int get endMs => times.isEmpty ? 0 : times.last + _lastDurationMs;

  void addVideoTag(
    String path,
    int dataPos,
    int dataSize,
    Uint8List head,
    int time,
    _FileReader r,
  ) {
    // bit 7: enhanced FLV (E-RTMP): frame type, packet type, FourCC
    if (head[0] & 0x80 != 0) {
      if (dataSize <= 5) return;
      final fourcc = String.fromCharCodes(head, 1, 5);
      _setCodec(switch (fourcc) {
        'avc1' || 'hvc1' => fourcc,
        _ => throw UnsupportedError('FLV video codec $fourcc'),
      });
      final key = (head[0] >> 4) & 0x07 == 1;
      switch (head[0] & 0x0F) {
        case 0: // SequenceStart: decoder configuration record
          _setConfig(r.read(dataPos + 5, dataSize - 5));
        case 1: // CodedFrames: composition time, then NAL units
          if (dataSize <= 8) return;
          final c = r.read(dataPos + 5, 3);
          final cts = ((c[0] << 16) | (c[1] << 8) | c[2]).toSigned(24);
          _add(path, dataPos + 8, dataSize - 8, time, cts, key);
        case 3: // CodedFramesX: NAL units, composition time 0
          _add(path, dataPos + 5, dataSize - 5, time, 0, key);
        case 2 || 4 || 7: // SequenceEnd / Metadata / ModEx: nothing to keep
          break;
        default: // multitrack / MPEG-2 TS config: no MP4 mapping here
          throw UnsupportedError('enhanced FLV packet type ${head[0] & 0x0F}');
      }
      return;
    }
    // legacy: codec id 7 = H.264, 12 = HEVC (the CDN convention in China)
    final codecId = head[0] & 0x0F;
    _setCodec(switch (codecId) {
      7 => 'avc1',
      12 => 'hvc1',
      _ => throw UnsupportedError('FLV video codec $codecId'),
    });
    if (dataSize <= 5) return;
    switch (head[1]) {
      case 0: // sequence header
        _setConfig(r.read(dataPos + 5, dataSize - 5));
      case 1: // NAL units
        final cts = ((head[2] << 16) | (head[3] << 8) | head[4]).toSigned(24);
        _add(path, dataPos + 5, dataSize - 5, time, cts, head[0] >> 4 == 1);
    }
  }

  void _setCodec(String c) {
    codec ??= c;
    // one track holds one codec (players switch configuration, not codec)
    if (codec != c) {
      throw UnsupportedError('FLV video codec changes ($codec -> $c)');
    }
  }

  void addAudioTag(
    String path,
    int dataPos,
    int dataSize,
    Uint8List head,
    int time,
    _FileReader r,
  ) {
    final format = head[0] >> 4;
    if (format != 10) {
      throw UnsupportedError('FLV audio codec $format (only AAC)');
    }
    if (dataSize <= 2) return;
    switch (head[1]) {
      case 0: // AudioSpecificConfig
        _setConfig(r.read(dataPos + 2, dataSize - 2));
      case 1: // raw frame
        _add(path, dataPos + 2, dataSize - 2, time, 0, true);
    }
  }

  /// Repeated at segment starts (same bytes: nothing changes); a different
  /// configuration (resolution / profile / sample rate change) becomes a
  /// new sample entry for the samples that follow.
  void _setConfig(Uint8List c) {
    for (var i = 0; i < configs.length; i++) {
      if (_sameBytes(configs[i], c)) {
        _current = i;
        return;
      }
    }
    configs.add(Uint8List.fromList(c));
    _current = configs.length - 1;
  }

  void _add(String path, int offset, int size, int time, int cts, bool key) {
    if (_current < 0) return; // undecodable before the sequence header
    if (times.isNotEmpty && time <= times.last) time = times.last + 1;
    configIndex.add(_current);
    times.add(time);
    ctsMs.add(cts);
    keys.add(key);
    paths.add(path);
    offsets.add(offset);
    sizes.add(size);
  }

  /// [baseMs]: earliest start of all tracks; a later start becomes an empty
  /// edit so audio and video stay in sync.
  _Track? build(int baseMs) {
    if (configs.isEmpty || sizes.isEmpty) return null;
    final config = configs.first;
    final t = _Track(paths.first)
      ..sourceMovieTimescale = 1000
      ..tkhdFlags = 0
      ..mdhdLanguage =
          Uint8List.fromList([0x55, 0xC4]) // und
      ..dinf = _box(
        'dinf',
        _box(
          'dref',
          (_W()
                ..u32(0)
                ..u32(1)
                ..bytes_(_box('url ', (_W()..u32(1)).bytes)))
              .bytes,
        ),
      );
    if (isVideo) {
      final (width, height) = _videoDimensions(config);
      t
        ..timescale = 1000
        ..sampleEntryType = codec!
        ..hdlr = _hdlr('vide', 'VideoHandler')
        ..mediaHeader = _box(
          'vmhd',
          (_W()
                ..u32(1)
                ..zeros(8))
              .bytes,
        )
        ..tkhdTail = _tkhdTail(0, width, height);
    } else {
      final (rate, _) = _aacFormat(config);
      t
        ..timescale = rate
        ..sampleEntryType = 'mp4a'
        ..hdlr = _hdlr('soun', 'SoundHandler')
        ..mediaHeader = _box('smhd', (_W()..zeros(8)).bytes)
        ..tkhdTail = _tkhdTail(0x0100, 0, 0);
    }
    final entries = [for (final c in configs) _sampleEntry(c)];
    t.stsd = _stsdOf(entries);
    if (entries.length > 1) t.sampleEntries = entries;

    final ts = t.timescale;
    final first = times.first;
    final dts = [for (final ms in times) _scale(ms - first, 1000, ts)];
    // Samples are grouped into chunks of about a second, the way the
    // fragmented-MP4 path does, so the sample tables stay small (one `stco`
    // entry per chunk, not per sample). FLV samples are payloads of separate
    // tags with the other track's tags in between, so a chunk lists its
    // samples' ranges one by one: what has to be contiguous is the chunk's
    // place in the *output* file, not in its source.
    final maxChunk = (Mp4Remuxer._maxChunkSeconds * ts).round();
    _Chunk? chunk;
    for (var i = 0; i < dts.length; i++) {
      final dur = i + 1 < dts.length
          ? dts[i + 1] - dts[i]
          : (i > 0
                ? dts[i] - dts[i - 1]
                : _scale(_defaultDurationMs, 1000, ts));
      final descIndex = configIndex[i] + 1;
      // a chunk holds one sample description and comes from one file
      if (chunk == null ||
          chunk.descIndex != descIndex ||
          chunk.sourcePath != paths[i] ||
          dts[i] - chunk.startDts >= maxChunk) {
        chunk = _Chunk(t, offsets[i], i, dts[i], paths[i])
          ..descIndex = descIndex
          ..ranges = <(int, int)>[];
        t.chunks.add(chunk);
      }
      chunk
        ..ranges!.add((offsets[i], sizes[i]))
        ..length += sizes[i]
        ..sampleCount += 1;
      t
        ..durations.add(dur)
        ..sizes.add(sizes[i])
        ..ctos.add(_scale(ctsMs[i], 1000, ts))
        ..syncs.add(keys[i]);
    }
    if (first > baseMs) {
      t.edits
        ..add(_EditEntry(first - baseMs, -1, 0x10000))
        ..add(_EditEntry(0, 0, 0x10000));
    }
    return t;
  }

  /// The sample entry for one codec configuration of this track.
  Uint8List _sampleEntry(Uint8List config) {
    if (isVideo) {
      final (width, height) = _videoDimensions(config);
      final hevc = codec == 'hvc1';
      return _box(
        codec!,
        (_W()
              ..zeros(6)
              ..u16(1) // data reference index
              ..zeros(16)
              ..u16(width)
              ..u16(height)
              ..u32(0x00480000) // 72 dpi
              ..u32(0x00480000)
              ..u32(0)
              ..u16(1) // frame count
              ..zeros(32) // compressor name
              ..u16(0x18) // depth
              ..u16(0xFFFF)
              ..bytes_(_box(hevc ? 'hvcC' : 'avcC', config)))
            .bytes,
      );
    }
    final (rate, channels) = _aacFormat(config);
    return _box(
      'mp4a',
      (_W()
            ..zeros(6)
            ..u16(1) // data reference index
            ..zeros(8)
            ..u16(channels)
            ..u16(16) // sample size
            ..zeros(4)
            ..u32(rate <= 0xFFFF ? rate << 16 : 0)
            ..bytes_(_esds(config)))
          .bytes,
    );
  }

  /// Picture size for the sample entry and track header; (0, 0) when it
  /// cannot be read.
  (int, int) _videoDimensions(Uint8List config) =>
      codec == 'hvc1' ? _hevcDimensions(config) : _avcDimensions(config);

  /// Conformance-window size from the first SPS of an HEVC configuration
  /// record (H.265 7.3.2.2.1); (0, 0) if it cannot be read.
  static (int, int) _hevcDimensions(Uint8List hvcC) {
    try {
      var p = 23;
      for (var a = 0; a < hvcC[22]; a++) {
        final type = hvcC[p] & 0x3F;
        final n = (hvcC[p + 1] << 8) | hvcC[p + 2];
        p += 3;
        for (var i = 0; i < n; i++) {
          final len = (hvcC[p] << 8) | hvcC[p + 1];
          if (type == 33) {
            return _hevcSpsDimensions(
              Uint8List.sublistView(hvcC, p + 2, p + 2 + len),
            );
          }
          p += 2 + len;
        }
      }
    } catch (_) {}
    return (0, 0);
  }

  static (int, int) _hevcSpsDimensions(Uint8List nal) {
    // skip sps_video_parameter_set_id (4 bits)
    final b = _BitReader(_rbsp(nal, 2))..bits(4);
    final maxSubLayersMinus1 = b.bits(3);
    b
      ..bit() // temporal_id_nesting
      ..bits(32) // general profile space / tier / idc + 24 compat bits
      ..bits(8) // rest of the compatibility flags
      ..bits(32) // source / constraint flags ...
      ..bits(16) // ... (48 bits in all)
      ..bits(8); // general_level_idc
    final profilePresent = <bool>[];
    final levelPresent = <bool>[];
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      profilePresent.add(b.bit() == 1);
      levelPresent.add(b.bit() == 1);
    }
    if (maxSubLayersMinus1 > 0) {
      for (var i = maxSubLayersMinus1; i < 8; i++) {
        b.bits(2);
      }
    }
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      if (profilePresent[i]) {
        b
          ..bits(32)
          ..bits(32)
          ..bits(24); // 88 bits
      }
      if (levelPresent[i]) b.bits(8);
    }
    b.ue(); // sps_seq_parameter_set_id
    final chroma = b.ue();
    final separate = chroma == 3 && b.bit() == 1;
    var width = b.ue();
    var height = b.ue();
    if (b.bit() == 1) {
      final left = b.ue();
      final right = b.ue();
      final top = b.ue();
      final bottom = b.ue();
      final subW = !separate && (chroma == 1 || chroma == 2) ? 2 : 1;
      final subH = !separate && chroma == 1 ? 2 : 1;
      width -= subW * (left + right);
      height -= subH * (top + bottom);
    }
    return (width, height);
  }

  /// RBSP of a NAL unit: without its [headerBytes] and the emulation
  /// prevention bytes (00 00 03).
  static Uint8List _rbsp(Uint8List nal, int headerBytes) {
    final rbsp = <int>[];
    var zeros = 0;
    for (var i = headerBytes; i < nal.length; i++) {
      final v = nal[i];
      if (zeros >= 2 && v == 3) {
        zeros = 0;
        continue;
      }
      zeros = v == 0 ? zeros + 1 : 0;
      rbsp.add(v);
    }
    return Uint8List.fromList(rbsp);
  }

  static Uint8List _tkhdTail(int volume, int width, int height) {
    final w = _W()
      ..zeros(8)
      ..u16(0) // layer
      ..u16(0) // alternate group
      ..u16(volume)
      ..u16(0)
      ..bytes_(_unityMatrix)
      ..u32(width << 16)
      ..u32(height << 16);
    return w.bytes;
  }

  static Uint8List _hdlr(String type, String name) => _box(
    'hdlr',
    (_W()
          ..u32(0)
          ..u32(0)
          ..fourcc(type)
          ..zeros(12)
          ..fourcc(name)
          ..u8(0))
        .bytes,
  );

  static Uint8List _esds(Uint8List asc) {
    Uint8List descriptor(int tag, Uint8List body) {
      final n = body.length;
      return (_W()
            ..u8(tag)
            ..u8(((n >> 21) & 0x7F) | 0x80)
            ..u8(((n >> 14) & 0x7F) | 0x80)
            ..u8(((n >> 7) & 0x7F) | 0x80)
            ..u8(n & 0x7F)
            ..bytes_(body))
          .bytes;
    }

    final decoderConfig = descriptor(
      4,
      (_W()
            ..u8(0x40) // MPEG-4 audio
            ..u8(0x15) // audio stream
            ..zeros(3) // buffer size
            ..u32(0) // max bitrate
            ..u32(0) // average bitrate
            ..bytes_(descriptor(5, asc)))
          .bytes,
    );
    final es = descriptor(
      3,
      (_W()
            ..u16(1) // ES id
            ..u8(0)
            ..bytes_(decoderConfig)
            ..bytes_(descriptor(6, Uint8List.fromList([2]))))
          .bytes,
    );
    return _box(
      'esds',
      (_W()
            ..u32(0)
            ..bytes_(es))
          .bytes,
    );
  }

  static const _aacRates = [
    96000, 88200, 64000, 48000, 44100, 32000, 24000, //
    22050, 16000, 12000, 11025, 8000, 7350,
  ];

  /// (sample rate, channel count) from an AudioSpecificConfig.
  static (int, int) _aacFormat(Uint8List asc) {
    final b = _BitReader(asc);
    if (b.bits(5) == 31) b.bits(6); // extended object type
    final index = b.bits(4);
    final int rate;
    if (index == 15) {
      rate = b.bits(24);
    } else if (index < _aacRates.length) {
      rate = _aacRates[index];
    } else {
      throw FormatException('bad AAC sampling index $index');
    }
    final channels = b.bits(4);
    return (rate, channels == 0 ? 2 : channels);
  }

  /// Coded picture size from the first SPS of an AVC configuration record;
  /// (0, 0) if it cannot be read (players then use the SPS themselves).
  static (int, int) _avcDimensions(Uint8List avcC) {
    try {
      if (avcC.length < 8 || avcC[5] & 0x1F == 0) return (0, 0);
      final len = (avcC[6] << 8) | avcC[7];
      return _spsDimensions(Uint8List.sublistView(avcC, 8, 8 + len));
    } catch (_) {
      return (0, 0);
    }
  }

  static const _highProfiles = {
    100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135, //
  };

  /// H.264 7.3.2.1.1 seq_parameter_set_data, as far as the picture size.
  static (int, int) _spsDimensions(Uint8List nal) {
    // drop the NAL header and emulation prevention bytes (00 00 03)
    final rbsp = <int>[];
    var zeros = 0;
    for (var i = 1; i < nal.length; i++) {
      final v = nal[i];
      if (zeros >= 2 && v == 3) {
        zeros = 0;
        continue;
      }
      zeros = v == 0 ? zeros + 1 : 0;
      rbsp.add(v);
    }
    final b = _BitReader(Uint8List.fromList(rbsp));
    final profile = b.bits(8);
    b
      ..bits(8) // constraint flags
      ..bits(8) // level
      ..ue(); // sps id
    var chromaFormat = 1;
    var separateColourPlane = false;
    if (_highProfiles.contains(profile)) {
      chromaFormat = b.ue();
      if (chromaFormat == 3) separateColourPlane = b.bit() == 1;
      b
        ..ue() // bit depth luma
        ..ue() // bit depth chroma
        ..bit(); // qpprime_y_zero_transform_bypass
      if (b.bit() == 1) {
        // scaling matrices: skip the lists
        for (var i = 0; i < (chromaFormat == 3 ? 12 : 8); i++) {
          if (b.bit() == 0) continue;
          final size = i < 6 ? 16 : 64;
          var last = 8;
          var next = 8;
          for (var j = 0; j < size; j++) {
            if (next != 0) next = (last + b.se() + 256) % 256;
            if (next != 0) last = next;
          }
        }
      }
    }
    b.ue(); // log2_max_frame_num_minus4
    final pocType = b.ue();
    if (pocType == 0) {
      b.ue();
    } else if (pocType == 1) {
      b
        ..bit()
        ..se()
        ..se();
      final n = b.ue();
      for (var i = 0; i < n; i++) {
        b.se();
      }
    }
    b
      ..ue() // max_num_ref_frames
      ..bit(); // gaps_in_frame_num_value_allowed
    final widthMbs = b.ue() + 1;
    final heightMapUnits = b.ue() + 1;
    final frameMbsOnly = b.bit();
    if (frameMbsOnly == 0) b.bit(); // mb_adaptive_frame_field
    b.bit(); // direct_8x8_inference
    var width = widthMbs * 16;
    var height = (2 - frameMbsOnly) * heightMapUnits * 16;
    if (b.bit() == 1) {
      final left = b.ue();
      final right = b.ue();
      final top = b.ue();
      final bottom = b.ue();
      final int cropX;
      final int cropY;
      if (chromaFormat == 0 || separateColourPlane) {
        cropX = 1;
        cropY = 2 - frameMbsOnly;
      } else {
        cropX = chromaFormat == 3 ? 1 : 2;
        cropY = (chromaFormat == 1 ? 2 : 1) * (2 - frameMbsOnly);
      }
      width -= cropX * (left + right);
      height -= cropY * (top + bottom);
    }
    return (width, height);
  }
}

/// Buffered synchronous reads (the demux runs inside `Isolate.run`).
class _FileReader {
  _FileReader(this.raf) : length = raf.lengthSync();

  static const _blockSize = 1 << 20;

  final RandomAccessFile raf;
  final int length;
  Uint8List _buf = Uint8List(0);
  int _bufPos = 0;

  Uint8List read(int pos, int n) {
    if (pos < _bufPos || pos + n > _bufPos + _buf.length) {
      raf.setPositionSync(pos);
      _buf = raf.readSync(max(n, _blockSize));
      _bufPos = pos;
      if (_buf.length < n) throw const FormatException('unexpected EOF');
    }
    return Uint8List.sublistView(_buf, pos - _bufPos, pos - _bufPos + n);
  }
}

class _BitReader {
  _BitReader(this.data);

  final Uint8List data;
  int _pos = 0; // in bits

  int bit() {
    final byte = _pos >> 3;
    if (byte >= data.length) throw const FormatException('bitstream EOF');
    final v = (data[byte] >> (7 - (_pos & 7))) & 1;
    _pos++;
    return v;
  }

  int bits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | bit();
    }
    return v;
  }

  /// Exp-Golomb unsigned.
  int ue() {
    var zeros = 0;
    while (bit() == 0) {
      if (++zeros > 31) throw const FormatException('bad exp-golomb');
    }
    return (1 << zeros) - 1 + bits(zeros);
  }

  /// Exp-Golomb signed.
  int se() {
    final k = ue();
    return k.isOdd ? (k + 1) >> 1 : -(k >> 1);
  }
}
