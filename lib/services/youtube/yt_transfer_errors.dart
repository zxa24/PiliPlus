/// LibrePili — what a YouTube download's transfer throws of its own
/// (design §4.3 table, stage-2 plan §3.4).
///
/// Before, every failure it built was an `HttpException`, and
/// `DownloadManager.isNetworkFailure` counts every `HttpException` as the
/// network: a server's 403 and a range that does not fit read the same as
/// a connection dropped mid-body. With these types, the `HttpException`s
/// left are dart:io's own (a body cut short, headers cut short).
///
/// No text here quotes a URL ([ytErrorText]): a stream URL's query carries
/// the viewer's address and a signature.
library;

import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/youtube/stream_relay.dart';

/// The server answered [code] (not 200 / 206 / a 416 at the end).
class YtHttpStatus implements Exception {
  const YtHttpStatus(this.code);

  final int code;

  /// 403 / 404 / 410: the address refused, retried by the entry (a new
  /// address), not within the transfer.
  bool get refused => code == 403 || code == 404 || code == 410;

  /// 429 / 5xx: the server busy, retried within the transfer's budget.
  bool get busy => code == 429 || code >= 500;

  @override
  String toString() => 'YtHttpStatus($code)';
}

/// How a range answer did not fit (design §4.2).
enum YtRangeKind {
  /// 416 that is not the end of what is on disk.
  notSatisfiable,

  /// 200 (the whole stream) to a request that did not start at 0.
  ignored,

  /// A 206 for other bytes than were asked for, or more of them.
  unexpected,

  /// A 206 whose total is not the stream's expected total.
  total,

  /// The bytes the overlap check read back differ from those on disk.
  overlap,
}

/// A range answer that does not fit the stream on disk: the stream file is
/// dropped and downloaded from 0 once per start; a second time in the same
/// start fails the entry (design §4.2).
class YtRangeError implements Exception {
  const YtRangeError(this.kind, this.detail);

  const YtRangeError.notSatisfiable(this.detail)
    : kind = YtRangeKind.notSatisfiable;
  const YtRangeError.ignored(this.detail) : kind = YtRangeKind.ignored;
  const YtRangeError.unexpected(this.detail) : kind = YtRangeKind.unexpected;
  const YtRangeError.total(this.detail) : kind = YtRangeKind.total;
  const YtRangeError.overlap(this.detail) : kind = YtRangeKind.overlap;

  final YtRangeKind kind;
  final String detail;

  /// The reason a restart from 0 for it is logged with.
  String get reason => switch (kind) {
    YtRangeKind.notSatisfiable => '416',
    YtRangeKind.ignored => 'range ignored',
    YtRangeKind.unexpected => 'range unexpected',
    YtRangeKind.total => 'range total',
    YtRangeKind.overlap => 'overlap mismatch',
  };

  @override
  String toString() => 'YtRangeError.${kind.name}($detail)';
}

/// The server ended a body before its length (`DownloadManager`'s
/// `incomplete transfer`): the network, retried within the budget.
class YtShortBody implements Exception {
  const YtShortBody(this.received, this.expected);

  final int received;
  final int expected;

  @override
  String toString() => 'YtShortBody($received of $expected)';
}

/// More redirects than `YtCheckedHops.maxHops`.
class YtTooManyRedirects implements Exception {
  const YtTooManyRedirects(this.host);

  final String host;

  @override
  String toString() => 'YtTooManyRedirects($host)';
}

/// What the transfer reports through `done`: which stream failed and why.
/// [cause] is kept as it was thrown (it is classified by its type); its
/// text here carries no URL — dart:io's `HttpException` appends the
/// request's whole URI, a `FormatException` of a URL its input, and the
/// service writes this text into `lastError` and the debug output.
class YtTransferError implements Exception {
  const YtTransferError(this.stream, this.cause);

  /// `video` or `audio`.
  final String stream;
  final Object cause;

  @override
  String toString() => '$stream: ${ytErrorText(cause)}';
}

/// [error] as text without any URL in it: an `HttpException` without its
/// URI, a `FormatException` without its input, and any other URL left in
/// the text cut to its scheme and host (a stream URL's path and query
/// carry the viewer's address and a signature).
String ytErrorText(Object error) {
  final text = switch (error) {
    HttpException(:final message) => 'HttpException: $message',
    FormatException(:final message) => 'FormatException: $message',
    _ => '$error',
  };
  return text.replaceAllMapped(_url, (m) => '${m[1]}://${m[2]}/…');
}

final _url = RegExp(r'([A-Za-z][A-Za-z0-9+.-]*)://([^\s/?#,]+)[^\s,]*');

/// Whether [error] is the network failing (design §4.3 `network`): counted
/// against the transfer's budget, and started again once the app is back
/// on screen.
bool ytNetworkFailure(Object error) => switch (error) {
  SocketException() ||
  TlsException() ||
  TimeoutException() ||
  YtShortBody() ||
  HttpException() => true,
  YtHopRefused(:final why) => why == 'no address',
  _ => false,
};

/// Whether the transfer tries [error] again within its budget: the network,
/// and a server that is busy (429 / 5xx, not counted as the network).
bool ytRetriedInTransfer(Object error) =>
    ytNetworkFailure(error) || (error is YtHttpStatus && error.busy);
