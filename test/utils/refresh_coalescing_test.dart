import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _Ctr extends CommonListController<List<int>?, int> {
  int calls = 0;
  final pending = <Completer<LoadingState<List<int>?>>>[];

  @override
  Future<LoadingState<List<int>?>> customGetData() {
    calls++;
    final c = Completer<LoadingState<List<int>?>>();
    pending.add(c);
    return c.future;
  }

  void completeAll(List<int> data) {
    for (final c in List.of(pending)) {
      if (!c.isCompleted) c.complete(Success(data));
    }
    pending.clear();
  }
}

void main() {
  test('a refresh while one is in flight attaches instead of re-requesting',
      () async {
    final ctr = _Ctr();
    final a = ctr.queryData();
    final b = ctr.queryData();
    expect(ctr.calls, 1, reason: 'coalesced into the in-flight refresh');
    ctr.completeAll([1, 2]);
    await Future.wait([a, b]);
    expect(ctr.calls, 1);
    // and a later refresh, once nothing is in flight, does request again
    final c = ctr.queryData();
    expect(ctr.calls, 2);
    ctr.completeAll([3]);
    await c;
  });

  test('markRefreshStale re-issues instead of attaching', () async {
    final ctr = _Ctr();
    final a = ctr.queryData();
    expect(ctr.calls, 1);
    ctr.markRefreshStale();
    final b = ctr.queryData();
    expect(ctr.calls, 2, reason: 'parameters changed: a real second request');
    ctr.completeAll([9]);
    await Future.wait([a, b]);
  });

  test('onReload marks stale', () async {
    final ctr = _Ctr();
    final a = ctr.queryData();
    expect(ctr.calls, 1);
    final b = ctr.onReload();
    expect(ctr.calls, 2);
    ctr.completeAll([9]);
    await Future.wait([a, b]);
  });

  test('the newest refresh wins: the older response is dropped', () async {
    final ctr = _Ctr();
    final a = ctr.queryData();
    ctr.markRefreshStale();
    final b = ctr.queryData();
    expect(ctr.calls, 2);
    // complete the *older* request first with its own data
    ctr.pending[0].complete(const Success<List<int>?>([111]));
    await Future.delayed(Duration.zero);
    ctr.pending[1].complete(const Success<List<int>?>([222]));
    await Future.wait([a, b]);
    expect(
      (ctr.loadingState.value as Success<List<int>?>).response,
      [222],
      reason: 'generation counter still discards the superseded response',
    );
  });
}
