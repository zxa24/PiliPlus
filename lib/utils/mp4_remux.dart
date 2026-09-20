import 'dart:io';
import 'dart:math' show max, min;
import 'dart:typed_data';

part 'flv_demux.dart';
part 'mp4_join.dart';

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
  static const _readWindowSize = 1 << 20;

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
    await _write(tracks, output, onProgress);
  }

  /// Whether [path] starts with an FLV header.
  static bool isFlv(String path) => _hasMagic(path, 0, 'FLV');

  /// Whether [path] is an (ISO BMFF) MP4 file.
  static bool isMp4(String path) => _hasMagic(path, 4, 'ftyp');

  static bool _hasMagic(String path, int offset, String magic) {
    final RandomAccessFile raf;
    try {
      raf = File(path).openSync();
    } on FileSystemException {
      // missing or unreadable: not this format (the caller reports the file
      // itself as damaged)
      return false;
    }
    try {
      raf.setPositionSync(offset);
      return String.fromCharCodes(raf.readSync(magic.length)) == magic;
    } finally {
      raf.closeSync();
    }
  }

  /// Joins FLV segments (in timeline order) into one progressive MP4.
  /// Supports H.264 / HEVC video (legacy codec id 7 / 12 and enhanced FLV
  /// `avc1` / `hvc1`) and AAC audio, also when the codec configuration
  /// changes mid-stream or between segments (one sample entry per
  /// configuration). Anything else throws [UnsupportedError] so the caller
  /// can keep the original file.
  static Future<void> remuxFlv({
    required List<String> inputs,
    required String output,
    void Function(int copied, int total)? onProgress,
  }) async {
    if (inputs.isEmpty) throw ArgumentError('no input');
    await _write(_FlvDemuxer.demux(inputs), output, onProgress);
  }

  /// Joins progressive MP4 segments (in timeline order) into one MP4.
  /// Differing codec configurations of the same codec become several sample
  /// entries; throws [UnsupportedError] only when the segments' tracks or
  /// codecs differ, so the caller can keep them separate.
  static Future<void> joinMp4({
    required List<String> inputs,
    required String output,
    void Function(int copied, int total)? onProgress,
  }) async {
    if (inputs.isEmpty) throw ArgumentError('no input');
    await _write(_Mp4Joiner.join(inputs), output, onProgress);
  }

  /// Whether a downloaded durl segment reads cleanly (FLV: every tag
  /// complete; MP4: sample tables inside the file). False means the data is
  /// damaged (e.g. a truncated transfer) and the segment should be
  /// downloaded again; formats it cannot check count as fine.
  static bool checkSegment(String path) {
    try {
      if (isFlv(path)) {
        _FlvDemuxer.demux([path], strict: true);
        return true;
      }
      if (isMp4(path)) {
        final length = File(path).lengthSync();
        for (final t in _Mp4Joiner._readProgressive(path)) {
          for (final c in t.chunks) {
            if (c.sourceOffset + c.length > length) return false;
          }
        }
      }
      return true;
    } on FormatException {
      return false;
    } on RangeError {
      // e.g. a box header cut off before its 64-bit size
      return false;
    } on UnsupportedError {
      // readable, just not joinable: not a download problem
      return true;
    }
  }

  /// The tracks an FLV demux produces; for tests only.
  static List<Map<String, Object>> debugFlvTracks(List<String> inputs) =>
      _debugSummary(_FlvDemuxer.demux(inputs));

  /// The tracks [joinMp4] reads from progressive MP4 inputs; for tests only.
  static List<Map<String, Object>> debugMp4JoinTracks(List<String> inputs) =>
      _debugSummary(_Mp4Joiner.join(inputs));

  static List<Map<String, Object>> _debugSummary(List<_Track> tracks) => [
    for (final t in tracks)
      {
        'type': t.sampleEntryType,
        'timescale': t.timescale,
        'sizes': t.sizes,
        'durations': t.durations,
        'ctos': t.ctos,
        'syncs': t.syncs,
        'stsd': t.stsdBox,
        'sampleEntries': t.sampleEntries?.length ?? 1,
        'descIndexes': [for (final c in t.chunks) c.descIndex],
        'sampleCounts': [for (final c in t.chunks) c.sampleCount],
        'chunkOffsets': [for (final c in t.chunks) c.sourceOffset],
        'tkhdTail': t.tkhdTail,
        'edits': [
          for (final e in t.edits) [e.segmentDuration, e.mediaTime],
        ],
      },
  ];

  static Future<void> _write(
    List<_Track> tracks,
    String output,
    void Function(int copied, int total)? onProgress,
  ) async {
    for (final t in tracks) {
      t._inlineParameterSets();
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
    final windows = <String, _ReadWindow>{};
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

      // Sample bytes go through buffers on both sides: a chunk is one sample
      // in an FLV, so a read and a write per chunk is hundreds of thousands
      // of round-trips for a long video. Chunks run forward through each
      // source, so a window that slides forward serves nearly all of them
      // from memory.
      final outBuf = Uint8List(_copyBufferSize);
      var outLen = 0;
      var copied = 0;

      Future<void> flushOut() async {
        if (outLen > 0) {
          await out.writeFrom(outBuf, 0, outLen);
          outLen = 0;
        }
      }

      Future<void> putBytes(Uint8List bytes, int start, int end) async {
        var i = start;
        while (i < end) {
          if (outLen == outBuf.length) await flushOut();
          final n = min(end - i, outBuf.length - outLen);
          outBuf.setRange(outLen, outLen + n, bytes, i);
          outLen += n;
          i += n;
          copied += n;
        }
      }

      Future<void> copyRange(
        RandomAccessFile src,
        _ReadWindow win,
        String from,
        int offset,
        int length,
      ) async {
        if (length <= 0) return;
        if (length >= win.buf.length) {
          // bigger than the window: stream it straight through
          await flushOut();
          await src.setPosition(offset);
          win.length = 0; // the window's bytes are no longer what it says
          var left = length;
          while (left > 0) {
            final n = await src.readInto(
              win.buf,
              0,
              left < win.buf.length ? left : win.buf.length,
            );
            if (n <= 0) throw FormatException('unexpected EOF in $from');
            await out.writeFrom(win.buf, 0, n);
            left -= n;
            copied += n;
          }
          return;
        }
        if (offset < win.start || offset + length > win.start + win.length) {
          await src.setPosition(offset);
          // a short read is not EOF on every backend (SAF / FUSE / network
          // paths): keep filling the window until a read returns nothing,
          // and only then decide whether the chunk was covered
          var n = 0;
          while (n < win.buf.length) {
            final read = await src.readInto(win.buf, n);
            if (read <= 0) break;
            n += read;
          }
          if (n < length) throw FormatException('unexpected EOF in $from');
          win
            ..start = offset
            ..length = n;
        }
        final at = offset - win.start;
        await putBytes(win.buf, at, at + length);
      }

      // the last chunk of each source: its read window is freed there, so a
      // merge of many segments does not hold one window per input file for
      // the whole write
      final lastChunkOf = <String, int>{};
      for (var i = 0; i < chunks.length; i++) {
        lastChunkOf[chunks[i].sourcePath] = i;
      }

      for (var ci = 0; ci < chunks.length; ci++) {
        final c = chunks[ci];
        final src = sources[c.sourcePath] ??= await File(
          c.sourcePath,
        ).open();
        final win = windows[c.sourcePath] ??= _ReadWindow();
        final prefix = c.prefix;
        if (prefix != null) {
          await putBytes(prefix, 0, prefix.length);
        }
        if (c.ranges case final ranges?) {
          for (final (offset, length) in ranges) {
            await copyRange(src, win, c.sourcePath, offset, length);
          }
        } else {
          await copyRange(
            src,
            win,
            c.sourcePath,
            c.sourceOffset,
            c.length - (prefix?.length ?? 0),
          );
        }
        if (lastChunkOf[c.sourcePath] == ci) windows.remove(c.sourcePath);
        onProgress?.call(copied, payloadSize);
      }
      await flushOut();
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
  _Chunk(
    this.track,
    this.sourceOffset,
    this.firstSample,
    this.startDts, [
    String? sourcePath,
  ]) : sourcePath = sourcePath ?? track.path;
  final _Track track;

  /// File the chunk's bytes are read from (FLV input: one per segment).
  final String sourcePath;
  final int sourceOffset;
  final int firstSample;
  final int startDts;
  int length = 0;
  int sampleCount = 0;
  int outputOffset = 0;

  /// `(offset, length)` of this chunk's sample bytes in [sourcePath], in
  /// output order. Null when the samples are one contiguous run starting at
  /// [sourceOffset], as in a fragmented MP4. An FLV's samples are payloads
  /// of separate tags with the other track's tags in between, so they are
  /// listed one by one: a chunk has to be contiguous in the *output* file
  /// (`stco` names one offset for it), not in its source.
  List<(int, int)>? ranges;

  /// 1-based index of the sample entry (in `stsd`) its samples use.
  int descIndex = 1;

  /// Bytes written before the source bytes (counted in [length] and in the
  /// first sample's size): in-band parameter sets at a configuration switch.
  Uint8List? prefix;
  double get startSeconds => startDts / track.timescale;
}

/// A block of one source file held in memory, so the many small reads a
/// chunk list makes (one sample each, in increasing offset order) mostly
/// come out of it instead of hitting the file.
class _ReadWindow {
  final Uint8List buf = Uint8List(Mp4Remuxer._readWindowSize);

  /// Offset in the source [buf] starts at, and how much of it is filled.
  int start = 0;
  int length = 0;
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

  /// Set when the track carries several codec configurations (segments /
  /// a stream whose configuration changes): `stsd` is then built from these
  /// sample entries and each chunk points at its own with
  /// [_Chunk.descIndex].
  List<Uint8List>? sampleEntries;

  /// The `stsd` box written to the output.
  Uint8List get stsdBox =>
      sampleEntries == null ? stsd : _stsdOf(sampleEntries!);

  bool _inlined = false;

  /// HEVC with several configurations: the switch to another sample entry
  /// is only signalled through the container, which FFmpeg's
  /// `hevc_mp4toannexb` (the MediaCodec path) ignores, so the new frames
  /// would be decoded with the first VPS/SPS/PPS. The first sample after
  /// each switch therefore also carries its configuration's parameter sets
  /// in-band, and the entries become `hev1` (parameter sets may be in-band).
  void _inlineParameterSets() {
    final entries = sampleEntries;
    if (_inlined || entries == null || entries.length < 2) return;
    if (sampleEntryType != 'hvc1' && sampleEntryType != 'hev1') return;
    _inlined = true;
    for (final e in entries) {
      e.setAll(4, 'hev1'.codeUnits);
    }
    sampleEntryType = 'hev1';
    for (var i = 1; i < chunks.length; i++) {
      final c = chunks[i];
      if (c.descIndex == chunks[i - 1].descIndex) continue;
      final prefix = _hevcParameterSets(entries[c.descIndex - 1]);
      if (prefix == null || prefix.isEmpty) continue;
      c
        ..prefix = prefix
        ..length += prefix.length;
      sizes[c.firstSample] += prefix.length;
    }
  }

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
          // 64-bit size: the header must be there in full
          if (header.length < 16) {
            throw FormatException('truncated box $type at $pos in $path');
          }
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
        stsdBox,
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
    final entries = <(int, int, int)>[];
    for (var i = 0; i < chunks.length; i++) {
      final n = chunks[i].sampleCount;
      final desc = chunks[i].descIndex;
      if (entries.isEmpty || entries.last.$2 != n || entries.last.$3 != desc) {
        entries.add((i + 1, n, desc));
      }
    }
    final w = _W()
      ..u32(0)
      ..u32(entries.length);
    for (final (firstChunk, perChunk, desc) in entries) {
      w
        ..u32(firstChunk)
        ..u32(perChunk)
        ..u32(desc);
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

/// An `stsd` box holding [entries] (complete sample entry boxes).
Uint8List _stsdOf(List<Uint8List> entries) => _box(
  'stsd',
  _concat([
    (_W()
          ..u32(0)
          ..u32(entries.length))
        .bytes,
    ...entries,
  ]),
);

/// The sample entry boxes of an `stsd` box.
List<Uint8List> _sampleEntriesOf(Uint8List stsd) {
  // box header (8), version/flags (4), entry count (4)
  final body = _R(Uint8List.sublistView(stsd, 16));
  return [
    for (final (type, entry) in body.boxes())
      _box(type, Uint8List.fromList(entry)),
  ];
}

/// The `hvcC` body inside an HEVC visual sample entry, or null.
Uint8List? _hvcCOf(Uint8List entry) {
  // box header (8) + VisualSampleEntry fields (78), then child boxes
  if (entry.length <= 86) return null;
  try {
    for (final (type, body) in _R(Uint8List.sublistView(entry, 86)).boxes()) {
      if (type == 'hvcC') return body;
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// The parameter-set NAL units (VPS / SPS / PPS / SEI arrays) of an HEVC
/// sample entry's `hvcC`, each prefixed with its length the way samples
/// are (lengthSizeMinusOne + 1 bytes).
Uint8List? _hevcParameterSets(Uint8List entry) {
  final c = _hvcCOf(entry);
  if (c == null || c.length < 23) return null;
  final lengthSize = (c[21] & 3) + 1;
  final w = BytesBuilder();
  var p = 23;
  for (var a = 0; a < c[22] && p + 3 <= c.length; a++) {
    final n = (c[p + 1] << 8) | c[p + 2];
    p += 3;
    for (var i = 0; i < n && p + 2 <= c.length; i++) {
      final len = (c[p] << 8) | c[p + 1];
      p += 2;
      if (p + len > c.length) return null;
      for (var b = lengthSize - 1; b >= 0; b--) {
        w.addByte((len >> (8 * b)) & 0xFF);
      }
      w.add(Uint8List.sublistView(c, p, p + len));
      p += len;
    }
  }
  return w.toBytes();
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 1-based index of [entry] in [entries], appending it when new.
int _entryIndex(List<Uint8List> entries, Uint8List entry) {
  for (var i = 0; i < entries.length; i++) {
    if (_sameBytes(entries[i], entry)) return i + 1;
  }
  entries.add(entry);
  return entries.length;
}

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

  void u8(int v) => _b.addByte(v & 0xFF);

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
