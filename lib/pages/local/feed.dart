import 'dart:async';

import 'package:PiliPlus/common/widgets/video_card/video_card_h.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/models_new/member/search_archive/vlist.dart';
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

  List<VListItemModel> _items = const [];
  bool _loading = false;
  int _failed = 0;
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

  Future<void> _load() async {
    final generation = ++_generation;
    final follows = LocalLibrary.followList();
    _mids = {for (final f in follows) f.mid};
    setState(() {
      _loading = true;
      _followCount = follows.length;
      _failed = 0;
    });
    final result = <VListItemModel>[];
    var failed = 0;
    for (var i = 0; i < follows.length; i += _concurrency) {
      if (generation != _generation || !mounted) return;
      final batch = follows.skip(i).take(_concurrency);
      final responses = await Future.wait([
        for (final f in batch)
          MemberHttp.searchArchive(mid: f.mid, pn: 1, ps: _perUp),
      ]);
      var j = 0;
      for (final f in batch) {
        final res = responses[j++];
        if (res case Success(:final response)) {
          final list = response.list?.vlist ?? const <VListItemModel>[];
          result.addAll(list);
          if (list.isNotEmpty) {
            LocalLibrary.updateFollowInfo(f.mid, name: list.first.owner.name);
          }
        } else {
          failed++;
        }
      }
      if (i + _concurrency < follows.length) {
        await Future.delayed(_batchDelay);
      }
    }
    if (generation != _generation || !mounted) return;
    result.sort((a, b) => (b.pubdate ?? 0).compareTo(a.pubdate ?? 0));
    setState(() {
      _items = result.length > _maxItems
          ? result.sublist(0, _maxItems)
          : result;
      _failed = failed;
      _loading = false;
    });
  }

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
      onRefresh: _load,
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
                    '$_failed 位 UP 主的投稿获取失败（可能触发了风控），下拉重试',
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
