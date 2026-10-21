import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:PiliPlus/pages/common/load_more_footer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Ctr extends CommonListController<List<int>?, int> {
  int calls = 0;
  final pending = <Completer<LoadingState<List<int>?>>>[];

  // a list that knows its own end, as most do (a total, a has-more flag)
  bool endsAtFirstPage = false;

  @override
  void checkIsEnd(int length) {
    if (endsAtFirstPage) isEnd = true;
  }

  @override
  Future<LoadingState<List<int>?>> customGetData() {
    calls++;
    final c = Completer<LoadingState<List<int>?>>();
    pending.add(c);
    return c.future;
  }

  // a parsed response is a growable list: a load-more appends to it
  void answer(LoadingState<List<int>?> res) => pending
      .removeAt(0)
      .complete(
        res is Success<List<int>?> ? Success([...?res.response]) : res,
      );
}

Future<_Ctr> _loaded() async {
  final ctr = _Ctr();
  final f = ctr.queryData();
  ctr.answer(const Success<List<int>?>([1, 2]));
  await f;
  return ctr;
}

Widget _host(_Ctr ctr) => MaterialApp(
  home: Scaffold(
    body: CustomScrollView(slivers: [LoadMoreFooter(controller: ctr)]),
  ),
);

void main() {
  group('controller', () {
    test('no footer until a next page is asked for', () async {
      final ctr = await _loaded();
      expect(ctr.loadMoreStatus.value, LoadMoreStatus.idle);
    });

    test(
      'loading while the next page is on its way, after the frame',
      () async {
        final ctr = await _loaded();
        final f = ctr.onLoadMore();
        expect(
          ctr.loadMoreStatus.value,
          LoadMoreStatus.idle,
          reason: 'not changed synchronously: it may be inside a layout',
        );
        await Future<void>.delayed(Duration.zero);
        expect(ctr.loadMoreStatus.value, LoadMoreStatus.loading);
        ctr.answer(const Success<List<int>?>([3]));
        await f;
        expect(ctr.loadMoreStatus.value, LoadMoreStatus.loading);
        expect(ctr.loadingState.value.data, [1, 2, 3]);
      },
    );

    test('an empty page is the end', () async {
      final ctr = await _loaded();
      final f = ctr.onLoadMore();
      ctr.answer(const Success<List<int>?>([]));
      await f;
      expect(ctr.isEnd, isTrue);
      expect(ctr.loadMoreStatus.value, LoadMoreStatus.end);
    });

    test('a list that fits on one page says nothing', () async {
      final ctr = _Ctr()..endsAtFirstPage = true;
      final f = ctr.queryData();
      ctr.answer(const Success<List<int>?>([1, 2]));
      await f;
      expect(ctr.isEnd, isTrue);
      expect(
        ctr.loadMoreStatus.value,
        LoadMoreStatus.idle,
        reason: '没有更多了 only after a load-more reached the end',
      );
    });

    test('a failed load-more keeps its error and leaves the list', () async {
      final ctr = await _loaded();
      final f = ctr.onLoadMore();
      ctr.answer(const Error('boom'));
      await f;
      expect(ctr.loadMoreStatus.value, LoadMoreStatus.error);
      expect(ctr.loadMoreError, 'boom');
      expect(ctr.loadingState.value.data, [1, 2]);
      expect(ctr.page, 2, reason: 'the failed page is asked for again');
    });

    test('retry asks again and clears the error', () async {
      final ctr = await _loaded();
      var f = ctr.onLoadMore();
      ctr.answer(const Error('boom'));
      await f;
      f = ctr.retryLoadMore();
      expect(ctr.calls, 3);
      expect(ctr.loadMoreStatus.value, LoadMoreStatus.loading);
      expect(ctr.loadMoreError, isNull);
      ctr.answer(const Success<List<int>?>([3]));
      await f;
      expect(ctr.loadMoreStatus.value, LoadMoreStatus.loading);
      expect(ctr.loadingState.value.data, [1, 2, 3]);
    });

    test("retry can go through the page's own load-more", () async {
      final ctr = await _loaded();
      final f = ctr.onLoadMore();
      ctr.answer(const Error('boom'));
      await f;
      var own = 0;
      await ctr.retryLoadMore(() async => own++);
      expect(own, 1);
      expect(ctr.calls, 2, reason: "the controller's own was not called");
      expect(ctr.loadMoreError, isNull);
      expect(ctr.loadMoreStatus.value, LoadMoreStatus.loading);
    });

    test('a refresh clears a load-more error', () async {
      final ctr = await _loaded();
      var f = ctr.onLoadMore();
      ctr.answer(const Error('boom'));
      await f;
      f = ctr.onRefresh();
      ctr.answer(const Success<List<int>?>([7]));
      await f;
      expect(ctr.loadMoreStatus.value, LoadMoreStatus.idle);
      expect(ctr.loadMoreError, isNull);
    });

    test(
      'a load-more superseded by a refresh leaves the status alone',
      () async {
        final ctr = await _loaded();
        final more = ctr.onLoadMore();
        final refresh = ctr.onRefresh();
        // the refresh answers first, then the stale load-more fails
        ctr.pending.removeAt(1).complete(const Success<List<int>?>([5]));
        await refresh;
        ctr.answer(const Error('late'));
        await more;
        expect(ctr.loadMoreStatus.value, LoadMoreStatus.idle);
        expect(ctr.loadMoreError, isNull);
      },
    );
  });

  group('widget', () {
    // the requests are answered by completers: a pump runs their callbacks
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
    }

    testWidgets('draws nothing while idle or before the first page', (
      tester,
    ) async {
      final ctr = _Ctr();
      await tester.pumpWidget(_host(ctr));
      unawaited(ctr.queryData());
      await settle(tester);
      expect(find.byType(LoadMoreFooterRow), findsNothing);
      ctr.answer(const Success<List<int>?>([1]));
      await settle(tester);
      expect(find.byType(LoadMoreFooterRow), findsNothing);
    });

    testWidgets('loading, error with retry, end', (tester) async {
      final ctr = _Ctr();
      await tester.pumpWidget(_host(ctr));
      unawaited(ctr.queryData());
      ctr.answer(const Success<List<int>?>([1]));
      await settle(tester);

      unawaited(ctr.onLoadMore());
      await settle(tester);
      expect(find.text('加载中...'), findsOneWidget);

      ctr.answer(const Error('网络错误'));
      await settle(tester);
      expect(find.text('加载失败：网络错误，点击重试'), findsOneWidget);

      await tester.tap(find.text('加载失败：网络错误，点击重试'));
      await settle(tester);
      expect(ctr.calls, 3, reason: 'the tap asked for the page again');
      expect(find.text('加载中...'), findsOneWidget);

      ctr.answer(const Success<List<int>?>([]));
      await settle(tester);
      expect(find.text('没有更多了'), findsOneWidget);
    });
  });
}
