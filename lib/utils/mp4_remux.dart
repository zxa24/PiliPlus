import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';

/// Losslessly merges single-track fragmented MP4 inputs (bilibili DASH
/// `video.m4s` / `audio.m4s`) into one progressive MP4 with `moov` placed
/// before `mdat` (fast start).
///
/// Sample data is copied byte-for-byte, codec configuration (`stsd`) and edit
/// lists are carried over, so any codec the inputs carry (AVC / HEVC / AV1 /
/// AAC ...) is supported. Pure Dart, no Flutter dependency: safe to run inside
/// `Isolate.run`.
abstract final class Mp4Remuxer {
  static const _movieTimescale = 1000;
  static const _maxChunkSeconds = 1.0;
  static const _copyBufferSize = 4 << 20;

  static Future<void> remux({
    required List<String> inputs,
    required String output,
    void Function(int copied, int total)? onProgress,
  }) async {
    if (inputs.isEmpty) throw ArgumentError('no input');
    final tracks = <_Track>[];
    for (final input in inputs) {
      tracks.add(
        await _Track.parse(input)
          ..index = tracks.length,
      );
    }

    final chunks = [for (final t in tracks) ...t.chunks]
      ..sort((a, b) {
        final c = a.startSeconds.compareTo(b.startSeconds);
        return c != 0 ? c : a.track.index.compareTo(b.track.index);
      });

    final payloadSize = chunks.fold<int>(0, (s, c) => s + c.length);
    final ftyp = _ftyp(tracks);
    // Size of moov does not depend on offset values, only on stco vs co64.
    final useCo64 = payloadSize + ftyp.length + (64 << 20) > 0xFFFFFFFF;
    final mdatHeaderSize = payloadSize + 8 > 0xFFFFFFFF ? 16 : 8;
    final moovSize = _moov(tracks, useCo64).length;
    var offset = ftyp.length + moovSize + mdatHeaderSize;
    for (final c in chunks) {
      c.outputOffset = offset;
      offset += c.length;
    }
    final moov = _moov(tracks, useCo64);
    assert(moov.length == moovSize);

    final tmp = File('$output.part');
    final out = await tmp.open(mode: FileMode.write);
    final sources = <String, RandomAccessFile>{};
    try {
      await out.writeFrom(ftyp);
      await out.writeFrom(moov);
      final mdatHeader = _W();
      if (mdatHeaderSize == 16) {
        mdatHeader
          ..u32(1)
          ..fourcc('mdat')
          ..u64(payloadSize + 16);
      } else {
        mdatHeader
          ..u32(payloadSize + 8)
          ..fourcc('mdat');
      }
      await out.writeFrom(mdatHeader.bytes);

      final buffer = Uint8List(_copyBufferSize);
      var copied = 0;
      for (final c in chunks) {
        final src = sources[c.track.path] ??= await File(
          c.track.path,
        ).open();
        await src.setPosition(c.sourceOffset);
        var remaining = c.length;
        while (remaining > 0) {
          final n = await src.readInto(
            buffer,
            0,
            remaining < buffer.length ? remaining : buffer.length,
          );
          if (n <= 0) {
            throw FormatException('unexpected EOF in ${c.track.path}');
          }
          await out.writeFrom(buffer, 0, n);
          remaining -= n;
          copied += n;
        }
        onProgress?.call(copied, payloadSize);
      }
    } catch (_) {
      await out.close();
      for (final s in sources.values) {
        await s.close();
      }
      if (tmp.existsSync()) await tmp.delete();
      rethrow;
    }
    await out.close();
    for (final s in sources.values) {
      await s.close();
    }
    final dest = File(output);
    if (dest.existsSync()) await dest.delete();
    await tmp.rename(output);
  }

