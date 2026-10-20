/// LibrePili — YouTube subscriptions.
///
/// The list lives on this device; YouTube has no idea it exists. The feed is
/// built by asking every followed channel for its uploads, a few channels at
/// a time, and merging them into one list ordered by publish time (user
/// 2026-10-19: all channels each refresh, newest first). A hundred channels
/// is still a hundred requests — the price of not having an account.
///
/// With 「订阅刷新时每个频道使用独立身份」 on (the default) each channel gets
/// a source of its own: a new connection and a visitorData minted for it
/// (one `visitor_id` POST), so a channel costs two requests instead of one.
/// Off, every channel goes over the page's one source and connection, which
/// sends WEB browse requests with no visitorData at all (only the stream
/// identity's is ever minted; YouTube hands each answer a new one, which
/// is not kept). The IP is the same either way.
library;

import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/services/youtube/yt_subscription_feed.dart';
import 'package:PiliPlus/services/youtube/yt_subscription_io.dart';
import 'package:PiliPlus/services/youtube/yt_subscriptions.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/storage_utils.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

class YtSubscriptionsPage extends StatefulWidget {
  const YtSubscriptionsPage({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  State<YtSubscriptionsPage> createState() => _YtSubscriptionsPageState();
}

class _YtSubscriptionsPageState extends State<YtSubscriptionsPage> {
  final _source = YtDirectSource.create();

  /// Channels asked at once. Enough that a long list does not take minutes,
  /// few enough not to look like a burst.
  static const _concurrency = 4;

  /// Newest uploads kept per channel, so one prolific channel cannot fill the
  /// whole feed.
  static const _perChannel = 6;

  var _subs = <YtSubscription>[];
  var _feed = <(YtSubscription, YtSearchItem)>[];
  var _loading = false;
  var _failed = 0;

  /// Channels the last (or the running) refresh asks about, and how many of
  /// them have answered so far.
  var _asked = 0;
  var _answered = 0;

  /// A refresh asked for while one runs: run again once it ends, with the
  /// list as it is then.
  var _again = false;
  late final _gridDelegate = Grid.videoCardHDelegate();
  StreamSubscription? _boxSub;

  @override
  void initState() {
    super.initState();
    _subs = YtSubscriptions.all();
    if (_subs.isNotEmpty) _refresh();
    // a channel followed from a video page or imported while this
    // (kept-alive) page is up must bring its uploads in — the feed itself
    // on a page that showed 「还没有订阅的频道」
    _boxSub = YtSubscriptions.watch().listen((_) {
      if (!mounted) return;
      final subs = YtSubscriptions.all();
      final known = {for (final s in _subs) s.channelId};
      final added = subs.any((s) => !known.contains(s.channelId));
      setState(() {
        _subs = subs;
        // an unfollow takes that channel's uploads out at once, with no
        // network asked
        _feed = _followed(_feed);
      });
      if (added) _refresh();
    });
  }

  @override
  void dispose() {
    _boxSub?.cancel();
    // a refresh under way still asks with it: it closes it when it ends
    if (!_loading) _source.close();
    super.dispose();
  }

  /// [feed] without the uploads of channels no longer followed.
  List<(YtSubscription, YtSearchItem)> _followed(
    List<(YtSubscription, YtSearchItem)> feed,
  ) {
    final ids = {for (final s in _subs) s.channelId};
    return [
      for (final e in feed)
        if (ids.contains(e.$1.channelId)) e,
    ];
  }

  /// One channel's newest uploads, or null when it could not be fetched.
  ///
  /// [health] is the refresh's: one transient streak for all its channels,
  /// so with YouTube not answering the retries are spent once, not again
  /// for every channel (about a minute each).
  Future<List<YtSearchItem>?> _fetch(
    YtSubscription sub,
    bool isolate,
    Map<String, YtSourceHealth> health,
  ) async {
    final source = isolate ? YtDirectSource.create() : _source;
    try {
      if (isolate) {
        // the browse calls go out as WEB; a failed mint still asks, without
        // one, over this channel's own connection
        await source.client.ensureVisitorData(YtClients.web);
      }
      final result = await YtSourceRouter(source, health: health).run(
        (s) => (s as YtDirectSource).channelVideos(sub.channelId),
      );
      if (!result.ok || result.value == null) return null;
      return result.value!.items.take(_perChannel).toList();
    } catch (_) {
      // one channel failing is a count in the header, not a failed refresh
      return null;
    } finally {
      if (isolate) source.close();
    }
  }

  Future<void> _refresh() async {
    if (_loading) {
      _again = true;
      return;
    }
    _again = false;
    final subs = YtSubscriptions.all();
    final isolate = Pref.ytSubIsolate;
    final health = <String, YtSourceHealth>{};
    setState(() {
      _loading = true;
      _failed = 0;
      _asked = subs.length;
      _answered = 0;
    });
    final answers = await runYtPooled(subs, _concurrency, (sub) async {
      // the page is gone: no channel more is asked about
      if (!mounted) return null;
      final items = await _fetch(sub, isolate, health);
      if (mounted) setState(() => _answered++);
      return items;
    });
    if (!mounted) {
      // the page closed during the refresh, which no longer asks
      _source.close();
      return;
    }
    final collected = <(YtSubscription, YtSearchItem)>[
      for (final (i, items) in answers.indexed)
        for (final item in items ?? const <YtSearchItem>[]) (subs[i], item),
    ];
    setState(() {
      _subs = YtSubscriptions.all();
      // a channel unfollowed while it was asked about stays out
      _feed = _followed(
        sortYtFeedByAge(collected, (e) => e.$2.publishedText),
      );
      _loading = false;
      _failed = answers.where((e) => e == null).length;
    });
    if (_again) _refresh();
  }

  // ------------------------------------------------------ import / export

  Future<void> _import() async {
    final picked = await FilePicker.pickFile(
      type: .custom,
      allowedExtensions: const ['json', 'csv', 'txt'],
    );
    if (picked == null) return;
    final YtSubscriptionFile file;
    try {
      file = parseYtSubscriptionFile(await picked.xFile.readAsString());
    } catch (e) {
      SmartDialog.showToast(
        '导入失败：${e is FormatException ? e.message : e}',
      );
      return;
    }
    final (:added, :skipped) = await YtSubscriptions.merge(file.channels);
    SmartDialog.showToast(
      [
        '新增 $added 个频道',
        if (skipped + file.duplicates > 0)
          '${skipped + file.duplicates} 个已在列表中',
        if (file.invalid > 0) '${file.invalid} 个无效已跳过',
        if (file.otherService > 0) '${file.otherService} 个非 YouTube 已跳过',
      ].join('，'),
    );
    // the channels added are brought in by the box watcher
  }

  void _export() {
    final subs = YtSubscriptions.all();
    if (subs.isEmpty) {
      SmartDialog.showToast('还没有订阅的频道');
      return;
    }
    final json = toNewPipeSubscriptionsJson(
      [for (final s in subs) (channelId: s.channelId, name: s.name)],
      appVersion: 'LibrePili ${BuildConfig.versionName}',
      appVersionInt: BuildConfig.versionCode,
    );
    StorageUtils.saveBytes2File(
      name:
          'librepili_youtube_subscriptions_'
          '${DateFormat('yyyyMMddHHmmss').format(DateTime.now())}.json',
      bytes: utf8.encode(json),
      allowedExtensions: const ['json'],
      savedMessage: '已导出 ${subs.length} 个频道',
    );
  }

  Widget _menu() => PopupMenuButton<VoidCallback>(
    icon: const Icon(Icons.more_vert),
    onSelected: (action) => action(),
    itemBuilder: (context) => [
      PopupMenuItem(
        value: _import,
        child: const Text('导入订阅（NewPipe / PipePipe）'),
      ),
      PopupMenuItem(
        value: _export,
        child: const Text('导出订阅（NewPipe 格式）'),
      ),
    ],
  );

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
                _menu(),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '还没有订阅的频道。\n在视频页点「订阅」即可加入，订阅只保存在本机。',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _import,
                child: const Text('导入订阅（NewPipe / PipePipe）'),
              ),
            ],
          ),
        ),
      );
    }
    if (_feed.isEmpty && _loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              '$_answered / $_asked 个频道',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
            ),
          ],
        ),
      );
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

  String get _status {
    if (_loading) return '正在刷新 $_answered / $_asked 个频道';
    final ok = _asked - _failed;
    return '已刷新 $ok / $_asked 个频道，按发布时间排列'
        '${_failed > 0 ? ' · $_failed 个获取失败' : ''}';
  }

  Widget _header(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _status,
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
        // the page embedded in the home tabs has no app bar to hold it
        if (!widget.showAppBar) _menu(),
      ],
    ),
  );
}
