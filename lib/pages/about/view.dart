import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/common/widgets/dialog/export_import.dart';
import 'package:PiliPlus/common/widgets/dialog/simple_dialog_option.dart';
import 'package:PiliPlus/common/widgets/flutter/list_tile.dart';
import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/services/local_player.dart';
import 'package:PiliPlus/services/logger.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/update.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  final currentVersion =
      '${BuildConfig.versionName}+${BuildConfig.versionCode}';
  RxString cacheSize = ''.obs;

  late int _pressCount = 0;

  @override
  void initState() {
    super.initState();
    getCacheSize();
  }

  @override
  void dispose() {
    cacheSize.close();
    super.dispose();
  }

  void getCacheSize() {
    CacheManager.loadApplicationCache().then((res) {
      if (mounted) {
        cacheSize.value = CacheManager.formatSize(res);
      }
    });
  }

  void _showDialog() => showDialog(
    context: context,
    builder: (context) => AlertDialog(
      constraints: Style.dialogFixedConstraints,
      content: TextField(
        autofocus: true,
        onSubmitted: (value) {
          Get.back();
          if (value.isNotEmpty) {
            PiliScheme.routePushFromUrl(value);
          }
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const style = TextStyle(fontSize: 15);
    final outline = theme.colorScheme.outline;
    final subTitleStyle = TextStyle(fontSize: 13, color: outline);
    final showAppBar = widget.showAppBar;
    final padding = MediaQuery.viewPaddingOf(context);
    return SimpleScaffold(
      appBar: showAppBar ? AppBar(title: const Text('关于')) : null,
      body: ListView(
        padding: EdgeInsets.only(
          left: showAppBar ? padding.left : 0,
          right: showAppBar ? padding.right : 0,
          bottom: padding.bottom + 100,
        ),
        children: [
          GestureDetector(
            onTap: () {
              if (++_pressCount == 5) {
                _pressCount = 0;
                _showDialog();
              }
            },
            onSecondaryTap: PlatformUtils.isDesktop ? _showDialog : null,
            child: Image.asset(
              width: 150,
              height: 150,
              excludeFromSemantics: true,
              cacheWidth: 150.cacheSize(context),
              Assets.logo,
            ),
          ),
          ListTile(
            title: Text(
              Constants.appName,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium!.copyWith(height: 2),
            ),
            subtitle: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '使用Flutter开发的B站第三方客户端',
                  style: TextStyle(color: outline),
                  semanticsLabel: '与你一起，发现不一样的世界',
                ),
                const Icon(
                  Icons.accessibility_new,
                  semanticLabel: "无障碍适配",
                  size: 18,
                ),
              ],
            ),
          ),
          ListTile(
            onTap: () => Update.checkUpdate(false),
            onLongPress: () => Utils.copyText(currentVersion),
            onSecondaryTap: PlatformUtils.isMobile
                ? null
                : () => Utils.copyText(currentVersion),
            title: const Text('当前版本'),
            leading: const Icon(Icons.commit_outlined),
            trailing: Text(
              currentVersion,
              style: subTitleStyle,
            ),
          ),
          ListTile(
            title: Text(
              '''
Build Time: ${DateFormatUtils.format(BuildConfig.buildTime, format: DateFormatUtils.longFormatDs)}
Commit Hash: ${BuildConfig.commitHash}''',
              style: const TextStyle(fontSize: 14),
            ),
            leading: const Icon(Icons.info_outline),
            onTap: () => PageUtils.launchURL(
              '${Constants.sourceCodeUrl}/commit/${BuildConfig.commitHash}',
            ),
            onLongPress: () => Utils.copyText(BuildConfig.commitHash),
            onSecondaryTap: PlatformUtils.isMobile
                ? null
                : () => Utils.copyText(BuildConfig.commitHash),
          ),
          Divider(
            thickness: 1,
            height: 30,
            color: theme.colorScheme.outlineVariant,
          ),
          ListTile(
            onTap: () => PageUtils.launchURL(Constants.sourceCodeUrl),
            leading: const Icon(Icons.code),
            title: const Text('Source Code'),
            subtitle: Text(Constants.sourceCodeUrl, style: subTitleStyle),
          ),
          if (Platform.isAndroid)
            ListTile(
              onTap: PiliAndroidHelper.openLinkVerifySettings,
              leading: const Icon(MdiIcons.linkBoxOutline),
              title: const Text('打开受支持的链接'),
              trailing: Icon(Icons.arrow_forward, size: 16, color: outline),
            ),
          ListTile(
            onTap: () =>
                PageUtils.launchURL('${Constants.sourceCodeUrl}/issues'),
            leading: const Icon(Icons.feedback_outlined),
            title: const Text('问题反馈'),
            trailing: Icon(Icons.arrow_forward, size: 16, color: outline),
          ),
          ListTile(
            onTap: () => Get.toNamed('/logs'),
            onLongPress: LoggerUtils.clearLogs,
            onSecondaryTap: PlatformUtils.isMobile
                ? null
                : LoggerUtils.clearLogs,
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('错误日志'),
            subtitle: Text('长按清除日志', style: subTitleStyle),
            trailing: Icon(Icons.arrow_forward, size: 16, color: outline),
          ),
          ListTile(
            onTap: () {
              if (cacheSize.value.isNotEmpty) {
                showConfirmDialog(
                  context: context,
                  title: const Text('提示'),
                  content: const Text('该操作将清除图片及网络请求缓存数据，确认清除？'),
                  onConfirm: () async {
                    SmartDialog.showLoading(msg: '正在清除...');
                    try {
                      await CacheManager.clearLibraryCache();
                      SmartDialog.showToast('清除成功');
                    } catch (err) {
                      SmartDialog.showToast(err.toString());
                    } finally {
                      SmartDialog.dismiss();
                    }
                    getCacheSize();
                  },
                );
              }
            },
            leading: const Icon(Icons.delete_outline),
            title: const Text('清除缓存'),
            subtitle: Obx(
              () => Text(
                '图片及网络缓存 ${cacheSize.value}',
                style: subTitleStyle,
              ),
            ),
          ),
          ListTile(
            title: const Text('导入/导出登录信息'),
            leading: const Icon(Icons.import_export_outlined),
            onTap: () => showImportExportDialog<Map>(
              context,
              title: '登录信息',
              localFileName: () => 'account',
              // the export is every account's full Cookie + access_key
              beforeExport: () => showConfirmDialog(
                context: context,
                title: const Text('导出登录信息？'),
                content: const Text(
                  '导出内容含账号的全部 Cookie（SESSDATA、bili_jct）与 access_key，'
                  '拿到它即可登录你的账号。剪贴板可被其他应用读取，建议导出文件至本地',
                ),
              ),
              onExport: () =>
                  Utils.jsonEncoder.convert(Accounts.account.toMap()),
              onImport: (json) async {
                // validate first, like the settings / local library imports:
                // nothing downstream checks these, and a jar without
                // DedeUserID parses fine and then throws on every mid read
                // (Accounts.refresh) at every launch, while a key that is
                // not the account's own mid makes delete() unreachable
                final res = <String, LoginAccount>{};
                for (final MapEntry(:key, :value) in json.entries) {
                  final LoginAccount account;
                  try {
                    account = LoginAccount.fromJson(value);
                    // reading mid forces the DedeUserID lookup
                    if (account.mid <= 0) {
                      throw const FormatException('DedeUserID 无效');
                    }
                  } catch (e) {
                    throw FormatException('登录信息无效（$key）: $e');
                  }
                  final mid = '${account.mid}';
                  if (mid != '$key') {
                    throw FormatException('登录信息的键与账号 mid 不一致：$key / $mid');
                  }
                  if (res.containsKey(mid)) {
                    throw FormatException('登录信息有重复的 mid: $mid');
                  }
                  res[mid] = account;
                }
                await Accounts.account.putAll(res);
                await Accounts.refresh();
                MineController.anonymity.value = !Pref.loginMode;
                if (Accounts.main.isLogin) {
                  await LoginUtils.onLoginMain();
                }
              },
            ),
          ),
          ListTile(
            title: const Text('导入/导出设置'),
            dense: false,
            leading: const Icon(Icons.import_export_outlined),
            onTap: () {
              // credentials (WebDAV login, SponsorBlock user id) are left out
              // unless the user says otherwise
              bool includeCredentials = false;
              showImportExportDialog<Map<String, dynamic>>(
                context,
                title: '设置',
                localFileName: () => 'setting_${DeviceUtils.platformName}',
                beforeExport: () async {
                  includeCredentials = await showConfirmDialog(
                    context: context,
                    title: const Text('导出中包含凭据？'),
                    content: const Text(
                      'WebDAV 用户名/密码、空降助手用户 ID。点「取消」则不包含（推荐）',
                    ),
                  );
                  return true;
                },
                onExport: () => GStorage.exportAllSettings(
                  includeCredentials: includeCredentials,
                ),
                onImport: (json) async {
                  final importCredentials =
                      GStorage.hasCredentials(json) &&
                      context.mounted &&
                      await showConfirmDialog(
                        context: context,
                        title: const Text('使用备份中的凭据？'),
                        content: const Text(
                          '备份含有 WebDAV 用户名/密码或空降助手用户 ID。点「取消」保留本机的',
                        ),
                      );
                  final snapshot = await GStorage.importAllJsonSettings(
                    json,
                    importCredentials: importCredentials,
                  );
                  // tell the user the undo exists, like the WebDAV restore;
                  // many settings are mirrored into statics read once at
                  // startup, so the running session keeps the old values
                  SmartDialog.showToast('导入成功（重启生效），导入前的数据已保存至 $snapshot');
                },
              );
            },
          ),
          ListTile(
            title: const Text('恢复到导入前'),
            leading: const Icon(Icons.undo_outlined),
            subtitle: Text('撤回最近一次导入/恢复', style: subTitleStyle),
            onTap: () async {
              final confirmed = await showConfirmDialog(
                context: context,
                title: const Text('恢复到导入前'),
                content: const Text('撤回最近一次恢复/导入，回到那之前的设置、本地关注和本地收藏'),
              );
              if (!confirmed) return;
              try {
                await GStorage.restoreLatestSnapshot();
                SmartDialog.showToast('已恢复到导入前（重启生效）');
              } catch (e) {
                SmartDialog.showToast('恢复失败: $e');
              }
            },
          ),
          ListTile(
            title: const Text('重置所有设置'),
            leading: const Icon(Icons.settings_backup_restore_outlined),
            onTap: () => showDialog(
              context: context,
              builder: (context) {
                return SimpleDialog(
                  clipBehavior: Clip.hardEdge,
                  title: const Text('是否重置所有设置？'),
                  children: [
                    DialogOption(
                      onPressed: () async {
                        Get.back();
                        // login mode is not an exportable setting: keep it
                        // (the running account state is not re-applied)
                        final loginMode = Pref.loginMode;
                        // snapshot first, like every import path, so
                        // 恢复到导入前 can undo this too
                        final snapshot = await GStorage.saveSnapshot();
                        await Future.wait([
                          GStorage.setting.clear(),
                          GStorage.video.clear(),
                        ]);
                        await GStorage.setting.put(
                          SettingBoxKey.loginMode,
                          loginMode,
                        );
                        SmartDialog.showToast(
                          '重置成功（重启生效），重置前的数据已保存至 $snapshot',
                        );
                      },
                      child: const Text('重置可导出的设置', style: style),
                    ),
                    DialogOption(
                      onPressed: () async {
                        Get.back();
                        // no snapshot: a full reset must not leave a copy of
                        // the data behind (GStorage.clear also drops the
                        // import snapshots), so it cannot be undone
                        await GStorage.clear();
                        // outside Hive, and just as much user data: the
                        // crash log (entries can carry signed request URLs)
                        // and the picked-document side-file mirrors
                        await LoggerUtils.clearLogs();
                        await LocalPlayer.clearMirrors();
                        SmartDialog.showToast('重置成功（重启生效）');
                      },
                      child: const Text(
                        '重置所有数据（含登录信息、本地关注/收藏，不可撤回）',
                        style: style,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
