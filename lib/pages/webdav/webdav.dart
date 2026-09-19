import 'dart:convert';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/widgets/pair.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

typedef _WebDavConfig = ({
  String uri,
  String username,
  String password,
  String directory,
});

class WebDav {
  _WebDavConfig? _clientConfig;
  webdav.Client? _client;

  WebDav._internal();
  static final WebDav _instance = WebDav._internal();
  factory WebDav() => _instance;

  _WebDavConfig _getConfig() {
    String directory = Pref.webdavDirectory;
    if (!directory.endsWith('/')) {
      directory += '/';
    }
    return (
      uri: Pref.webdavUri,
      username: Pref.webdavUsername,
      password: Pref.webdavPassword,
      directory: '$directory${Constants.appName}',
    );
  }

  Future<webdav.Client> _connect(
    _WebDavConfig config, {
    bool force = false,
  }) async {
    final cachedClient = _client;
    if (!force && cachedClient != null && _clientConfig == config) {
      return cachedClient;
    }

    final client =
        webdav.newClient(
            config.uri,
            user: config.username,
            password: config.password,
          )
          ..setHeaders({'accept-charset': 'utf-8'})
          ..setConnectTimeout(12000)
          ..setReceiveTimeout(12000)
          ..setSendTimeout(12000);

    await client.mkdirAll(config.directory);
    _clientConfig = config;
    _client = client;
    return client;
  }

  Future<Pair<bool, String?>> init() async {
    try {
      await _connect(_getConfig(), force: true);

      return Pair(first: true, second: null);
    } catch (e) {
      return Pair(first: false, second: e.toString());
    }
  }

  String _getFileName() {
    return 'piliplus_settings_${DeviceUtils.platformName}.json';
  }

  Future<void> backup({bool includeCredentials = false}) async {
    // Keep the payload bound to the same settings snapshot as the connection.
    final config = _getConfig();
    final data = GStorage.exportAllSettings(
      includeCredentials: includeCredentials,
    );
    final webdav.Client client;
    try {
      client = await _connect(config);
    } catch (e) {
      SmartDialog.showToast('备份失败，请检查配置: $e');
      return;
    }
    try {
      final path = '${config.directory}/${_getFileName()}';
      // write a new file first and move it over the old one: a failed upload
      // must not lose the existing backup
      final tmpPath = '$path.tmp';
      await client.write(tmpPath, utf8.encode(data));
      await client.rename(tmpPath, path, true);
      SmartDialog.showToast('备份成功');
    } catch (e) {
      SmartDialog.showToast('备份失败: $e');
    }
  }

  /// [askCredentials]: asked when the backup carries credentials; true
  /// lets them replace this device's.
  Future<void> restore({
    required Future<bool> Function() askCredentials,
  }) async {
    final config = _getConfig();
    final webdav.Client client;
    try {
      client = await _connect(config);
    } catch (e) {
      SmartDialog.showToast('恢复失败，请检查配置: $e');
      return;
    }
    try {
      final path = '${config.directory}/${_getFileName()}';
      final data = await client.read(path);
      final Map<String, dynamic> map = jsonDecode(utf8.decode(data));
      final importCredentials =
          GStorage.hasCredentials(map) && await askCredentials();
      final snapshot = await GStorage.importAllJsonSettings(
        map,
        importCredentials: importCredentials,
      );
      SmartDialog.showToast('恢复成功，恢复前的数据已保存至 $snapshot');
    } catch (e) {
      SmartDialog.showToast('恢复失败: $e');
    }
  }

  /// Undoes the last restore / import (see [GStorage.restoreLatestSnapshot]).
  Future<void> restoreSnapshot() async {
    try {
      await GStorage.restoreLatestSnapshot();
      SmartDialog.showToast('已恢复到导入前');
    } catch (e) {
      SmartDialog.showToast('恢复失败: $e');
    }
  }
}
