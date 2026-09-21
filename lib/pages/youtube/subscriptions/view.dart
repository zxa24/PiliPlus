/// LibrePili — YouTube subscriptions.
///
/// The list lives on this device; YouTube has no idea it exists. The feed is
/// built by asking each followed channel for its uploads and interleaving
/// them, which is also why it is capped: a hundred channels would be a
/// hundred requests.
library;

import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_subscriptions.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtSubscriptionsPage extends StatefulWidget {
  const YtSubscriptionsPage({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  State<YtSubscriptionsPage> createState() => _YtSubscriptionsPageState();
}

class _YtSubscriptionsPageState extends State<YtSubscriptionsPage> {
  final _source = YtDirectSource.create();
  late final _router = YtSourceRouter(_source);

  /// How many channels one refresh will ask about. Each is a request, and a
  /// feed that takes a minute to appear is not a feed.
  static const _channelsPerRefresh = 12;

  /// Newest uploads kept per channel, so one prolific channel cannot fill the
  /// whole feed.
  static const _perChannel = 6;

  var _subs = <YtSubscription>[];
  var _feed = <(YtSubscription, YtSearchItem)>[];
  var _loading = false;
  var _failed = 0;
  late final _gridDelegate = Grid.videoCardHDelegate();

  @override
  void initState() {
    super.initState();
    _subs = YtSubscriptions.all();
    if (_subs.isNotEmpty) _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = 0;
    });
    final subs = YtSubscriptions.all();
    final collected = <(YtSubscription, YtSearchItem)>[];
    var failed = 0;
    for (final sub in subs.take(_channelsPerRefresh)) {
      final result = await _router.run(
        (s) => (s as YtDirectSource).channelVideos(sub.channelId),
      );
      if (!mounted) return;
      if (result.ok && result.value != null) {
        for (final item in result.value!.items.take(_perChannel)) {
          collected.add((sub, item));
        }
      } else {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _subs = subs;
      _feed = collected;
      _loading = false;
      _failed = failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(
              title: const Text('YouTube 订阅'),
              actions: [
                IconButton(
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            )
          : null,
      body: _body(theme),
    );
  }

  Widget _body(ThemeData theme) {
    if (_subs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            '还没有订阅的频道。\n在视频页点「订阅」即可加入，订阅只保存在本机。',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.outline),
          ),
        ),
      );
    }
    if (_feed.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            sliver: SliverToBoxAdapter(child: _header(theme)),
          ),
          SliverGrid(
            gridDelegate: _gridDelegate,
            delegate: SliverChildBuilderDelegate(
              childCount: _feed.length,
              (context, index) {
                final (_, item) = _feed[index];
                return YtVideoTile(
                  item: item,
                  onTap: () =>
                      Get.toNamed('/ytVideo', parameters: {'id': item.videoId}),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '${_subs.length} 个频道'
            '${_subs.length > _channelsPerRefresh ? '（本次刷新前 $_channelsPerRefresh 个）' : ''}'
            '${_failed > 0 ? ' · $_failed 个获取失败' : ''}',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.outline,
            ),
          ),
        ),
        if (_loading)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    ),
  );
}
