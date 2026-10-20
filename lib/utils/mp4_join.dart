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
///
/// Each segment's leading edit is kept in the timing (user 2026-10-19, D9 A):
/// the first segment's edit list becomes the joined track's, and a later
/// segment is placed so that its own edit's media time plays at the join —
/// an empty edit (a late start) becomes a gap, and an edit that skips the
/// segment's first media time (AAC encoder priming) drops the audio samples
/// wholly before it and takes the rest off the previous sample's duration,
/// so the tracks stay in step at every join instead of drifting by 20-50 ms
/// and playing the priming (audit A37).
abstract final class _Mp4Joiner {
  static List<_Track> join(List<String> inputs) {
    final tracks = _readProgressive(inputs.first);
    for (final t in tracks) {
      _openEndedEdits(t);
    }
    // the first segment's edit, which the joined edit list is: its lead
    // (seconds) and the media time it starts playing at, per track
    final leads = [for (final t in tracks) _leadOf(t)];
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
      }
      // its own leading edit, read before its times are converted
      final own = [
        for (var i = 0; i < tracks.length; i++)
          _leadOf(segment[i], timescale: tracks[i].timescale),
      ];
      for (var i = 0; i < tracks.length; i++) {
        final s = segment[i];
        final timescale = tracks[i].timescale;
        if (s.timescale != timescale) _rescale(s, timescale);
      }
      // start where the track that plays longest ends, so the tracks stay
      // in sync
      final start = [
        for (var i = 0; i < tracks.length; i++)
          playedEnd(
            lead: leads[i].lead,
            mediaTime: leads[i].mediaTime,
            mediaEnd: tracks[i].mediaDuration,
            firstOffset: tracks[i].ctos.first,
            timescale: tracks[i].timescale,
          ),
      ].reduce(max);
      for (var i = 0; i < tracks.length; i++) {
        final t = tracks[i];
        final s = segment[i];
        // this segment's sample entries, as indexes into the joined stsd
        final entries = t.sampleEntries ??= _sampleEntriesOf(t.stsd);
        final descIndex = [
          for (final e in _sampleEntriesOf(s.stsd)) _entryIndex(entries, e),
        ];
        final fit = fitSegment(
          offset:
              placeAt(
                start: start,
                lead: leads[i].lead,
                mediaTime: leads[i].mediaTime,
                ownLead: own[i].lead,
                ownMediaTime: own[i].mediaTime,
                timescale: t.timescale,
              ) -
              t.mediaDuration,
          mediaTime: own[i].mediaTime,
          durations: s.durations,
          syncs: s.syncs,
          lastDuration: t.durations.last,
        );
        if (fit.drop > 0) _dropLeading(s, fit.drop);
        t.durations.last += fit.extend - fit.shorten;
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

  /// The lead (seconds of empty edits) of [t]'s edit list and the media
  /// time its first playing edit starts at, in [timescale] (the track's own
  /// when null): (0, 0) without an edit list.
  static ({double lead, int mediaTime}) _leadOf(_Track t, {int? timescale}) {
    var lead = 0.0;
    for (final e in t.edits) {
      if (e.mediaTime < 0) {
        lead += e.segmentDuration / t.sourceMovieTimescale;
        continue;
      }
      return (
        lead: lead,
        mediaTime: _scale(e.mediaTime, t.timescale, timescale ?? t.timescale),
      );
    }
    return (lead: lead, mediaTime: 0);
  }

  /// When a track of the joined file stops playing, in seconds: its
  /// [lead], then its media from [mediaTime] to [mediaEnd] (decode times).
  /// [firstOffset], the first sample's composition offset, is the delay a
  /// B-frame stream presents everything by: an edit that starts there skips
  /// nothing of its end (one that starts later, AAC priming, does). Without
  /// an edit this is the decode end, as joins have always been placed.
  static double playedEnd({
    required double lead,
    required int mediaTime,
    required int mediaEnd,
    required int firstOffset,
    required int timescale,
  }) =>
      lead +
      (mediaEnd - mediaTime + min(max(0, firstOffset), mediaTime)) / timescale;

  /// The joined decode time a later segment's own times are offset by, so
  /// that its own edit's [ownMediaTime] plays [ownLead] after [start] (the
  /// join, seconds) under the joined edit list ([lead], [mediaTime]).
  static int placeAt({
    required double start,
    required double lead,
    required int mediaTime,
    required double ownLead,
    required int ownMediaTime,
    required int timescale,
  }) =>
      ((start - lead + ownLead) * timescale).round() + mediaTime - ownMediaTime;

  /// How a later segment is fitted on to the joined track, whose own times
  /// are to be offset by [offset] from the joined track's end ([placeAt]
  /// less that end); [mediaTime] is where its own edit starts playing and
  /// [durations] and [syncs] are its samples'. The samples wholly before
  /// [mediaTime] never play (AAC priming): they are dropped while the next
  /// one is a sync sample (audio; a video starts on its key frame, so
  /// nothing of it goes). The first sample kept then starts a gap after the
  /// end, added to the previous sample's duration, or overlaps it, taken
  /// off that duration ([lastDuration], which keeps at least 1).
  static ({int drop, int extend, int shorten}) fitSegment({
    required int offset,
    required int mediaTime,
    required List<int> durations,
    required List<bool> syncs,
    required int lastDuration,
  }) {
    var drop = 0;
    var dropped = 0;
    while (drop + 1 < durations.length &&
        dropped + durations[drop] <= mediaTime &&
        syncs[drop + 1]) {
      dropped += durations[drop];
      drop++;
    }
    final at = offset + dropped;
    return (
      drop: drop,
      extend: max(0, at),
      shorten: at < 0 ? min(-at, max(0, lastDuration - 1)) : 0,
    );
  }

  /// [s] without its first [n] samples: its times start at the next one.
  static void _dropLeading(_Track s, int n) {
    var shift = 0;
    for (var i = 0; i < n; i++) {
      shift += s.durations[i];
    }
    final chunks = <_Chunk>[];
    for (final c in s.chunks) {
      final end = c.firstSample + c.sampleCount;
      if (end <= n) continue;
      var offset = c.sourceOffset;
      var length = c.length;
      var startDts = c.startDts;
      var first = c.firstSample;
      for (; first < n; first++) {
        offset += s.sizes[first];
        length -= s.sizes[first];
        startDts += s.durations[first];
      }
      chunks.add(
        _Chunk(s, offset, first - n, startDts - shift, c.sourcePath)
          ..length = length
          ..sampleCount = end - first
          ..descIndex = c.descIndex,
      );
    }
    s.chunks
      ..clear()
      ..addAll(chunks);
    s.durations.removeRange(0, n);
    s.sizes.removeRange(0, n);
    s.ctos.removeRange(0, n);
    s.syncs.removeRange(0, n);
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
    var length = 0;
    try {
      length = raf.lengthSync();
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
      _readSampleTables(t, trak, length);
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

  /// [fileLength] bounds the sample count: a damaged count must not
  /// allocate or loop without end.
  static void _readSampleTables(_Track t, Uint8List trak, int fileLength) {
    final stbl = _stbl(trak);

    // sample sizes
    final sizes = <int>[];
    if (stbl['stsz'] case final body?) {
      final b = _R(body)..skip(4);
      final fixed = b.u32();
      final n = b.u32();
      if (fixed != 0 ? n * fixed > fileLength : n * 4 > b.remaining) {
        throw FormatException('bad stsz sample count $n in ${t.path}');
      }
      for (var i = 0; i < n; i++) {
        sizes.add(fixed != 0 ? fixed : b.u32());
      }
    } else if (stbl['stz2'] case final body?) {
      final b = _R(body)..skip(7);
      final field = b.u8();
      final n = b.u32();
      if (n * field > b.remaining * 8) {
        throw FormatException('bad stz2 sample count $n in ${t.path}');
      }
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
