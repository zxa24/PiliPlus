import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:dio/dio.dart';
import 'package:http2/http2.dart';

class RetryInterceptor extends Interceptor {
  final Dio _client;
  final int _count;
  final int _delay;

  RetryInterceptor(this._client, this._count, this._delay);

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.responseType == ResponseType.stream) {
      return handler.next(err);
    }
    if (err.response != null) {
      final options = err.requestOptions;
      if (options.followRedirects && options.maxRedirects > 0) {
        final status = err.response!.statusCode;
        if (status != null && 300 <= status && status < 400) {
          var redirectUrl = err.response!.headers.value('location');
          if (redirectUrl != null) {
            final oldUri = options.uri;
            var uri = Uri.parse(redirectUrl);
            if (!uri.hasScheme) {
              uri = oldUri.resolveUri(uri);
              redirectUrl = uri.toString();
            }
            if (uri.scheme != oldUri.scheme ||
                uri.host != oldUri.host ||
                uri.port != oldUri.port) {
              // another origin gets neither the account's cookies nor its
              // headers, nor the old query (access_key...): the location
              // carries its own
              options
                ..queryParameters = {}
                // every gRPC header too: x-bili-metadata-bin starts with the
                // accessKey, x-bili-device-bin/buvid carry the persistent
                // device id, and the referer names where we came from
                ..headers.removeWhere((key, _) {
                  final name = key.toLowerCase();
                  return name.startsWith('x-bili-') ||
                      name == 'cookie' ||
                      name == 'authorization' ||
                      name == 'buvid' ||
                      name == 'referer';
                })
                ..extra['account'] = const NoAccount();
              // 307/308 (and a POST this interceptor follows itself) keep
              // the body: take the account's secrets out of it too
              _scrubBody(options);
            }
            (options..path = redirectUrl).maxRedirects--;
            if (status == 303) {
              options
                ..data = null
                ..method = 'GET';
            }
            _client
                .fetch(options)
                .then(
                  (i) => handler.resolve(
                    i
                      ..redirects.add(
                        RedirectRecord(status, options.method, uri),
                      )
                      ..isRedirect = true,
                  ),
                )
                .onError<DioException>((error, _) => handler.next(error));
            return;
          }
        }
      }
      return handler.next(err);
    } else {
      switch (err.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.unknown:
          // only idempotent reads are re-sent: a POST (like, coin, comment,
          // follow...) may already have been applied by the server
          final method = err.requestOptions.method.toUpperCase();
          final extra = err.requestOptions.extra;
          // a retry re-enters this interceptor through `_client.fetch`, so
          // onError runs once per attempt on the same RequestOptions. Only
          // the attempt the caller made (no `_rt` yet) passes the final
          // error on, so the interceptors after this one — AccountManager's
          // toast and cookie save — run exactly once, not once per retry.
          final isRetryAttempt = extra.containsKey('_rt');
          void finish(DioException error) =>
              isRetryAttempt ? handler.reject(error) : handler.next(error);
          if ((method == 'GET' || method == 'HEAD') &&
              (extra['_rt'] ??= 0) < _count &&
              err.error
                  is! TransportConnectionException // 网络中断, 此时请求可能已经被服务器所接收
                  ) {
            Future.delayed(
              Duration(milliseconds: ++extra['_rt'] * _delay),
              () => _client
                  .fetch(err.requestOptions)
                  .then(handler.resolve)
                  .onError<DioException>((error, _) => finish(error)),
            );
          } else {
            finish(err);
          }
          return;
        default:
          return handler.next(err);
      }
    }
  }

  /// Account secrets a body may carry (see AccountManager) and the
  /// signatures computed over them: worthless at another origin, and the
  /// account's to keep.
  static const _bodySecrets = [
    'access_key',
    'mobile_access_key',
    'csrf',
    'csrf_token',
    'biliCSRF',
    'sign',
    'w_rid',
  ];

  static void _scrubBody(RequestOptions options) {
    switch (options.data) {
      case final Map data:
        data.removeWhere((key, _) => _bodySecrets.contains(key));
      case final FormData data:
        data.fields.removeWhere((e) => _bodySecrets.contains(e.key));
    }
  }

  RetryInterceptor copyWith({Dio? client, int? count, int? delay}) =>
      .new(client ?? _client, count ?? _count, delay ?? _delay);
}