  static Uint8List _ftyp(List<_Track> tracks) {
    final brands = <String>{'isom', 'iso2', 'mp41'};
    for (final t in tracks) {
      final fmt = t.sampleEntryType;
      if (fmt == 'avc1' || fmt == 'avc3') brands.add('avc1');
      if (fmt == 'av01') brands.add('av01');
    }
    final w = _W()
      ..fourcc('isom')
      ..u32(0x200);
    brands.forEach(w.fourcc);
    return _box('ftyp', w.bytes);
  }

  static Uint8List _moov(List<_Track> tracks, bool useCo64) {
    final traks = <Uint8List>[];
    var movieDuration = 0;
    for (var i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      final trackDuration = t.movieDuration;
      movieDuration = max(movieDuration, trackDuration);
      traks.add(t.buildTrak(i + 1, trackDuration, useCo64));
    }
    final mvhd = _W();
    final v1 = movieDuration > 0xFFFFFFFF;
    mvhd.u32(v1 ? 0x01000000 : 0);
    if (v1) {
      mvhd
        ..u64(0)
        ..u64(0)
        ..u32(_movieTimescale)
        ..u64(movieDuration);
    } else {
      mvhd
        ..u32(0)
        ..u32(0)
        ..u32(_movieTimescale)
        ..u32(movieDuration);
    }
    mvhd
      ..u32(0x00010000) // rate
      ..u16(0x0100) // volume
      ..zeros(10)
      ..bytes_(_unityMatrix)
      ..zeros(24)
      ..u32(tracks.length + 1);
    return _box('moov', _concat([_box('mvhd', mvhd.bytes), ...traks]));
  }
}

final _unityMatrix = () {
  final w = _W();
  for (final v in [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]) {
    w.u32(v);
  }
  return w.bytes;
}();

class _Chunk {
  _Chunk(this.track, this.sourceOffset, this.firstSample, this.startDts);
  final _Track track;
  final int sourceOffset;
  final int firstSample;
  final int startDts;
  int length = 0;
  int sampleCount = 0;
  int outputOffset = 0;
  double get startSeconds => startDts / track.timescale;
}

class _EditEntry {
  _EditEntry(this.segmentDuration, this.mediaTime, this.rate);
  int segmentDuration; // in source movie timescale; 0 = until end
  final int mediaTime; // in media timescale; -1 = empty edit
  final int rate;
}

class _Track {
  _Track(this.path);
  final String path;
  int index = 0;

  late int timescale;
  late int sourceMovieTimescale;
  late String sampleEntryType;
  late Uint8List tkhdTail; // layer .. height, copied verbatim
  late int tkhdFlags;
  late Uint8List mdhdLanguage;
  late Uint8List hdlr;
  late Uint8List mediaHeader; // vmhd / smhd / nmhd
  late Uint8List dinf;
  late Uint8List stsd;
  final edits = <_EditEntry>[];

  // trex defaults
  int _trexDuration = 0;
  int _trexSize = 0;
  int _trexFlags = 0;

  final durations = <int>[];
  final sizes = <int>[];
  final ctos = <int>[];
  final syncs = <bool>[];
  final chunks = <_Chunk>[];

  int get mediaDuration => durations.fold(0, (s, d) => s + d);

  /// End of the last presented sample in media time (decode time plus
  /// composition offset); exceeds [mediaDuration] when B-frames reorder.
  int get presentationEnd {
    var dts = 0;
    var end = 0;
    for (var i = 0; i < durations.length; i++) {
      end = max(end, dts + ctos[i] + durations[i]);
      dts += durations[i];
    }
    return end;
  }

  int get movieDuration {
    if (edits.isEmpty) {
      return _scale(mediaDuration, timescale, Mp4Remuxer._movieTimescale);
    }
    var total = 0;
    for (final e in _resolvedEdits()) {
      total += e.segmentDuration;
    }
    return total;
  }

