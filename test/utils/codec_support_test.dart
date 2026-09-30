import 'dart:io';

import 'package:PiliPlus/utils/codec_support.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('codec-support-test-');
    Hive.init(tempDir.path);
    GStorage.setting = await Hive.openBox('setting');
  });

  setUp(() => GStorage.setting.clear());

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('parseDecoders', () {
    test('the codecs answered, each a bool', () {
      expect(
        CodecSupport.parseDecoders({
          'avc': true,
          'hevc': true,
          'vp9': false,
          'av1': false,
        }),
        {
          HwCodec.avc: true,
          HwCodec.hevc: true,
          HwCodec.vp9: false,
          HwCodec.av1: false,
        },
      );
    });

    test('anything else is left out, never guessed', () {
      expect(
        CodecSupport.parseDecoders({
          'avc': true,
          'hevc': null,
          'vp9': 'yes',
          'h266': true,
        }),
        {HwCodec.avc: true},
      );
      expect(CodecSupport.parseDecoders(null), isEmpty);
      expect(CodecSupport.parseDecoders(true), isEmpty);
      expect(CodecSupport.parseDecoders(const <Object?>[]), isEmpty);
    });
  });

  group('hardware', () {
    test('nothing stored: nothing known', () {
      expect(CodecSupport.hardware, isEmpty);
    });

    test('reads back what was stored', () async {
      await CodecSupport.store({HwCodec.avc: true, HwCodec.av1: false});
      expect(GStorage.setting.get(SettingBoxKey.hardwareDecoders), {
        'avc': true,
        'av1': false,
      });
      expect(CodecSupport.hardware, {HwCodec.avc: true, HwCodec.av1: false});
    });

    test('AV1 seen decoded in software overrides the device', () async {
      await CodecSupport.store({HwCodec.avc: true, HwCodec.av1: true});
      CodecSupport.noteSoftwareAv1();
      expect(CodecSupport.hardware, {HwCodec.avc: true, HwCodec.av1: false});
      expect(GStorage.setting.get(SettingBoxKey.av1Hardware), isFalse);
    });
  });

  group('hardwareDecodingOn', () {
    test('off with 硬件解码 off, or --hwdec=no', () async {
      await GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'auto');
      expect(CodecSupport.hardwareDecodingOn, isTrue);
      await GStorage.setting.put(SettingBoxKey.enableHA, false);
      expect(CodecSupport.hardwareDecodingOn, isFalse);
      await GStorage.setting.put(SettingBoxKey.enableHA, true);
      await GStorage.setting.put(SettingBoxKey.hardwareDecoding, 'no');
      expect(CodecSupport.hardwareDecodingOn, isFalse);
      await GStorage.setting.put(
        SettingBoxKey.hardwareDecoding,
        'mediacodec,mediacodec-copy',
      );
      expect(CodecSupport.hardwareDecodingOn, isTrue);
    });
  });

  group('check', () {
    const channel = MethodChannel('librepili/codecs');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    // only Android and Windows are asked
    final skip = !Platform.isAndroid && !Platform.isWindows;

    test('stores both answers, refreshed on every start', () async {
      var decoders = <String, bool>{'avc': true, 'av1': true};
      messenger.setMockMethodCallHandler(channel, (call) async {
        return switch (call.method) {
          'av1Hardware' => decoders['av1'],
          'hardwareDecoders' => decoders,
          _ => null,
        };
      });
      await CodecSupport.check();
      expect(CodecSupport.hardware, {HwCodec.avc: true, HwCodec.av1: true});
      expect(GStorage.setting.get(SettingBoxKey.av1Hardware), isTrue);

      decoders = {'avc': true, 'hevc': false, 'av1': false};
      await CodecSupport.check();
      expect(CodecSupport.hardware, {
        HwCodec.avc: true,
        HwCodec.hevc: false,
        HwCodec.av1: false,
      });
      expect(GStorage.setting.get(SettingBoxKey.av1Hardware), isFalse);
    }, skip: skip);

    test('an unanswered method keeps what was known', () async {
      await CodecSupport.store({HwCodec.avc: true});
      messenger.setMockMethodCallHandler(channel, (call) {
        throw MissingPluginException();
      });
      await CodecSupport.check();
      expect(CodecSupport.hardware, {HwCodec.avc: true});
    }, skip: skip);
  });
}
