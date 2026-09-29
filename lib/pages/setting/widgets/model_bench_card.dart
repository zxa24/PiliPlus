/// LibrePili: the performance test on the models page (本地模型 → 性能测试).
///
/// Its own widget so the models page takes one line for it. It shows the
/// advice first and the numbers behind it folded under 详细数据; it changes
/// no setting — which model to use stays the user's choice. Leaving the page
/// stops a test in progress (see [ModelBench]).
library;

import 'package:PiliPlus/services/model_bench/bench_advice.dart';
import 'package:PiliPlus/services/model_bench/model_bench.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:material_ui/material_ui.dart';

class ModelBenchCard extends StatefulWidget {
  const ModelBenchCard({super.key});

  @override
  State<ModelBenchCard> createState() => _ModelBenchCardState();
}

class _ModelBenchCardState extends State<ModelBenchCard> {
  ModelBench? _bench;
  ModelBenchProgress? _progress;
  ModelBenchResult? _result = ModelBench.last;

  @override
  void dispose() {
    // leaving the page ends the test: its numbers need the app in front
    // and nothing else running, which a page left behind no longer ensures
    _bench?.cancel('离开了页面');
    _bench = null;
    super.dispose();
  }

  Future<void> _start() async {
    final bench = ModelBench(
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );
    setState(() {
      _bench = bench;
      _progress = (fraction: 0, label: '准备中');
    });
    final result = await bench.run();
    // a test cut short by leaving the page is not kept: the last full one
    // stays what the page shows
    if (!mounted) return;
    if (result.complete || _result == null) {
      await ModelBench.remember(result);
    }
    setState(() {
      _bench = null;
      _progress = null;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    final running = _bench != null;
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: const Text('性能测试'),
          subtitle: const Text(
            '测一测本机运行已下载的模型有多快，并给出选择建议。'
            '转录和翻译会同时运行，约需一分钟，不会下载任何东西。',
          ),
          titleTextStyle: theme.textTheme.titleMedium,
        ),
        if (running) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '测试中，请勿离开此页 · ${_progress?.label ?? ''}',
                  style: TextStyle(fontSize: 12, color: outline),
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(value: _progress?.fraction),
              ],
            ),
          ),
        ] else if (result != null)
          ..._resultView(theme, result),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: running
              ? FilledButton.tonal(
                  onPressed: () => _bench?.cancel(),
                  child: const Text('取消测试'),
                )
              : FilledButton.tonal(
                  onPressed: _start,
                  child: Text(result == null ? '开始测试' : '重新测试'),
                ),
        ),
      ],
    );
  }

  List<Widget> _resultView(ThemeData theme, ModelBenchResult result) {
    final outline = theme.colorScheme.outline;
    final advice = benchAdvice(result);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          '上次测试：${DateFormatUtils.longFormatD.format(result.at)}',
          style: TextStyle(fontSize: 12, color: outline),
        ),
      ),
      for (final line in advice)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1, right: 8),
                child: Icon(
                  switch (line.level) {
                    BenchAdviceLevel.good => Icons.check_circle_outline,
                    BenchAdviceLevel.warn => Icons.error_outline,
                    BenchAdviceLevel.bad => Icons.cancel_outlined,
                    BenchAdviceLevel.info => Icons.info_outline,
                  },
                  size: 18,
                  color: switch (line.level) {
                    BenchAdviceLevel.good => theme.colorScheme.primary,
                    BenchAdviceLevel.warn => theme.colorScheme.tertiary,
                    BenchAdviceLevel.bad => theme.colorScheme.error,
                    BenchAdviceLevel.info => outline,
                  },
                ),
              ),
              Expanded(
                child: Text(line.text, style: const TextStyle(fontSize: 14)),
              ),
            ],
          ),
        ),
      Theme(
        // the expansion's own dividers would double the page's
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: const Text('详细数据', style: TextStyle(fontSize: 14)),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          expandedAlignment: Alignment.centerLeft,
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in benchDetails(result))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$label：',
                        style: TextStyle(color: outline),
                      ),
                      TextSpan(text: value),
                    ],
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    ];
  }
}
