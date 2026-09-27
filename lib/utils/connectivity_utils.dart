import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

abstract final class ConnectivityUtils {
  static Future<bool> get isWiFi async {
    try {
      return PlatformUtils.isMobile &&
          (await Connectivity().checkConnectivity()).contains(
            ConnectivityResult.wifi,
          );
    } catch (_) {
      return true;
    }
  }

  /// LibrePili: a phone on its mobile data and nothing better — where a
  /// large download costs the user money. False wherever it cannot be told.
  static Future<bool> get isMobileData async {
    if (!PlatformUtils.isMobile) return false;
    try {
      final now = await Connectivity().checkConnectivity();
      return now.contains(ConnectivityResult.mobile) &&
          !now.contains(ConnectivityResult.wifi) &&
          !now.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false;
    }
  }
}
