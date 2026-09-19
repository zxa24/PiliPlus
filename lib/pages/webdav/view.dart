import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/common/widgets/view_insets_safe_area.dart';
import 'package:PiliPlus/pages/webdav/webdav.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

class WebDavSettingPage extends StatefulWidget {
  const WebDavSettingPage({
    super.key,
    this.showAppBar = true,
  });

  final bool showAppBar;

  @override
  State<WebDavSettingPage> createState() => _WebDavSettingPageState();
}

class _WebDavSettingPageState extends State<WebDavSettingPage> {
  final _uriCtr = TextEditingController(text: Pref.webdavUri);
  final _usernameCtr = TextEditingController(text: Pref.webdavUsername);
  final _passwordCtr = TextEditingController(text: Pref.webdavPassword);
  final _directoryCtr = TextEditingController(text: Pref.webdavDirectory);
  bool _obscureText = true;

  @override
  void dispose() {
    _uriCtr.dispose();
    _usernameCtr.dispose();
    _passwordCtr.dispose();
    _directoryCtr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showAppBar = widget.showAppBar;
    final padding = MediaQuery.viewPaddingOf(context);
    return SimpleScaffold(
      appBar: showAppBar ? AppBar(title: const Text('WebDAV 设置')) : null,
      body: ViewInsetsSafeArea(
        child: ListView(
          padding: padding.copyWith(
            top: 20,
            left: 20 + (showAppBar ? padding.left : 0),
            right: 20 + (showAppBar ? padding.right : 0),
            bottom: padding.bottom + 100,
          ),
          children: [
            TextField(
              controller: _uriCtr,
              decoration: const InputDecoration(
                labelText: '地址',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _usernameCtr,
              decoration: const InputDecoration(
                labelText: '用户',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _passwordCtr,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: '密码',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscureText = !_obscureText),
                  icon: _obscureText
                      ? const Icon(Icons.visibility)
                      : const Icon(Icons.visibility_off),
                ),
              ),
              obscureText: _obscureText,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _directoryCtr,
              decoration: const InputDecoration(
                labelText: '路径',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      shape: const RoundedRectangleBorder(
                        borderRadius: Style.mdRadius,
                      ),
                    ),
                    onPressed: () async {
                      final includeCredentials = await showConfirmDialog(
                        context: context,
                        title: const Text('备份中包含凭据？'),
                        content: const Text(
                          'WebDAV 用户名/密码、空降助手用户 ID。点「取消」则不包含（推荐）',
                        ),
                      );
                      WebDav().backup(includeCredentials: includeCredentials);
                    },
                    child: const Text('备份设置'),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      shape: const RoundedRectangleBorder(
                        borderRadius: Style.mdRadius,
                      ),
                    ),
                    onPressed: () async {
                      final confirmed = await showConfirmDialog(
                        context: context,
                        title: const Text('恢复设置'),
                        content: const Text(
                          '将用 WebDAV 上的备份替换本机的全部设置、本地关注和本地收藏。'
                          '恢复前的数据会自动保存，可用「恢复到导入前」撤回',
                        ),
                      );
                      if (!confirmed || !context.mounted) return;
                      WebDav().restore(
                        askCredentials: () => showConfirmDialog(
                          context: context,
                          title: const Text('使用备份中的凭据？'),
                          content: const Text(
                            '备份含有 WebDAV 用户名/密码或空降助手用户 ID。点「取消」保留本机的',
                          ),
                        ),
                      );
                    },
                    child: const Text('恢复设置'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () async {
                final confirmed = await showConfirmDialog(
                  context: context,
                  title: const Text('恢复到导入前'),
                  content: const Text('撤回最近一次恢复/导入，回到那之前的设置、本地关注和本地收藏'),
                );
                if (confirmed) WebDav().restoreSnapshot();
              },
              child: const Text('恢复到导入前'),
            ),
          ],
        ),
      ),
      fab: Padding(
        padding: .only(
          right: kFloatingActionButtonMargin + (showAppBar ? padding.right : 0),
          bottom: kFloatingActionButtonMargin + padding.bottom,
        ),
        child: ViewInsetsSafeArea(
          child: FloatingActionButton(
            child: const Icon(Icons.save),
            onPressed: () async {
              await GStorage.setting.putAll({
                SettingBoxKey.webdavUri: _uriCtr.text,
                SettingBoxKey.webdavUsername: _usernameCtr.text,
                SettingBoxKey.webdavPassword: _passwordCtr.text,
                SettingBoxKey.webdavDirectory: _directoryCtr.text,
              });
              if (_uriCtr.text.isEmpty) {
                return;
              }
              try {
                final res = await WebDav().init();
                if (res.first) {
                  SmartDialog.showToast('配置成功');
                } else {
                  SmartDialog.showToast('配置失败: ${res.second}');
                }
              } catch (e) {
                SmartDialog.showToast('配置失败: ${e.toString()}');
                return;
              }
            },
          ),
        ),
      ),
    );
  }
}
