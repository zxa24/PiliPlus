/// LibrePili: just enough of libmpv's C API to run a second, hidden player
/// instance that decodes audio to raw PCM.
///
/// This binds the very libmpv the app already ships with media_kit, so there
/// is no second decoder to bundle and no ffmpeg dependency. media_kit's own
/// Dart API cannot be used for this: it has no way to say "decode to a file
/// instead of the speakers", and the `stream-record` / `dump-cache` commands
/// that would have done it are dead ends — media_kit's ffmpeg is built
/// decode-only and contains no muxers at all (measured: every container
/// extension returns `Output format not found`).
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// The handful of `mpv_event_id` values this path cares about.
abstract final class MpvEventId {
  static const shutdown = 1;
  static const logMessage = 2;
  static const endFile = 7;
}

// mpv_event { int event_id; int error; uint64 reply_userdata; void* data; }
final class MpvEvent extends Struct {
  @Int32()
  external int eventId;
  @Int32()
  external int error;
  @Uint64()
  external int replyUserdata;
  external Pointer<Void> data;
}

final class MpvLogMessage extends Struct {
  external Pointer<Utf8> prefix;
  external Pointer<Utf8> level;
  external Pointer<Utf8> text;
  @Int32()
  external int logLevel;
}

typedef _CreateNative = Pointer<Void> Function();
typedef _IntCtxNative = Int32 Function(Pointer<Void>);
typedef _IntCtxDart = int Function(Pointer<Void>);
typedef _SetOptNative =
    Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetOptDart =
    int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _CommandNative =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _CommandDart = int Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _WaitNative = Pointer<Void> Function(Pointer<Void>, Double);
typedef _WaitDart = Pointer<Void> Function(Pointer<Void>, double);
typedef _GetPropNative = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _GetPropDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _VoidCtxNative = Void Function(Pointer<Void>);
typedef _VoidCtxDart = void Function(Pointer<Void>);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _ReqLogNative = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _ReqLogDart = int Function(Pointer<Void>, Pointer<Utf8>);

class Mpv {
  Mpv(this.lib)
    : _create = lib.lookupFunction<_CreateNative, _CreateNative>('mpv_create'),
      _initialize = lib.lookupFunction<_IntCtxNative, _IntCtxDart>(
        'mpv_initialize',
      ),
      _setOption = lib.lookupFunction<_SetOptNative, _SetOptDart>(
        'mpv_set_option_string',
      ),
      _command = lib.lookupFunction<_CommandNative, _CommandDart>(
        'mpv_command',
      ),
      _waitEvent = lib.lookupFunction<_WaitNative, _WaitDart>('mpv_wait_event'),
      _getProperty = lib.lookupFunction<_GetPropNative, _GetPropDart>(
        'mpv_get_property_string',
      ),
      _terminateDestroy = lib.lookupFunction<_VoidCtxNative, _VoidCtxDart>(
        'mpv_terminate_destroy',
      ),
      _free = lib.lookupFunction<_FreeNative, _FreeDart>('mpv_free'),
      _requestLog = lib.lookupFunction<_ReqLogNative, _ReqLogDart>(
        'mpv_request_log_messages',
      );

  final DynamicLibrary lib;
  final Pointer<Void> Function() _create;
  final int Function(Pointer<Void>) _initialize;
  final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>) _setOption;
  final int Function(Pointer<Void>, Pointer<Pointer<Utf8>>) _command;
  final Pointer<Void> Function(Pointer<Void>, double) _waitEvent;
  final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>) _getProperty;
  final void Function(Pointer<Void>) _terminateDestroy;
  final void Function(Pointer<Void>) _free;
  final int Function(Pointer<Void>, Pointer<Utf8>) _requestLog;

  static String get libraryName => Platform.isWindows
      ? 'libmpv-2.dll'
      : (Platform.isMacOS || Platform.isIOS ? 'libmpv.dylib' : 'libmpv.so');

  /// Binds to the already-loaded libmpv: the player has it open, so this
  /// resolves to the same image rather than a second copy.
  static Mpv open() => Mpv(DynamicLibrary.open(libraryName));

  Pointer<Void> create() => _create();

  int initialize(Pointer<Void> ctx) => _initialize(ctx);

  void destroy(Pointer<Void> ctx) => _terminateDestroy(ctx);

  int setOption(Pointer<Void> ctx, String key, String value) {
    final k = key.toNativeUtf8();
    final v = value.toNativeUtf8();
    try {
      return _setOption(ctx, k, v);
    } finally {
      calloc
        ..free(k)
        ..free(v);
    }
  }

  int command(Pointer<Void> ctx, List<String> args) {
    final array = calloc<Pointer<Utf8>>(args.length + 1);
    for (var i = 0; i < args.length; i++) {
      array[i] = args[i].toNativeUtf8();
    }
    array[args.length] = nullptr;
    try {
      return _command(ctx, array);
    } finally {
      for (var i = 0; i < args.length; i++) {
        calloc.free(array[i]);
      }
      calloc.free(array);
    }
  }

  int requestLogMessages(Pointer<Void> ctx, String level) {
    final l = level.toNativeUtf8();
    try {
      return _requestLog(ctx, l);
    } finally {
      calloc.free(l);
    }
  }

  Pointer<MpvEvent> waitEvent(Pointer<Void> ctx, double timeout) =>
      _waitEvent(ctx, timeout).cast<MpvEvent>();

  String? property(Pointer<Void> ctx, String name) {
    final n = name.toNativeUtf8();
    try {
      final result = _getProperty(ctx, n);
      if (result == nullptr) return null;
      final value = result.toDartString();
      _free(result.cast());
      return value;
    } finally {
      calloc.free(n);
    }
  }
}