  /// Edits converted to the output movie timescale, with "until end" (0)
  /// segment durations of fragmented files resolved against the real length.
  List<_EditEntry> _resolvedEdits() {
    return [
      for (final e in edits)
        _EditEntry(
          e.segmentDuration == 0 && e.mediaTime >= 0
              ? _scale(
                  max(0, presentationEnd - e.mediaTime),
                  timescale,
                  Mp4Remuxer._movieTimescale,
                )
              : _scale(
                  e.segmentDuration,
                  sourceMovieTimescale,
                  Mp4Remuxer._movieTimescale,
                ),
          e.mediaTime,
          e.rate,
        ),
    ];
  }

  static Future<_Track> parse(String path) async {
    final t = _Track(path);
    final raf = await File(path).open();
    try {
      final length = await raf.length();
      var pos = 0;
      var sawMoov = false;
      var dts = 0;
      while (pos + 8 <= length) {
        await raf.setPosition(pos);
        final header = await raf.read(16);
        final hd = ByteData.sublistView(header);
        var size = hd.getUint32(0);
        final type = String.fromCharCodes(header, 4, 8);
        var headerSize = 8;
        if (size == 1) {
          size = hd.getUint64(8);
          headerSize = 16;
        } else if (size == 0) {
          size = length - pos;
        }
        if (size < headerSize || pos + size > length) {
          throw FormatException('bad box $type at $pos in $path');
        }
        if (type == 'moov') {
          await raf.setPosition(pos + headerSize);
          t._parseMoov(await raf.read(size - headerSize));
          sawMoov = true;
        } else if (type == 'moof') {
          if (!sawMoov) throw FormatException('moof before moov in $path');
          await raf.setPosition(pos + headerSize);
          dts = t._parseMoof(await raf.read(size - headerSize), pos, dts);
        }
        pos += size;
      }
      if (!sawMoov) throw FormatException('no moov in $path');
      if (t.sizes.isEmpty) throw FormatException('no samples in $path');
      return t;
    } finally {
      await raf.close();
    }
  }

  void _parseMoov(Uint8List moov) {
    final r = _R(moov);
    sourceMovieTimescale = Mp4Remuxer._movieTimescale;
    var trakCount = 0;
    for (final (type, body) in r.boxes()) {
      switch (type) {
        case 'mvhd':
          final b = _R(body);
          final v = b.u8();
          b.skip(3 + (v == 1 ? 16 : 8));
          sourceMovieTimescale = b.u32();
        case 'mvex':
          for (final (t2, b2) in _R(body).boxes()) {
            if (t2 == 'trex') {
              final b = _R(b2)..skip(12);
              _trexDuration = b.u32();
              _trexSize = b.u32();
              _trexFlags = b.u32();
            }
          }
        case 'trak':
          trakCount++;
          _parseTrak(body);
      }
    }
    if (trakCount != 1) {
      throw FormatException('expected 1 track, got $trakCount in $path');
    }
  }

  void _parseTrak(Uint8List trak) {
    for (final (type, body) in _R(trak).boxes()) {
      switch (type) {
        case 'tkhd':
          final b = _R(body);
          final v = b.u8();
          tkhdFlags = b.u24();
          // skip times, track id, reserved, duration
          b.skip(v == 1 ? 32 : 20);
          tkhdTail = b.rest();
        case 'edts':
          for (final (t2, b2) in _R(body).boxes()) {
            if (t2 != 'elst') continue;
            final b = _R(b2);
            final v = b.u8();
            b.skip(3);
            final n = b.u32();
            for (var i = 0; i < n; i++) {
              final seg = v == 1 ? b.u64() : b.u32();
              final mt = v == 1 ? b.i64() : b.i32();
              edits.add(_EditEntry(seg, mt, b.u32()));
            }
          }
        case 'mdia':
          _parseMdia(body);
      }
    }
  }

