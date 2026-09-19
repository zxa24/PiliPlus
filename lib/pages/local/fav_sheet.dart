import 'package:PiliPlus/services/local_library.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// Picks which local favorite folders [key] belongs to.
/// Returns the new favorite state, or null if dismissed.
Future<bool?> showLocalFavSheet(
  BuildContext context, {
  required String key,
  required Map<String, dynamic> data,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => _LocalFavSheet(itemKey: key, data: data),
  );
}

/// Asks for a folder name; returns the trimmed name or null.
Future<String?> showFolderNameDialog(
  BuildContext context, {
  String title = '新建收藏夹',
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _FolderNameDialog(title: title, initial: initial),
  );
}

/// Owns its text controller, so it is disposed with the dialog (after the
/// closing animation) instead of when the dialog is popped.
class _FolderNameDialog extends StatefulWidget {
  const _FolderNameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 30,
        decoration: const InputDecoration(hintText: '收藏夹名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isEmpty) {
              SmartDialog.showToast('名称不能为空');
              return;
            }
            Navigator.of(context).pop(name);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _LocalFavSheet extends StatefulWidget {
  const _LocalFavSheet({required this.itemKey, required this.data});

  final String itemKey;
  final Map<String, dynamic> data;

  @override
  State<_LocalFavSheet> createState() => _LocalFavSheetState();
}

class _LocalFavSheetState extends State<_LocalFavSheet> {
  late List<LocalFavFolder> _folders = LocalLibrary.folders();
  late final Set<int> _selected = LocalLibrary.foldersOf(widget.itemKey);

  Future<void> _create() async {
    final name = await showFolderNameDialog(context);
    if (name == null) return;
    final folder = await LocalLibrary.createFolder(name);
    if (!mounted) return;
    setState(() {
      _folders = LocalLibrary.folders();
      _selected.add(folder.id);
    });
  }

  Future<void> _done() async {
    await LocalLibrary.setFolders(widget.itemKey, widget.data, _selected);
    SmartDialog.showToast(_selected.isEmpty ? '已取消本地收藏' : '已保存到本地收藏');
    if (mounted) Navigator.of(context).pop(_selected.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text('添加到本地收藏夹', style: theme.textTheme.titleMedium),
            trailing: TextButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建'),
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _folders.length,
              itemBuilder: (context, index) {
                final folder = _folders[index];
                return CheckboxListTile(
                  value: _selected.contains(folder.id),
                  title: Text(folder.title),
                  subtitle: Text('${LocalLibrary.folderCount(folder.id)} 个内容'),
                  onChanged: (value) => setState(() {
                    value == true
                        ? _selected.add(folder.id)
                        : _selected.remove(folder.id);
                  }),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _done, child: const Text('完成')),
            ),
          ),
        ],
      ),
    );
  }
}
