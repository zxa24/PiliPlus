import 'dart:async';

import 'package:PiliPlus/common/widgets/video_card/video_card_h.dart';
import 'package:PiliPlus/pages/local/fav_sheet.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// Local favorite folders: create / rename / delete / drag to reorder.
class LocalFavsTab extends StatefulWidget {
  const LocalFavsTab({super.key});

  @override
  State<LocalFavsTab> createState() => _LocalFavsTabState();
}

class _LocalFavsTabState extends State<LocalFavsTab>
    with AutomaticKeepAliveClientMixin {
  List<LocalFavFolder> _folders = LocalLibrary.folders();
  final _subs = <StreamSubscription>[];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    void refresh(_) {
      if (mounted) setState(() => _folders = LocalLibrary.folders());
    }

    _subs
      ..add(LocalLibrary.watchFolders().listen(refresh))
      ..add(LocalLibrary.watchFavs().listen(refresh));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _create() async {
    final name = await showFolderNameDialog(context);
    if (name != null) await LocalLibrary.createFolder(name);
  }

  Future<void> _rename(LocalFavFolder folder) async {
    final name = await showFolderNameDialog(
      context,
      title: '重命名收藏夹',
      initial: folder.title,
    );
    if (name != null) await LocalLibrary.renameFolder(folder.id, name);
  }

  Future<void> _delete(LocalFavFolder folder) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除收藏夹'),
        content: Text('删除「${folder.title}」？只在此收藏夹中的内容也会被移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await LocalLibrary.deleteFolder(folder.id);
  }

  void _onReorder(int oldIndex, int newIndex) {
    final list = [..._folders];
    list.insert(newIndex, list.removeAt(oldIndex));
    setState(() => _folders = list);
    LocalLibrary.reorderFolders([for (final f in list) f.id]);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.small(
        heroTag: null,
        tooltip: '新建收藏夹',
        onPressed: _create,
        child: const Icon(Icons.add),
      ),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: _folders.length,
        onReorderItem: _onReorder,
        itemBuilder: (context, index) {
          final folder = _folders[index];
          final isDefault = folder.id == LocalLibrary.defaultFolderId;
          return ListTile(
            key: ValueKey(folder.id),
            leading: const Icon(Icons.folder_outlined),
            title: Text(folder.title),
            subtitle: Text(
              '${LocalLibrary.folderCount(folder.id)} 个内容',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
            ),
            onTap: () => Get.to(() => LocalFavFolderPage(folder: folder)),
            trailing: PopupMenuButton<int>(
              icon: const Icon(Icons.more_vert, size: 20),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 0, child: Text('重命名')),
                if (!isDefault)
                  const PopupMenuItem(value: 1, child: Text('删除')),
              ],
              onSelected: (v) => v == 0 ? _rename(folder) : _delete(folder),
            ),
          );
        },
      ),
    );
  }
}

enum _SortType {
  favTime('收藏时间'),
  pubTime('发布时间'),
  title('标题');

  final String label;
  const _SortType(this.label);
}

/// Items of one local folder, with search and sort.
class LocalFavFolderPage extends StatefulWidget {
  const LocalFavFolderPage({super.key, required this.folder});

  final LocalFavFolder folder;

  @override
  State<LocalFavFolderPage> createState() => _LocalFavFolderPageState();
}

class _LocalFavFolderPageState extends State<LocalFavFolderPage> {
  late List<LocalFavItem> _items = LocalLibrary.folderItems(widget.folder.id);
  String _query = '';
  _SortType _sort = _SortType.favTime;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = LocalLibrary.watchFavs().listen((_) {
      if (mounted) {
        setState(() => _items = LocalLibrary.folderItems(widget.folder.id));
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  List<LocalFavItem> get _visible {
    final q = _query.toLowerCase();
    final list = q.isEmpty
        ? [..._items]
        : _items
              .where(
                (e) =>
                    e.title.toLowerCase().contains(q) ||
                    e.author.toLowerCase().contains(q),
              )
              .toList();
    switch (_sort) {
      case _SortType.favTime:
        list.sort((a, b) => b.time.compareTo(a.time));
      case _SortType.pubTime:
        list.sort(
          (a, b) => ((b.data['created'] as int?) ?? 0).compareTo(
            (a.data['created'] as int?) ?? 0,
          ),
        );
      case _SortType.title:
        list.sort((a, b) => a.title.compareTo(b.title));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _visible;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folder.title),
        actions: [
          PopupMenuButton<_SortType>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => [
              for (final s in _SortType.values)
                PopupMenuItem(value: s, child: Text('按${s.label}')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: '搜索标题或 UP 主（${_items.length}）',
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text(
                      _items.isEmpty ? '收藏夹是空的' : '没有匹配的内容',
                      style: TextStyle(color: theme.colorScheme.outline),
                    ),
                  )
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final item = list[index];
                      return VideoCardH(
                        videoItem: item.toVideoItem(),
                        onRemove: () => LocalLibrary.removeFromFolder(
                          item.key,
                          widget.folder.id,
                        ),
                        removeTitle: '移出收藏夹',
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