  void _parseMdia(Uint8List mdia) {
    for (final (type, body) in _R(mdia).boxes()) {
      switch (type) {
        case 'mdhd':
          final b = _R(body);
          final v = b.u8();
          b.skip(3 + (v == 1 ? 16 : 8));
          timescale = b.u32();
          b.skip(v == 1 ? 8 : 4);
          mdhdLanguage = b.bytes(2);
        case 'hdlr':
          hdlr = _box('hdlr', body);
        case 'minf':
          for (final (t2, b2) in _R(body).boxes()) {
            switch (t2) {
              case 'vmhd' || 'smhd' || 'nmhd' || 'sthd':
                mediaHeader = _box(t2, b2);
              case 'dinf':
                dinf = _box(t2, b2);
              case 'stbl':
                for (final (t3, b3) in _R(b2).boxes()) {
                  if (t3 == 'stsd') {
                    stsd = _box(t3, b3);
                    sampleEntryType = String.fromCharCodes(b3, 12, 16);
                  }
                }
            }
          }
      }
    }
  }

  /// Returns the decode time after this fragment.
  int _parseMoof(Uint8List moof, int moofOffset, int dts) {
    for (final (type, body) in _R(moof).boxes()) {
      if (type != 'traf') continue;
      var baseOffset = moofOffset;
      var defDuration = _trexDuration;
      var defSize = _trexSize;
      var defFlags = _trexFlags;
      int? nextDataOffset;
      for (final (t2, b2) in _R(body).boxes()) {
        final b = _R(b2);
        switch (t2) {
          case 'tfhd':
            final flags = b.u32() & 0xFFFFFF;
            b.skip(4); // track id
            if (flags & 0x1 != 0) baseOffset = b.u64();
            if (flags & 0x2 != 0) b.skip(4);
            if (flags & 0x8 != 0) defDuration = b.u32();
            if (flags & 0x10 != 0) defSize = b.u32();
            if (flags & 0x20 != 0) defFlags = b.u32();
          case 'tfdt':
            final v = b.u8();
            b.skip(3);
            dts = v == 1 ? b.u64() : b.u32();
          case 'trun':
            final vf = b.u32();
            final version = vf >>> 24;
            final flags = vf & 0xFFFFFF;
            final n = b.u32();
            var dataOffset = nextDataOffset ?? baseOffset;
            if (flags & 0x1 != 0) dataOffset = baseOffset + b.i32();
            int? firstFlags;
            if (flags & 0x4 != 0) firstFlags = b.u32();
            _Chunk? chunk;
            var chunkDuration = 0;
            final maxChunk = (Mp4Remuxer._maxChunkSeconds * timescale).round();
            for (var i = 0; i < n; i++) {
              final dur = flags & 0x100 != 0 ? b.u32() : defDuration;
              final size = flags & 0x200 != 0 ? b.u32() : defSize;
              final sFlags = flags & 0x400 != 0
                  ? b.u32()
                  : (i == 0 && firstFlags != null ? firstFlags : defFlags);
              final cto = flags & 0x800 != 0
                  ? (version == 0 ? b.u32() : b.i32())
                  : 0;
              if (chunk == null || chunkDuration >= maxChunk) {
                chunk = _Chunk(this, dataOffset, sizes.length, dts);
                chunks.add(chunk);
                chunkDuration = 0;
              }
              durations.add(dur);
              sizes.add(size);
              ctos.add(cto);
              // sample_is_non_sync_sample
              syncs.add(sFlags & 0x10000 == 0);
              chunk
                ..length += size
                ..sampleCount += 1;
              chunkDuration += dur;
              dataOffset += size;
              dts += dur;
            }
            nextDataOffset = dataOffset;
        }
      }
    }
    return dts;
  }

