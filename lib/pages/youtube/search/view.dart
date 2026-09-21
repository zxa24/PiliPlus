/// LibrePili — YouTube, stage 3: searching and opening a result.
///
/// The first place in the app where YouTube is reachable without a link.
library;

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtSearchPage extends StatefulWidget {
  const YtSearchPage({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  State<YtSearchPage> createState() => _YtSearchPageState();
}

class _YtSearchPageState extends State<YtSearchPage> {
  final _source = YtDirectSource.create();
  late final _router = YtSourceRouter(_source);
  final _input = TextEditingController();

  var _items = <YtSearchItem>[];
  String? _continuation;
  var _loading = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _search([String? query]) async {
    final text = (query ?? _input.text).trim();
    if (text.isEmpty) return;

    // a pasted link is not a search: open it
    if (tryParseYouTubeVideoId(text) case final videoId?) {
      Get.toNamed('/ytVideo', parameters: {'id': videoId});
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _items = const [];
      _continuation = null;
    });
    final result = await _router.run((s) => (s as YtDirectSource).search(text));
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
    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(title: const Text('YouTube'))
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _input,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              decoration: InputDecoration(
                hintText: '搜索 YouTube，或粘贴链接',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _search,
                ),
              ),
            ),
          ),
          Expanded(child: _results(theme)),
        ],
      ),
    );
  }

  Widget _results(ThemeData theme) {
    if (_error case final error?) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error, textAlign: TextAlign.center),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Text(
                '输入关键词开始搜索',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 300) _more();
        return false;
      },
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _items.length + (_continuation == null ? 0 : 1),
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return _tile(theme, _items[index]);
        },
      ),
    );
  }

  Widget _tile(ThemeData theme, YtSearchItem item) => InkWell(
    onTap: () =>
        Get.toNamed('/ytVideo', parameters: {'id': item.videoId}),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          alignment: Alignment.bottomRight,
          children: [
            NetworkImgLayer(
              width: 160,
              height: 90,
              src: item.bestThumbnail?.url,
            ),
            if (item.duration case final duration?)
              Container(
                margin: const EdgeInsets.all(4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 1,
                ),
                color: Colors.black54,
                child: Text(
                  DurationUtils.formatDuration(duration.inSeconds),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                [
                  item.author,
                  ?item.viewCountText,
                  ?item.publishedText,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
