import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/api_type.dart';
import 'package:PiliPlus/utils/accounts/login_policy.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

List<SettingsModel> get privacySettings => [
  NormalModel(
    onTap: (context, setState) {
      if (!Accounts.main.isLogin) {
        SmartDialog.showToast('登录后查看');
        return;
      }
      Get.toNamed('/blackListPage');
    },
    title: '黑名单管理',
    subtitle: '已拉黑用户',
    leading: const Icon(Icons.block),
  ),
  NormalModel(
    onTap: (context, setState) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('账号模式详情'),
          content: SelectionArea(
            child: SingleChildScrollView(
              child: _getAccountDetail(context),
            ),
          ),
          actions: [
            TextButton(
              onPressed: Get.back,
              child: const Text('确认'),
            ),
          ],
        ),
      );
    },
    leading: const Icon(Icons.flag_outlined),
    title: '了解账号模式',
    subtitle: '查看各个账号模式作用的API列表',
  ),
];

Widget _getAccountDetail(BuildContext context) {
  final theme = TextTheme.of(context);
  final children = <Widget>[
    // the role mapping alone says nothing: LoginPolicy decides per request
    // whether the account is attached at all, so each row is marked
    Text(
      '下面是各账号模式负责的 API。实际请求另由隐私策略决定：默认无痕，'
      '即使开启账号模式，也只有需要账号的请求（个人数据、写操作、播放地址、'
      '首页推荐）会带上账号，其余仍匿名发送。'
      '「带账号」= 开启账号模式后会带上账号；「匿名」= 始终匿名发送'
      '（写操作、个人主页等仍会按请求内容带上账号）。',
      style: theme.bodySmall,
    ),
  ];
  for (final i in AccountType.values) {
    final url = ApiType.apiTypeSet[i];
    if (url == null) continue;

    children
      ..add(Center(child: Text(i.title, style: theme.titleMedium)))
      ..add(
        Text(
          url
              .map(
                (e) => '${LoginPolicy.isAccountPath(e) ? '[带账号]' : '[匿名]'} $e',
              )
              .join('\n'),
        ),
      );
  }
  return Column(
    spacing: 8,
    mainAxisSize: .min,
    crossAxisAlignment: .start,
    children: children,
  );
}
