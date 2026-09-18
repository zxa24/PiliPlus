import 'dart:async';

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// Locally followed UPs, searchable, newest first.
class LocalFollowsTab extends StatefulWidget {
  const LocalFollowsTab({super.key});

  @override
  State<LocalFollowsTab> createState() => _LocalFollowsTabState();
}

class _LocalFollowsTabState extends State<LocalFollowsTab>
    with AutomaticKeepAliveClientMixin {
  List<LocalFollow> _all = LocalLibrary.followList();
  String _query = '';
  StreamSubscription? _sub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _sub = LocalLibrary.watchFollows().listen((_) {
      if (mounted) setState(() => _all = LocalLibrary.followList());
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _unfollow(LocalFollow f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消本地关注'),
        content: Text('确定不再关注 ${f.name ?? 'UID ${f.mid}'}？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('点错了'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true) await LocalLibrary.unfollow(f.mid);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final q = _query.toLowerCase();
    final list = q.isEmpty
        ? _all
        : _all
              .where(
                (f) =>
                    (f.name ?? '').toLowerCase().contains(q) ||
                    '${f.mid}'.contains(q),
              )
              .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            onChanged: (v) => setState(() => _query = v.trim()),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: '搜索本地关注（${_all.length}）',
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Text(
                    _all.isEmpty ? '还没有本地关注' : '没有匹配的 UP 主',
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                )
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, index) {
                    final f = list[index];
                    return ListTile(
                      onTap: () => Get.toNamed('/member?mid=${f.mid}'),
                      leading: NetworkImgLayer(
                        src: f.face,
                        width: 40,
                        height: 40,
                        type: .avatar,
                      ),
                      title: Text(f.name ?? 'UID ${f.mid}'),
                      subtitle: Text(
                        '关注于 ${_date(f.time)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      trailing: TextButton(
                        onPressed: () => _unfollow(f),
                        child: const Text('已关注'),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static String _date(int sec) {
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}