  Uint8List buildTrak(int trackId, int trackDuration, bool useCo64) {
    final tkhd = _W();
    final v1 = trackDuration > 0xFFFFFFFF;
    tkhd.u32((v1 ? 0x01000000 : 0) | tkhdFlags | 0x3);
    if (v1) {
      tkhd
        ..u64(0)
        ..u64(0)
        ..u32(trackId)
        ..u32(0)
        ..u64(trackDuration);
    } else {
      tkhd
        ..u32(0)
        ..u32(0)
        ..u32(trackId)
        ..u32(0)
        ..u32(trackDuration);
    }
    tkhd.bytes_(tkhdTail);

    final parts = <Uint8List>[_box('tkhd', tkhd.bytes)];

    if (edits.isNotEmpty) {
      final resolved = _resolvedEdits();
      final needV1 = resolved.any(
        (e) =>
            e.segmentDuration > 0xFFFFFFFF ||
            e.mediaTime > 0x7FFFFFFF ||
            e.mediaTime < -0x80000000,
      );
      final elst = _W()
        ..u32(needV1 ? 0x01000000 : 0)
        ..u32(resolved.length);
      for (final e in resolved) {
        if (needV1) {
          elst
            ..u64(e.segmentDuration)
            ..i64(e.mediaTime);
        } else {
          elst
            ..u32(e.segmentDuration)
            ..u32(e.mediaTime);
        }
        elst.u32(e.rate);
      }
      parts.add(_box('edts', _box('elst', elst.bytes)));
    }

    final mdhd = _W();
    final dur = mediaDuration;
    final mv1 = dur > 0xFFFFFFFF;
    mdhd.u32(mv1 ? 0x01000000 : 0);
    if (mv1) {
      mdhd
        ..u64(0)
        ..u64(0)
        ..u32(timescale)
        ..u64(dur);
    } else {
      mdhd
        ..u32(0)
        ..u32(0)
        ..u32(timescale)
        ..u32(dur);
    }
    mdhd
      ..bytes_(mdhdLanguage)
      ..u16(0);

    final stbl = _box(
      'stbl',
      _concat([
        stsd,
        _stts(),
        ?_ctts(),
        ?_stss(),
        _stsz(),
        _stsc(),
        _stco(useCo64),
      ]),
    );
    final minf = _box('minf', _concat([mediaHeader, dinf, stbl]));
    final mdia = _box('mdia', _concat([_box('mdhd', mdhd.bytes), hdlr, minf]));
    parts.add(mdia);
    return _box('trak', _concat(parts));
  }

  Uint8List _stts() {
    final entries = <(int, int)>[];
    for (final d in durations) {
      if (entries.isNotEmpty && entries.last.$2 == d) {
        entries.last = (entries.last.$1 + 1, d);
      } else {
        entries.add((1, d));
      }
    }
    final w = _W()
      ..u32(0)
      ..u32(entries.length);
    for (final (count, delta) in entries) {
      w
        ..u32(count)
        ..u32(delta);
    }
    return _box('stts', w.bytes);
  }

  Uint8List? _ctts() {
    if (ctos.every((e) => e == 0)) return null;
    final signed = ctos.any((e) => e < 0);
    final entries = <(int, int)>[];
    for (final c in ctos) {
      if (entries.isNotEmpty && entries.last.$2 == c) {
        entries.last = (entries.last.$1 + 1, c);
      } else {
        entries.add((1, c));
      }
    }
    final w = _W()
      ..u32(signed ? 0x01000000 : 0)
      ..u32(entries.length);
    for (final (count, offset) in entries) {
      w
        ..u32(count)
        ..u32(offset);
    }
    return _box('ctts', w.bytes);
  }

  Uint8List? _stss() {
    if (syncs.every((e) => e)) return null;
    final w = _W()..u32(0);
    final idx = <int>[
      for (var i = 0; i < syncs.length; i++)
        if (syncs[i]) i + 1,
    ];
    w.u32(idx.length);
    idx.forEach(w.u32);
    return _box('stss', w.bytes);
  }

  Uint8List _stsz() {
    final w = _W()..u32(0);
    final first = sizes.first;
    if (sizes.every((e) => e == first)) {
      w
        ..u32(first)
        ..u32(sizes.length);
    } else {
      w
        ..u32(0)
        ..u32(sizes.length);
      sizes.forEach(w.u32);
    }
    return _box('stsz', w.bytes);
  }

