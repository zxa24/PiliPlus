part of 'mp4_remux.dart';

/// LibrePili: joins progressive MP4 segments (old single-URL downloads that
/// come split into several files) into one timeline for [Mp4Remuxer]'s
/// writer. Samples are read from each segment's sample tables (stts, ctts,
/// stss, stsc, stsz/stz2, stco/co64) and copied byte-for-byte.
///
/// Every segment must carry the same tracks (same kind and codec); a codec
/// configuration (stsd) that differs between segments is kept as an extra
/// sample entry, which chunks of that segment point at, and a differing
/// media timescale is converted. Only different tracks or codecs throw
/// [UnsupportedError], and the caller keeps the segments as separate files.
abstract final class _Mp4Joiner {
  static List<_Track> join(List<String> inputs) {
    final tracks = _readProgressive(inputs.first);
    for (final t in tracks) {
      _openEndedEdits(t);
    }
    for (final input in inputs.skip(1)) {
      final segment = _readProgressive(input);
      if (segment.length != tracks.length) {
        throw UnsupportedError('segments have different tracks: $input');
      }
      for (var i = 0; i < tracks.length; i++) {
        final t = tracks[i];
        final s = segment[i];
        if (!_sameBytes(_handlerType(t), _handlerType(s))) {
          throw UnsupportedError('segments have different tracks: $input');
        }
        if (s.sampleEntryType != t.sampleEntryType) {
          throw UnsupportedError(
            'codec changes between segments '
            '(${t.sampleEntryType} -> ${s.sampleEntryType}): $input',
          );
        }
        if (s.timescale != t.timescale) _rescale(s, t.timescale);
      }
      // start where the longest track ended, so the tracks stay in sync
      final start = tracks
          .map((t) => t.mediaDuration / t.timescale)
          .reduce(max);
      for (var i = 0; i < tracks.length; i++) {
        final t = tracks[i];
        final s = segment[i];
        // this segment's sample entries, as indexes into the joined stsd
        final entries = t.sampleEntries ??= _sampleEntriesOf(t.stsd);
        final descIndex = [
          for (final e in _sampleEntriesOf(s.stsd)) _entryIndex(entries, e),
        ];
        final gap = (start * t.timescale).round() - t.mediaDuration;
        if (gap > 0) t.durations.last += gap;
        final firstSample = t.sizes.length;
        final dts = t.mediaDuration;
        for (final c in s.chunks) {
          t.chunks.add(
            _Chunk(
                t,
                c.sourceOffset,
                c.firstSample + firstSample,
                c.startDts + dts,
                c.sourcePath,
              )
              ..length = c.length
              ..sampleCount = c.sampleCount
              ..descIndex = c.descIndex <= descIndex.length
                  ? descIndex[c.descIndex - 1]
                  : descIndex.first,
          );
        }
        t
          ..durations.addAll(s.durations)
          ..sizes.addAll(s.sizes)
          ..ctos.addAll(s.ctos)
          ..syncs.addAll(s.syncs);
      }
    }
    // a single configuration throughout: keep the stsd as it was
    for (final t in tracks) {
      if (t.sampleEntries?.length == 1) t.sampleEntries = null;
    }
    return tracks;
  }

  /// handler_type of the track's `hdlr` (vide / soun ...).
  static Uint8List _handlerType(_Track t) =>
      Uint8List.sublistView(t.hdlr, 16, 20);

  /// Converts [s]'s decode times to [timescale], rounding the running time
  /// (not each duration) so the segment does not drift.
  static void _rescale(_Track s, int timescale) {
    final from = s.timescale;
    var src = 0;
    var dst = 0;
    final starts = <int>[];
    for (var i = 0; i < s.durations.length; i++) {
      starts.add(dst);
      src += s.durations[i];
      final end = _scale(src, from, timescale);
      s.durations[i] = end - dst;
      s.ctos[i] = _scale(s.ctos[i], from, timescale);
      dst = end;
    }
    for (var i = 0; i < s.chunks.length; i++) {
      final c = s.chunks[i];
      s.chunks[i] =
          _Chunk(
              s,
              c.sourceOffset,
              c.firstSample,
              starts[c.firstSample],
              c.sourcePath,
            )
            ..length = c.length
            ..sampleCount = c.sampleCount
            ..descIndex = c.descIndex;
    }
    s.timescale = timescale;
  }

  /// The first segment's edit list is kept (encoder delay, a late start),
  /// but its playing edit must run to the end of the joined track.
  static void _openEndedEdits(_Track t) {
    final firstPlaying = t.edits.indexWhere((e) => e.mediaTime >= 0);
    if (firstPlaying == -1) {
      t.edits.clear();
      return;
    }
    final playing = t.edits[firstPlaying];
    t.edits
      ..removeRange(firstPlaying, t.edits.length)
      ..add(_EditEntry(0, playing.mediaTime, playing.rate));
  }

  static List<_Track> _readProgressive(String path) {
    final raf = File(path).openSync();
    Uint8List? moov;
    try {
      final length = raf.lengthSync();
      var pos = 0;
      while (pos + 8 <= length) {
        raf.setPositionSync(pos);
        final header = raf.readSync(16);
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
          raf.setPositionSync(pos + headerSize);
          moov = raf.readSync(size - headerSize);
        } else if (type == 'moof') {
          throw UnsupportedError('fragmented MP4 segment: $path');
        }
        pos += size;
      }
    } finally {
      raf.closeSync();
    }
    if (moov == null) throw FormatException('no moov in $path');

