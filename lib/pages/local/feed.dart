import 'dart:async';

import 'package:PiliPlus/common/widgets/video_card/video_card_h.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/models/common/member/contribute_type.dart';
import 'package:PiliPlus/models_new/member/search_archive/vlist.dart';
import 'package:PiliPlus/models_new/space/space_archive/item.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:material_ui/material_ui.dart';

/// Latest uploads of locally followed UPs, newest first.
class LocalFeedTab extends StatefulWidget {
  const LocalFeedTab({super.key});

  @override
  State<LocalFeedTab> createState() => _LocalFeedTabState();
}

class _LocalFeedTabState extends State<LocalFeedTab>
    with AutomaticKeepAliveClientMixin {
  static const _perUp = 10;
  static const _concurrency = 2;
  static const _batchDelay = Duration(milliseconds: 400);
  static const _maxItems = 300;

  /// Uploads per UP, kept for the session: opening the tab again or
  /// (un)following someone only fetches the UPs not fetched recently, not
  /// the whole list; pull to refresh fetches everyone.
  static final _cache = <int, ({DateTime at, List<VListItemModel> items})>{};
  static const _cacheTtl = Duration(minutes: 30);

  List<VListItemModel> _items = const [];
  bool _loading = false;
  int _failed = 0;
  String? _firstError;
  int _followCount = 0;
  int _generation = 0;
  Set<int> _mids = const {};
  StreamSubscription? _sub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    // reload only when someone is (un)followed, not on name/avatar updates
    _sub = LocalLibrary.watchFollows().listen((_) {
      final mids = {for (final f in LocalLibrary.followList()) f.mid};
      if (mids.length != _mids.length || !mids.containsAll(_mids)) _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() => _load(force: true);

  Future<void> _load({bool force = false}) async {
    final generation = ++_generation;
    final all = LocalLibrary.followList();
    _mids = {for (final f in all) f.mid};
    _cache.removeWhere((mid, _) => !_mids.contains(mid));
    final now = DateTime.now();
    final follows = [
      for (final f in all)
        if (force ||
            _cache[f.mid] == null ||
            now.difference(_cache[f.mid]!.at) > _cacheTtl)
          f,
    ];
    setState(() {
      _loading = true;
      _followCount = all.length;
      _failed = 0;
    });
    var failed = 0;
    String? firstError;
    for (var i = 0; i < follows.length; i += _concurrency) {
      if (generation != _generation || !mounted) return;
      final batch = follows.skip(i).take(_concurrency);
      // App-side space archive: works anonymously, while the web
      // searchArchive (WBI) is rejected for anonymous requests.
      final responses = await Future.wait([
        for (final f in batch)
          MemberHttp.spaceArchive(type: ContributeType.video, mid: f.mid),
      ]);
      var j = 0;
      for (final f in batch) {
        final res = responses[j++];
        if (res case Success(:final response)) {
          final list = [
            for (final e in (response.item ?? const []).take(_perUp))
              if (e.bvid != null) _toVideoItem(e, f.mid),
          ];
          _cache[f.mid] = (at: now, items: list);
          if (list.isNotEmpty) {
            LocalLibrary.updateFollowInfo(f.mid, name: list.first.owner.name);
          }
        } else {
          failed++;
          firstError ??= '$res';
          debugPrint('local feed: mid ${f.mid} failed: $res');
        }
      }
      if (i + _concurrency < follows.length) {
        await Future.delayed(_batchDelay);
      }
    }
    if (generation != _generation || !mounted) return;
    // a failed UP keeps its earlier uploads, if any
    final result = [for (final f in all) ...?_cache[f.mid]?.items]
      ..sort((a, b) => (b.pubdate ?? 0).compareTo(a.pubdate ?? 0));
    setState(() {
      _items = result.length > _maxItems
          ? result.sublist(0, _maxItems)
          : result;
      _failed = failed;
      _firstError = firstError;
      _loading = false;
    });
  }

  static VListItemModel _toVideoItem(SpaceArchiveItem e, int mid) =>
      VListItemModel.fromJson(
        LocalLibrary.buildFavData(
          aid: int.tryParse(e.param ?? ''),
          bvid: e.bvid,
          title: e.title,
          cover: e.cover,
          durationSec: e.duration > 0 ? e.duration : null,
          pubdate: e.ctime,
          mid: mid,
          author: e.owner.name,
          play: e.stat.view,
          danmaku: e.stat.danmu,
        ),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    if (_followCount == 0 && !_loading) {
      return const _Hint(
        icon: Icons.person_add_alt_outlined,
        text: '还没有本地关注\n在视频页或 UP 主页点「关注」即可添加，无需登录',
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (_loading && _items.isEmpty)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if (_failed > 0)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    '$_failed 位 UP 主的投稿获取失败，下拉重试'
                    '${_firstError == null ? '' : '\n原因：$_firstError'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ),
            if (_items.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: _Hint(icon: Icons.inbox_outlined, text: '暂无投稿'),
              )
            else
              SliverList.builder(
                itemCount: _items.length,
                itemBuilder: (context, index) =>
                    VideoCardH(videoItem: _items[index]),
              ),
          ],
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
