import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: the row a paged list ends on, as a sliver to put after the
/// list's own. It is drawn from the controller's [LoadMoreStatus] alone, so
/// one widget serves every list on [CommonListController]: "加载中…" while
/// the next page loads, "没有更多了" at the end, and a failed load-more's
/// error with a tap to try again. Nothing is drawn before the first page has
/// arrived (the list shows its own skeleton or error then) or while no next
/// page has been asked for.
class LoadMoreFooter extends StatelessWidget {
  const LoadMoreFooter({super.key, required this.controller, this.onRetry})
    : _sliver = true;

  /// The same row as the last item of a box list (a [ListView]).
  const LoadMoreFooter.box({
    super.key,
    required this.controller,
    this.onRetry,
  }) : _sliver = false;

  final CommonListController controller;
  final bool _sliver;

  /// What 点击重试 asks for the next page with, when the page does not use
  /// the controller's [CommonListController.onLoadMore] alone.
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) => Obx(() {
    final status = controller.loadMoreStatus.value;
    final hasItems = switch (controller.loadingState.value) {
      Success(:final List response) => response.isNotEmpty,
      _ => false,
    };
    if (!hasItems || status == LoadMoreStatus.idle) {
      return _sliver ? const SliverToBoxAdapter() : const SizedBox.shrink();
    }
    final row = LoadMoreFooterRow(
      status: status,
      error: controller.loadMoreError,
      onRetry: () => controller.retryLoadMore(onRetry),
    );
    return _sliver ? SliverToBoxAdapter(child: row) : row;
  });
}

/// The row itself. It is the same height whatever it says, so the list
/// does not jump when the last page lands.
class LoadMoreFooterRow extends StatelessWidget {
  const LoadMoreFooterRow({
    super.key,
    required this.status,
    this.error,
    this.onRetry,
  });

  static const height = 60.0;

  final LoadMoreStatus status;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final outline = ColorScheme.of(context).outline;
    final style = TextStyle(fontSize: 12, color: outline);
    return SizedBox(
      height: height,
      child: Center(
        child: switch (status) {
          LoadMoreStatus.error => TextButton(
            onPressed: onRetry,
            child: Text(
              '加载失败：${error ?? '未知错误'}，点击重试',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          LoadMoreStatus.end => Text('没有更多了', style: style),
          LoadMoreStatus.loading || LoadMoreStatus.idle => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: outline,
                ),
              ),
              const SizedBox(width: 8),
              Text('加载中...', style: style),
            ],
          ),
        },
      ),
    );
  }
}