    var movieTimescale = Mp4Remuxer._movieTimescale;
    final traks = <Uint8List>[];
    for (final (type, body) in _R(moov).boxes()) {
      if (type == 'mvhd') {
        final b = _R(body);
        final v = b.u8();
        b.skip(3 + (v == 1 ? 16 : 8));
        movieTimescale = b.u32();
      } else if (type == 'trak') {
        traks.add(body);
      }
    }
    final tracks = <_Track>[];
    for (final trak in traks) {
      final t = _Track(path)
        ..sourceMovieTimescale = movieTimescale
        .._parseTrak(trak);
      _readSampleTables(t, trak);
      if (t.sizes.isNotEmpty) tracks.add(t..index = tracks.length);
    }
    if (tracks.isEmpty) throw FormatException('no samples in $path');
    return tracks;
  }

  static Map<String, Uint8List> _stbl(Uint8List trak) {
    for (final (type, mdia) in _R(trak).boxes()) {
      if (type != 'mdia') continue;
      for (final (t2, minf) in _R(mdia).boxes()) {
        if (t2 != 'minf') continue;
        for (final (t3, stbl) in _R(minf).boxes()) {
          if (t3 == 'stbl') {
            return {for (final (k, v) in _R(stbl).boxes()) k: v};
          }
        }
      }
    }
    return const {};
  }

  static void _readSampleTables(_Track t, Uint8List trak) {
    final stbl = _stbl(trak);

    // sample sizes
    final sizes = <int>[];
    if (stbl['stsz'] case final body?) {
      final b = _R(body)..skip(4);
      final fixed = b.u32();
      final n = b.u32();
      for (var i = 0; i < n; i++) {
        sizes.add(fixed != 0 ? fixed : b.u32());
      }
    } else if (stbl['stz2'] case final body?) {
      final b = _R(body)..skip(7);
      final field = b.u8();
      final n = b.u32();
      for (var i = 0; i < n; i++) {
        switch (field) {
          case 4:
            final byte = b.data[b.pos + (i >> 1)];
            sizes.add(i.isEven ? byte >> 4 : byte & 0xF);
          case 8:
            sizes.add(b.u8());
          case 16:
            sizes.add((b.u8() << 8) | b.u8());
          default:
            throw FormatException('bad stz2 field size $field');
        }
      }
    }
    if (sizes.isEmpty) return;
    final n = sizes.length;

    // decode durations
    final durations = <int>[];
    if (stbl['stts'] case final body?) {
      final b = _R(body)..skip(4);
      final entries = b.u32();
      for (var i = 0; i < entries && durations.length < n; i++) {
        final count = b.u32();
        final delta = b.u32();
        for (var j = 0; j < count && durations.length < n; j++) {
          durations.add(delta);
        }
      }
    }
    while (durations.length < n) {
      durations.add(durations.isEmpty ? 0 : durations.last);
    }

    // composition offsets
    final ctos = <int>[];
    if (stbl['ctts'] case final body?) {
      final b = _R(body);
      final signed = b.u8() == 1;
      b.skip(3);
      final entries = b.u32();
      for (var i = 0; i < entries && ctos.length < n; i++) {
        final count = b.u32();
        final offset = signed ? b.i32() : b.u32();
        for (var j = 0; j < count && ctos.length < n; j++) {
          ctos.add(offset);
        }
      }
    }
    while (ctos.length < n) {
      ctos.add(0);
    }

    // sync samples (no stss: every sample is a sync sample)
    final syncs = List.filled(n, true);
    if (stbl['stss'] case final body?) {
      syncs.fillRange(0, n, false);
      final b = _R(body)..skip(4);
      final entries = b.u32();
      for (var i = 0; i < entries; i++) {
        final s = b.u32() - 1;
        if (s >= 0 && s < n) syncs[s] = true;
      }
    }

    // chunk offsets and samples per chunk
    final offsets = <int>[];
    if (stbl['stco'] case final body?) {
      final b = _R(body)..skip(4);
      final entries = b.u32();
      for (var i = 0; i < entries; i++) {
        offsets.add(b.u32());
      }
    } else if (stbl['co64'] case final body?) {
      final b = _R(body)..skip(4);
      final entries = b.u32();
      for (var i = 0; i < entries; i++) {
        offsets.add(b.u64());
      }
    }
    // (first chunk, 0-based; samples per chunk; sample description index)
    final stsc = <(int, int, int)>[];
    if (stbl['stsc'] case final body?) {
      final b = _R(body)..skip(4);
      final entries = b.u32();
      for (var i = 0; i < entries; i++) {
        stsc.add((b.u32() - 1, b.u32(), max(1, b.u32())));
      }
    }
    if (offsets.isEmpty || stsc.isEmpty) {
      throw FormatException('missing chunk tables in ${t.path}');
    }

    var sample = 0;
    var dts = 0;
    var entry = 0;
    for (var c = 0; c < offsets.length && sample < n; c++) {
      while (entry + 1 < stsc.length && stsc[entry + 1].$1 <= c) {
        entry++;
      }
      final chunk = _Chunk(t, offsets[c], sample, dts)
        ..descIndex = stsc[entry].$3;
      for (var j = 0; j < stsc[entry].$2 && sample < n; j++) {
        chunk
          ..length += sizes[sample]
          ..sampleCount += 1;
        dts += durations[sample];
        sample++;
      }
      t.chunks.add(chunk);
    }
    if (sample < n) {
      throw FormatException('chunk tables cover $sample of $n samples');
    }
    t
      ..sizes.addAll(sizes)
      ..durations.addAll(durations)
      ..ctos.addAll(ctos)
      ..syncs.addAll(syncs);
  }
}
