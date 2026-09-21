/// LibrePili — YouTube search, laid out like bilibili's.
///
/// The box lives in the app bar and the page under it is the history, the
/// same chips with the same 无痕 switch and the same 清空. Results are a
/// page of their own, as they are there — typing and reading are different
/// things and the app has always treated them that way.
///
/// What is missing is missing on purpose: 大家都在搜 and 搜索发现 are
/// bilibili endpoints, and YouTube's suggestion endpoint would send every
/// keystroke to Google, which is not a trade this app makes quietly.
library;

import 'package:PiliPlus/common/widgets/disabled_icon.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/sliver_wrap.dart';
import 'package:PiliPlus/common/widgets/view_insets_safe_area.dart';
import 'package:PiliPlus/pages/search/widgets/search_text.dart';
import 'package:PiliPlus/pages/youtube/search/controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtSearchPage extends StatefulWidget {
  const YtSearchPage({super.key});

  @override
  State<YtSearchPage> createState() => _YtSearchPageState();
}

class _YtSearchPageState extends State<YtSearchPage> {
  final _tag = 'yt';
  late final YtSearchController _controller = Get.put(
    YtSearchController(),
    tag: _tag,
  );
  late ThemeData theme;
  late EdgeInsets padding;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    theme = Theme.of(context);
    padding = MediaQuery.viewPaddingOf(context);
  }

  @override
  void dispose() {
    Get.delete<YtSearchController>(tag: _tag);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SimpleScaffold(
    appBar: _appBar,
    body: Padding(
      padding: EdgeInsets.only(left: padding.left, right: padding.right),
      child: ViewInsetsSafeArea(
        child: CustomScrollView(
          slivers: [
            _history,
            SliverPadding(padding: EdgeInsets.only(bottom: padding.bottom)),
          ],
        ),
      ),
    ),
  );

  PreferredSizeWidget get _appBar => AppBar(
    shape: Border(
      bottom: BorderSide(
        color: theme.dividerColor.withValues(alpha: 0.08),
        width: 1,
      ),
    ),
    actions: [
      IconButton(
        tooltip: '清空',
        icon: const Icon(Icons.clear, size: 22),
        onPressed: _controller.onClear,
      ),
      IconButton(
        tooltip: '搜索',
        icon: const Icon(Icons.search, size: 22),
        onPressed: _controller.submit,
      ),
      const SizedBox(width: 10),
    ],
    title: TextField(
      autofocus: true,
      focusNode: _controller.focusNode,
      controller: _controller.controller,
      textInputAction: TextInputAction.search,
      decoration: const InputDecoration(
        visualDensity: VisualDensity.standard,
        hintText: '搜索 YouTube，或粘贴链接',
        border: InputBorder.none,
      ),
      onSubmitted: _controller.submit,
    ),
  );

  late final _chipExtent = 16 + MediaQuery.textScalerOf(context).scale(14);

  Widget get _history => Obx(() {
    final list = _controller.historyList;
    if (list.isEmpty) {
      return const SliverToBoxAdapter();
    }
    final secondary = theme.colorScheme.secondary;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 25),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Text(
                    '搜索历史',
                    strutStyle: const StrutStyle(leading: 0, height: 1),
                    style: theme.textTheme.titleMedium!.copyWith(
                      height: 1,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _recordBtn,
                  const Spacer(),
                  TextButton.icon(
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                    onPressed: _controller.onClearHistory,
                    icon: Icon(
                      Icons.clear_all_outlined,
                      size: 18,
                      color: secondary,
                    ),
                    label: Text(
                      '清空',
                      style: TextStyle(height: 1, color: secondary),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverFixedWrap(
            mainAxisExtent: _chipExtent,
            spacing: 8,
            runSpacing: 8,
            delegate: SliverChildBuilderDelegate(
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: false,
              childCount: list.length,
              (context, index) => SearchText(
                text: list[index],
                onTap: _controller.onClickKeyword,
                onLongPress: _controller.onLongSelect,
                fontSize: 14,
                height: 1,
                padding: const EdgeInsets.fromLTRB(11, 8, 11, 0),
              ),
            ),
          ),
        ],
      ),
    );
  });

  Widget get _recordBtn => Obx(() {
    final enable = _controller.recordSearchHistory.value;
    return IconButton(
      iconSize: 22,
      tooltip: enable ? '记录搜索' : '无痕搜索',
      icon: DisabledIcon(
        disable: !enable,
        child: Icon(
          Icons.history,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
        ),
      ),
      style: const ButtonStyle(
        visualDensity: VisualDensity.comfortable,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      onPressed: _controller.toggleRecord,
    );
  });
}
