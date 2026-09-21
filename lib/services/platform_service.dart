/// LibrePili: which platform the app is currently showing.
///
/// A platform is a mode (as in NewPipe and PipePipe): it decides where the
/// home feed, the dynamics tab and search get their content, while the bottom
/// navigation itself stays put. The choice is global and survives a restart;
/// a link opens on the platform it belongs to without changing it.
library;

import 'package:PiliPlus/models/common/platform_mode.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';

class PlatformService extends GetxService {
  static PlatformService get to => Get.find<PlatformService>();

  late final mode = Pref.platformMode.obs;

  bool get showsBilibili =>
      mode.value == PlatformMode.bilibili || mode.value == PlatformMode.all;

  bool get showsYouTube =>
      mode.value == PlatformMode.youtube || mode.value == PlatformMode.all;

  Future<void> set(PlatformMode value) async {
    if (mode.value == value) return;
    mode.value = value;
    await GStorage.setting.put(SettingBoxKey.platformMode, value.index);
  }
}
