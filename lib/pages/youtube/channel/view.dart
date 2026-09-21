/// LibrePili: a YouTube channel — its header, its uploads, and the follow
/// button that puts it in the local subscription list.
library;

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_subscriptions.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtChannelPageView extends StatefulWidget {
  const YtChannelPageView({super.key});

  @override
  State<YtChannelPageView> createState() => _YtChannelPageViewState();
}

class _YtChannelPageViewState extends State<YtChannelPageView> {
  late final String channelId = Get.parameters['id'] ?? '';
  final _source = YtDirectSource.create();
  late final _router = YtSourceRouter(_source);

  YtChannelInfo? _info;
  var _videos = <YtSearchItem>[];
  String? _continuation;
  var _loading = true;
  String? _error;
  var _subscribed = false;

  @override
  void initState() {
    super.initState();
    _subscribed = YtSubscriptions.isFollowed(channelId);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await _router.run(
      (s) => (s as YtDirectSource).channelPage(channelId),
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.ok && result.value != null) {
        _info = result.value!.info;
        _videos = result.value!.videos.items;
        _continuation = result.value!.videos.continuation;
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
      (s) => (s as YtDirectSource).channelVideos(
        channelId,
        continuation: token,
      ),
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.ok && result.value != null) {
        _videos = [..._videos, ...result.value!.items];
        _continuation = result.value!.continuation;
      } else {
        _continuation = null;
      }
    });
  }

  Future<void> _toggle() async {
    final now = await YtSubscriptions.toggle(
      channelId,
      name: _info?.name ?? channelId,
      avatar: _info?.avatar?.url,
    );
    if (!mounted) return;
    setState(() => _subscribed = now);
    SmartDialog.showToast(now ? '已订阅' : '已取消订阅');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_info?.name ?? '频道')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _load,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          : NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.metrics.extentAfter < 400) _more();
                return false;
              },
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: _videos.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  if (index == 0) return _header(theme);
                  final item = _videos[index - 1];
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
    );
  }

  Widget _header(ThemeData theme) {
    final info = _info;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          if (info?.avatar?.url case final avatar?)
            NetworkImgLayer(
              type: ImageType.avatar,
              width: 56,
              height: 56,
              src: avatar,
            )
          else
            CircleAvatar(
              radius: 28,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              child: Icon(Icons.person, color: theme.colorScheme.outline),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info?.name ?? channelId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  [?info?.subscriberText, ?info?.videoCountText].join('    '),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: _toggle,
            child: Text(_subscribed ? '已订阅' : '订阅'),
          ),
        ],
      ),
    );
  }
}