  Uint8List _stsc() {
    final entries = <(int, int)>[];
    for (var i = 0; i < chunks.length; i++) {
      final n = chunks[i].sampleCount;
      if (entries.isEmpty || entries.last.$2 != n) entries.add((i + 1, n));
    }
    final w = _W()
      ..u32(0)
      ..u32(entries.length);
    for (final (firstChunk, perChunk) in entries) {
      w
        ..u32(firstChunk)
        ..u32(perChunk)
        ..u32(1);
    }
    return _box('stsc', w.bytes);
  }

  Uint8List _stco(bool co64) {
    final w = _W()
      ..u32(0)
      ..u32(chunks.length);
    for (final c in chunks) {
      co64 ? w.u64(c.outputOffset) : w.u32(c.outputOffset);
    }
    return _box(co64 ? 'co64' : 'stco', w.bytes);
  }
}

int _scale(int value, int from, int to) =>
    from == to ? value : (value * to + from ~/ 2) ~/ from;

Uint8List _box(String type, Uint8List body) {
  final size = body.length + 8;
  final w = _W();
  if (size > 0xFFFFFFFF) {
    w
      ..u32(1)
      ..fourcc(type)
      ..u64(size + 8);
  } else {
    w
      ..u32(size)
      ..fourcc(type);
  }
  return _concat([w.bytes, body]);
}

Uint8List _concat(List<Uint8List> parts) {
  final b = BytesBuilder(copy: false);
  parts.forEach(b.add);
  return b.takeBytes();
}

class _W {
  final _b = BytesBuilder();
  final _tmp = ByteData(8);
  Uint8List get bytes => _b.toBytes();

  void u16(int v) {
    _tmp.setUint16(0, v);
    _b.add(_tmp.buffer.asUint8List(0, 2));
  }

  void u32(int v) {
    _tmp.setUint32(0, v & 0xFFFFFFFF);
    _b.add(_tmp.buffer.asUint8List(0, 4));
  }

  void u64(int v) {
    _tmp.setUint64(0, v);
    _b.add(_tmp.buffer.asUint8List(0, 8));
  }

  void i64(int v) {
    _tmp.setInt64(0, v);
    _b.add(_tmp.buffer.asUint8List(0, 8));
  }

  void fourcc(String s) => _b.add(s.codeUnits);
  void zeros(int n) => _b.add(Uint8List(n));
  void bytes_(Uint8List data) => _b.add(data);
}

class _R {
  _R(this.data) : _bd = ByteData.sublistView(data);
  final Uint8List data;
  final ByteData _bd;
  int pos = 0;

  int u8() => _bd.getUint8(pos++);
  int u24() {
    final v = (_bd.getUint8(pos) << 16) | _bd.getUint16(pos + 1);
    pos += 3;
    return v;
  }

  int u32() {
    final v = _bd.getUint32(pos);
    pos += 4;
    return v;
  }

  int i32() {
    final v = _bd.getInt32(pos);
    pos += 4;
    return v;
  }

  int u64() {
    final v = _bd.getUint64(pos);
    pos += 8;
    return v;
  }

  int i64() {
    final v = _bd.getInt64(pos);
    pos += 8;
    return v;
  }

  void skip(int n) => pos += n;
  Uint8List bytes(int n) {
    final v = Uint8List.sublistView(data, pos, pos + n);
    pos += n;
    return v;
  }

  Uint8List rest() => Uint8List.sublistView(data, pos);

  /// Iterates child boxes of the current buffer, yielding (type, body).
  Iterable<(String, Uint8List)> boxes() sync* {
    var p = 0;
    while (p + 8 <= data.length) {
      var size = _bd.getUint32(p);
      final type = String.fromCharCodes(data, p + 4, p + 8);
      var header = 8;
      if (size == 1) {
        size = _bd.getUint64(p + 8);
        header = 16;
      } else if (size == 0) {
        size = data.length - p;
      }
      if (size < header || p + size > data.length) {
        throw FormatException('bad box $type');
      }
      yield (type, Uint8List.sublistView(data, p + header, p + size));
      p += size;
    }
  }
}
