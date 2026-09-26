/// LibrePili: slow and failed requests, in the event log.
///
/// "The home page hung, then said the connection timed out" left nothing
/// to go on: the app's own log (librepili_logs.json) keeps crashes and the
/// player's errors, not requests. A request that fails, or takes longer
/// than [slow], is written to [EventLog] with its host, path, what went
/// wrong and how long it took — each attempt, since this runs before the
/// retries. It is what the failure dialog shows (FailureReport), in
/// release builds too. The query is left out: it carries keys and ids.
library;

import 'package:PiliPlus/services/event_log.dart';
import 'package:dio/dio.dart';

class TimingInterceptor extends Interceptor {
  TimingInterceptor({this.slow = const Duration(seconds: 3)});

  final Duration slow;

  static const _startedAt = 'librepili.startedAt';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startedAt] = DateTime.now().millisecondsSinceEpoch;
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final ms = _elapsed(response.requestOptions);
    if (ms != null && ms >= slow.inMilliseconds) {
      EventLog.add(
        'http',
        'slow ${_what(response.requestOptions)} '
            '${response.statusCode} in $ms ms',
      );
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.type != DioExceptionType.cancel) {
      final ms = _elapsed(err.requestOptions);
      final cause = err.error ?? err.message ?? '';
      EventLog.add(
        'http',
        'failed ${_what(err.requestOptions)} ${err.type.name} '
            'after ${ms ?? '?'} ms: $cause',
      );
    }
    handler.next(err);
  }

  static int? _elapsed(RequestOptions options) {
    final started = options.extra[_startedAt];
    return started is int
        ? DateTime.now().millisecondsSinceEpoch - started
        : null;
  }

  static String _what(RequestOptions options) {
    final uri = options.uri;
    return '${options.method} ${uri.host}${uri.path}';
  }
}
