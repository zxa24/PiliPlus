import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/models/common/theme/theme_type.dart';
import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/models/user/stat.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/data.dart';
import 'package:PiliPlus/pages/common/common_data_controller.dart';
import 'package:PiliPlus/services/account_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/login_policy.dart';
import 'package:PiliPlus/utils/extension/scroll_controller_ext.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

class MineController extends CommonDataController<FavFolderData, FavFolderData>
    with AccountMixin {
  @override
  AccountService accountService = Get.find<AccountService>();

  int? favFolderCount;

  // 用户信息 头像、昵称、lv
  final Rx<UserInfoData> userInfo = UserInfoData().obs;
  // 用户状态 动态、关注、粉丝
  final Rx<UserStat> userStat = const UserStat().obs;

  final Rx<ThemeType> themeType = Pref.themeType.obs;

  ThemeType get nextThemeType =>
      ThemeType.values[(themeType.value.index + 1) % ThemeType.values.length];

  /// LibrePili: incognito is the default; it means login mode is off.
  /// (Independent of the heartbeat role: an anonymous heartbeat in login
  /// mode is not incognito.)
  static RxBool anonymity = (!LoginPolicy.loginMode).obs;

  late final list = <({IconData icon, String title, VoidCallback onTap})>[
    (
      icon: CustomIcons.folderDownloadOutline,
      title: '离线缓存',
      onTap: () => Get.toNamed('/download'),
    ),
    (
      icon: CustomIcons.history,
      title: '观看记录',
      onTap: () {
        if (isLogin) {
          Get.toNamed('/history');
        }
      },
    ),
    (
      icon: CustomIcons.subscriptions_outlined,
      title: '我的订阅',
      onTap: () {
        if (isLogin) {
          Get.toNamed('/subscription');
        }
      },
    ),
    (
      icon: CustomIcons.watch_later_outlined,
      title: '稍后再看',
      onTap: () {
        if (isLogin) {
          Get.toNamed('/later');
        }
      },
    ),
  ];

  @override
  void onInit() {
    super.onInit();
    UserInfoData? userInfoCache = Pref.userInfoCache;
    if (userInfoCache != null && LoginPolicy.loginMode) {
      userInfo.value = userInfoCache;
      queryData();
      queryUserInfo();
    }
  }

  bool get isLogin {
    if (!accountService.isLogin.value) {
      // SmartDialog.showToast('账号未登录');
      return false;
    }
    return true;
  }

  Future<void> queryUserInfo() async {
    final res = await UserHttp.userInfo();
    if (res case Success(:final response)) {
      if (response.isLogin == true) {
        userInfo.value = response;
        if (response != Pref.userInfoCache) {
          GStorage.userInfo.put('userInfoCache', response);
        }
        accountService
          ..face.value = response.face!
          ..isLogin.value = true;
      } else {
        _onLogoutMain();
        return;
      }
    } else {
      final errMsg = res.toString();
      SmartDialog.showToast(errMsg);
      if (errMsg == '账号未登录') {
        _onLogoutMain();
        return;
      }
    }
    queryUserStatOwner();
  }

  void _onLogoutMain() {
    // "未登录" only proves the account is invalid if the request carried it:
    // with login mode off the policy sent it anonymously, so keep the account
    if (!LoginPolicy.loginMode) return;
    if (Accounts.main case final LoginAccount account) {
      // kept (marked expired), credentials included, so the user can
      // re-login or remove it — one bad answer must not cost the login
      Accounts.markExpired({account});
      SmartDialog.showToast('账号登录已失效，可在「账号切换」中重新登录或删除');
    }
  }

  Future<void> queryUserStatOwner() async {
    final res = await UserHttp.userStatOwner();
    if (res case Success(:final response)) {
      userStat.value = response;
    }
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<FavFolderData> response) {
    favFolderCount = response.response.count;
    loadingState.value = response;
    return true;
  }

  @override
  Future<LoadingState<FavFolderData>> customGetData() {
    return FavHttp.userfavFolder(
      pn: 1,
      ps: 20,
      mid: Accounts.main.mid,
    );
  }

  /// Toggles between incognito (default, login mode off) and login mode.
  static Future<void> onChangeAnonymity() async {
    // without an account there is nothing login mode could turn on, but a
    // leftover `loginMode: true` must still be turned off — otherwise the
    // toast asserts a privacy posture the app is not in
    if (Accounts.account.isEmpty) {
      if (LoginPolicy.loginMode) {
        await GStorage.setting.put(SettingBoxKey.loginMode, false);
        await Accounts.refresh();
        anonymity.value = true;
        await LoginUtils.onLogoutMain();
      }
      SmartDialog.showToast('当前为无痕模式（默认）。需要账号功能时，请先在设置中登录');
      return;
    }
    final enterIncognito = !anonymity.value;
    await GStorage.setting.put(SettingBoxKey.loginMode, !enterIncognito);
    await Accounts.refresh();
    anonymity.value = enterIncognito;
    if (enterIncognito) {
      await LoginUtils.onLogoutMain();
    } else if (Accounts.main.isLogin) {
      await LoginUtils.onLoginMain();
    }
    SmartDialog.dismiss();
    SmartDialog.show(
      clickMaskDismiss: true,
      usePenetrate: true,
      displayTime: const Duration(seconds: 3),
      alignment: Alignment.bottomCenter,
      builder: (context) {
        final theme = Theme.of(context);
        return ColoredBox(
          color: theme.colorScheme.secondaryContainer,
          child: Padding(
            padding: EdgeInsets.only(
              top: 15,
              left: 20,
              right: 20,
              bottom: MediaQuery.viewPaddingOf(context).bottom + 15,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      enterIncognito
                          ? MdiIcons.incognito
                          : MdiIcons.incognitoOff,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      enterIncognito ? '已进入无痕模式' : '已开启登录模式',
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  enterIncognito
                      ? '所有请求（推荐、搜索、播放等）均不携带账号\n'
                            '账号仍保存在本机，但不会被使用\n'
                            '需要登录才能用的功能将隐藏'
                      : '只有必须登录的请求才会携带账号：\n'
                            '点赞/投币/评论等操作、历史与账号收藏、消息、高画质取流\n'
                            '推荐、搜索、视频信息等仍然匿名',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void onChangeTheme() {
    final newVal = nextThemeType;
    themeType.value = newVal;
    GStorage.setting.put(SettingBoxKey.themeMode, newVal.index);
    Get.changeThemeMode(ThemeUtils.themeMode = newVal.toThemeMode);
  }

  void push(String name) {
    late final mid = userInfo.value.mid;
    if (isLogin && mid != null) {
      Get.toNamed('/$name?mid=$mid');
    }
  }

  void onLogin([bool longPress = false]) {
    if (!accountService.isLogin.value || longPress) {
      Get.toNamed('/loginPage');
    } else {
      Get.toNamed('/member?mid=${userInfo.value.mid}');
    }
  }

  @override
  Future<void> onRefresh({bool isManual = true}) {
    if (!accountService.isLogin.value) {
      return Future.syncValue(null);
    }
    queryUserInfo();
    return super.onRefresh().whenComplete(() {
      if (isManual) {
        scrollController.jumpToTop();
      }
    });
  }

  @override
  void onChangeAccount(bool isLogin) {
    if (isLogin) {
      onRefresh();
    } else {
      userInfo.value = UserInfoData();
      userStat.value = const UserStat();
      loadingState.value = LoadingState.loading();
    }
  }
}
