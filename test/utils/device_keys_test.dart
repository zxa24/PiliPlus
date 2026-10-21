import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/local_history.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:PiliPlus/services/youtube/yt_subscriptions.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// The 设置代理 setting and the hardware decoding mode are this device's
/// (user 2026-10-20): out of a backup, kept on import.
void main() {
  late Directory tempDir;

  const deviceValues = {
    SettingBoxKey.enableSystemProxy: true,
    SettingBoxKey.systemProxyHost: '192.168.1.2',
    SettingBoxKey.systemProxyPort: '7890',
    SettingBoxKey.hardwareDecoding: 'd3d11va',
  };

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('device-keys-test-');
    Hive.init(tempDir.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    await LocalLibrary.init();
    await LocalHistory.init();
    await YtSubscriptions.init();
  });

  setUp(() => GStorage.setting.clear());

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('they are device keys', () {
    expect(GStorage.deviceKeys, containsAll(deviceValues.keys));
  });

  test('an export leaves them out', () async {
    await GStorage.setting.putAll({...deviceValues, 'someSetting': 1});
    final map = jsonDecode(GStorage.exportAllSettings()) as Map;
    final settings = map[GStorage.setting.name] as Map;
    expect(settings['someSetting'], 1);
    for (final key in deviceValues.keys) {
      expect(settings.containsKey(key), isFalse, reason: key);
    }
  });

  test("an import keeps this device's values", () async {
    await GStorage.setting.putAll(deviceValues);
    await GStorage.importAllJsonSettings({
      GStorage.setting.name: {
        SettingBoxKey.enableSystemProxy: false,
        SettingBoxKey.systemProxyHost: '10.0.0.1',
        SettingBoxKey.systemProxyPort: '1080',
        SettingBoxKey.hardwareDecoding: 'no',
        'someSetting': 2,
      },
    }, snapshot: false);
    for (final e in deviceValues.entries) {
      expect(GStorage.setting.get(e.key), e.value, reason: e.key);
    }
    expect(GStorage.setting.get('someSetting'), 2);
  });

  test('an import does not bring them where this device has none', () async {
    await GStorage.importAllJsonSettings({
      GStorage.setting.name: {
        SettingBoxKey.enableSystemProxy: true,
        SettingBoxKey.systemProxyHost: '10.0.0.1',
        SettingBoxKey.systemProxyPort: '1080',
        SettingBoxKey.hardwareDecoding: 'no',
      },
    }, snapshot: false);
    for (final key in deviceValues.keys) {
      expect(GStorage.setting.containsKey(key), isFalse, reason: key);
    }
  });
}
