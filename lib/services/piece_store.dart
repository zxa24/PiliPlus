/// LibrePili: pieces of bilibili's streams kept on disk, for [ParallelFetch]
/// to answer from before it asks the network (user 2026-10-17: 「加上缓存
/// 到存储，大小为1g」, 1B 2A 3B: in the system's cache folder, read by
/// downloads too).
///
/// A stream is known by its path and its size: the hosts all serve one
/// file at one path (`/upgcxcode/26/84/41424718426/41424718426-1-100026.m4s`
/// on akamai and cosov alike, measured), only the signature after it
/// changes. Each stream has a folder: `meta` (its path, size and type) and
/// a file per piece, `<start>-<length>`. Pieces of one stream may overlap
/// (a piece starts where a seek landed): a byte is read from the piece
/// holding it that starts last. Past [maxBytes], the pieces least lately
/// used go first; with every piece of a stream gone, its folder goes too.
///
/// Free of the app: dart:io only. Every operation fails quietly — a store
/// that cannot be written is a network fetch, as before.
library;

import 'dart:collection' show SplayTreeMap;
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io';
import 'dart:typed_data';

class PieceStore {
  PieceStore(this.dir, {required this.maxBytes});

  final Directory dir;

  /// The size kept at most, all streams together; 0 keeps nothing.
  int maxBytes;

  final _streams = <String, _Stream>{};

  /// Folders being deleted: a stream made again under the same name waits
  /// for its old folder to be gone.
  final _deleting = <String, Future<void>>{};

  /// Every piece, least lately used first.
  final _lru = <_Piece>{};
  var _bytes = 0;

  /// What the pieces kept take now.
  int get bytes => _bytes;

  bool _ready = false;

  /// Reads what is on disk. Until it has, nothing is found and nothing is
  /// kept.
  Future<void> open() async {
    try {
      await dir.create(recursive: true);
      final found = <_Piece>[];
      await for (final entry in dir.list()) {
        if (entry is! Directory) continue;
        final key = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        final meta = await _readMeta(File('${entry.path}/meta'));
        if (meta == null) {
          await entry.delete(recursive: true).catchError((_) => entry);
          continue;
        }
        final stream = _streams[key] = _Stream(key, meta.size, meta.type);
        await for (final file in entry.list()) {
          if (file is! File) continue;
          final name = file.uri.pathSegments.last;
          final m = RegExp(r'^(\d+)-(\d+)$').firstMatch(name);
          if (m == null) continue;
          final piece = _Piece(
            stream,
            int.parse(m[1]!),
            int.parse(m[2]!),
            file.statSync().modified,
          );
          stream.pieces[piece.start] = piece;
          found.add(piece);
        }
        if (stream.pieces.isEmpty) _forget(stream);
      }
      found.sort((a, b) => a.used.compareTo(b.used));
      for (final piece in found) {
        _lru.add(piece);
        _bytes += piece.length;
      }
      _ready = true;
      await _trim();
    } catch (_) {
      _ready = false;
    }
  }

