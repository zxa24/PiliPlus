import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingInterceptor extends Interceptor {
  int errors = 0;
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    errors++;
    handler.next(err);
  }
}

class _AlwaysFailAdapter implements HttpClientAdapter {
  int calls = 0;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    calls++;
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'probe',
    );
  }
}

void main() {
  test('a retried GET reaches the interceptors after RetryInterceptor exactly '
      'once, and the request still fails', () async {
    final dio = Dio();
    final adapter = _AlwaysFailAdapter();
    dio.httpClientAdapter = adapter;
    final counter = _CountingInterceptor();
    dio.interceptors.add(RetryInterceptor(dio, 2, 1));
    dio.interceptors.add(counter);

    Object? thrown;
    try {
      await dio.get('http://127.0.0.1:1/probe');
    } catch (e) {
      thrown = e;
    }
    expect(adapter.calls, 3, reason: 'initial attempt + 2 retries');
    expect(counter.errors, 1, reason: 'exactly one delivery, not one per retry');
    expect(thrown, isA<DioException>());
  });

  test('a POST is not retried and still reaches later interceptors', () async {
    final dio = Dio();
    final adapter = _AlwaysFailAdapter();
    dio.httpClientAdapter = adapter;
    final counter = _CountingInterceptor();
    dio.interceptors.add(RetryInterceptor(dio, 2, 1));
    dio.interceptors.add(counter);

    try {
      await dio.post('http://127.0.0.1:1/probe');
    } catch (_) {}
    expect(adapter.calls, 1);
    expect(counter.errors, 1);
  });
}
