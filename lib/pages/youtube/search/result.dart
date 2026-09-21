/// LibrePili — YouTube search results, as a page of their own.
///
/// bilibili puts the keyword in the app bar and lets a tap on it take you
/// back to editing; the results sit in the same responsive grid that the
/// rest of the app uses, so a wide window gets columns instead of one very
/// long line of cards. This does both.
///
/// There is one tab where bilibili has six: a YouTube search returns videos,
/// channels and playlists in one stream and this reads the videos out of it.
/// A tab bar with a single tab is not alignment, it is decoration.
library;

import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtSearchResultPage extends StatefulWidget {
  const YtSearchResultPage({super.key});

  @override
  State<YtSearchResultPage> createState() => _YtSearchResultPageState();
}

class _YtSearchResultPageState extends State<YtSearchResultPage> {
  late final String keyword = Get.parameters['keyword'] ?? '';
  final _source = YtDirectSource.create();
  late final _router = YtSourceRouter(_source);
  late final _gridDelegate = Grid.videoCardHDelegate();

  var _items = <YtSearchItem>[];
  String? _continuation;
  var _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await _router.run(
      (s) => (s as YtDirectSource).search(keyword),
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.ok && result.value != null) {
        _items = result.value!.items;
        _continuation = result.value!.continuation;
      } else {
        _error = result.verdict.toString();
      }
    });
  }

  Future<void> _more() async {
    final token = _continuation;
    if (token == null || _loading) return;
    setState(() => _loading = true);
    final result = await _router.run(
      (s) => (s as YtDirectSource).searchContinuation(token),
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.ok && result.value != null) {
        _items = [..._items, ...result.value!.items];
        _continuation = result.value!.continuation;
      } else {
        _continuation = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        shape: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
        title: GestureDetector(
          // the same gesture as the bilibili result page: the keyword is the
          // way back into the box that produced it
          onTap: () => Get.offNamed(
            '/ytSearch',
            parameters: {'keyword': keyword},
          ),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: double.infinity,
            child: Text(
              keyword,
              style: theme.textTheme.titleMedium,
              maxLines: 1,
            ),
          ),
        ),
      ),
      body: ViewSafeArea(child: _body(theme)),
    );
  }

  Widget _body(ThemeData theme) {
    if (_error case final error?) {
      return HttpError(errMsg: error, onReload: _search);
    }
    if (_items.isEmpty) {
      return Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Text(
                '没有找到「$keyword」',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 300) _more();
        return false;
      },
      child: CustomScrollView(
        slivers: [
          SliverGrid(
            gridDelegate: _gridDelegate,
            delegate: SliverChildBuilderDelegate(
              childCount: _items.length,
              (context, index) {
                final item = _items[index];
                return YtVideoTile(
                  item: item,
                  onTap: () => Get.toNamed(
                    '/ytVideo',
                    parameters: {'id': item.videoId},
                  ),
                );
              },
            ),
          ),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}