  /// The folder name for the stream at [uri]: its path, readable and short.
  static String keyOf(Uri uri) {
    final path = uri.path;
    final name = uri.pathSegments.isEmpty
        ? 'stream'
        : uri.pathSegments.last.replaceAll(RegExp(r'[^\w.-]'), '_');
    var hash = 0x811c9dc5;
    for (final b in utf8.encode(path)) {
      hash = ((hash ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    final short = name.length > 60 ? name.substring(name.length - 60) : name;
    return '${hash.toRadixString(16).padLeft(8, '0')}_$short';
  }

  /// The size and type kept for [key], when anything is.
  ({int size, String? type})? meta(String key) {
    if (!_ready) return null;
    final stream = _streams[key];
    return stream == null ? null : (size: stream.size, type: stream.type);
  }

  /// The stream at [key] is [size] bytes: kept pieces of another size are
  /// another file, and go.
  Future<void> sized(String key, Uri uri, int size, String? type) async {
    if (!_ready || maxBytes <= 0) return;
    final known = _streams[key];
    if (known != null && known.size == size) return;
    if (known != null) await _drop(known);
    await _deleting[key];
    final stream = _streams[key] = _Stream(key, size, type);
    try {
      final folder = Directory('${dir.path}/$key');
      await folder.create(recursive: true);
      await File('${folder.path}/meta').writeAsString(
        jsonEncode({'path': uri.path, 'size': size, 'type': type}),
      );
    } catch (_) {
      _streams.remove(stream.key);
    }
  }

  /// The bytes kept of [key] from [pos] on, up to [max] of them, from the
  /// piece holding [pos] that starts last; null when none holds it.
  Future<Uint8List?> read(String key, int pos, int max) async {
    if (!_ready) return null;
    final stream = _streams[key];
    if (stream == null) return null;
    _Piece? holding;
    for (
      var at = stream.pieces.lastKeyBefore(pos + 1);
      at != null;
      at = stream.pieces.lastKeyBefore(at)
    ) {
      final piece = stream.pieces[at]!;
      if (pos < piece.start + piece.length) {
        holding = piece;
        break;
      }
      // pieces are at most a few hundred KB: one that far back holds nothing
      if (pos - at > 8 << 20) break;
    }
    if (holding == null) return null;
    final file = File('${dir.path}/$key/${holding.start}-${holding.length}');
    try {
      final from = pos - holding.start;
      final to = (from + max).clamp(from, holding.length);
      final handle = await file.open();
      try {
        await handle.setPosition(from);
        final data = await handle.read(to - from);
        if (data.length != to - from) throw const FileSystemException('short');
        _use(holding);
        return data;
      } finally {
        await handle.close();
      }
    } catch (_) {
      // gone from under the store (the cache folder cleared): forgotten
      _remove(holding);
      return null;
    }
  }

  /// Keeps [data] as the piece of [key] at [start]; nothing when one kept
  /// already holds all of it, or the stream's size is not known.
  Future<void> write(String key, int start, Uint8List data) async {
    if (!_ready || maxBytes <= 0 || data.isEmpty) return;
    final stream = _streams[key];
    if (stream == null) return;
    final end = start + data.length;
    final before = stream.pieces.lastKeyBefore(start + 1);
    if (before != null && before + stream.pieces[before]!.length >= end) {
      return;
    }
    final piece = _Piece(stream, start, data.length, DateTime.now());
    try {
      await File(
        '${dir.path}/$key/$start-${data.length}',
      ).writeAsBytes(data, flush: false);
    } catch (_) {
      return;
    }
    // written meanwhile by another (the same piece twice): the one kept
    if (stream.pieces[start] case final had?) _remove(had, delete: false);
    stream.pieces[start] = piece;
    _lru.add(piece);
    _bytes += piece.length;
    await _trim();
  }

  /// Everything kept, gone.
  Future<void> clear() async {
    for (final stream in _streams.values.toList()) {
      await _drop(stream);
    }
    _lru.clear();
    _bytes = 0;
  }

  /// Down to [maxBytes] (after it was lowered, too).
  Future<void> trim() => _trim();

  Future<void> _trim() async {
    while (_bytes > maxBytes && _lru.isNotEmpty) {
      _remove(_lru.first);
    }
  }

  void _use(_Piece piece) {
    if (_lru.remove(piece)) _lru.add(piece);
    piece.used = DateTime.now();
    // what is read is what stays: the order survives a restart
    File(
      '${dir.path}/${piece.stream.key}/${piece.start}-${piece.length}',
    ).setLastModified(piece.used).catchError((_) {});
  }

  void _remove(_Piece piece, {bool delete = true}) {
    if (_lru.remove(piece)) _bytes -= piece.length;
    final stream = piece.stream;
    if (identical(stream.pieces[piece.start], piece)) {
      stream.pieces.remove(piece.start);
    }
    if (delete) {
      File(
        '${dir.path}/${stream.key}/${piece.start}-${piece.length}',
      ).delete().catchError((_) => File(''));
    }
    if (stream.pieces.isEmpty && identical(_streams[stream.key], stream)) {
      _forget(stream);
    }
  }

  Future<void> _drop(_Stream stream) async {
    for (final piece in stream.pieces.values.toList()) {
      if (_lru.remove(piece)) _bytes -= piece.length;
    }
    stream.pieces.clear();
    await _forget(stream);
  }

  Future<void> _forget(_Stream stream) {
    _streams.remove(stream.key);
    final key = stream.key;
    final gone = Directory('${dir.path}/$key')
        .delete(recursive: true)
        .then<void>((_) {}, onError: (_) {})
        .whenComplete(() => _deleting.remove(key));
    return _deleting[key] = gone;
  }

  static Future<({int size, String? type})?> _readMeta(File file) async {
    try {
      final json = jsonDecode(await file.readAsString()) as Map;
      final size = json['size'];
      if (size is! int || size <= 0) return null;
      return (size: size, type: json['type'] as String?);
    } catch (_) {
      return null;
    }
  }
}

class _Stream {
  _Stream(this.key, this.size, this.type);

  final String key;
  final int size;
  final String? type;
  final pieces = SplayTreeMap<int, _Piece>();
}

class _Piece {
  _Piece(this.stream, this.start, this.length, this.used);

  final _Stream stream;
  final int start;
  final int length;
  DateTime used;
}
