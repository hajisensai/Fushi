// 反馈 Eemf0HOZhj（BUG-4069）：截屏识字有自己的 OCR 引擎设置，默认跟随全局 OCR 引擎。
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/ocr/screen_ocr_engine.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';

ScreenOcrEngine _resolve(
  ScreenOcrEngineSetting setting,
  MangaOcrEnginePreference global, {
  bool systemOcrSupported = true,
  bool localModelReady = false,
}) => resolveScreenOcrEngine(
  setting: setting,
  global: global,
  systemOcrSupported: systemOcrSupported,
  localModelReady: localModelReady,
);

void main() {
  group('ScreenOcrEngineSetting 存储值', () {
    test('出厂（没写过 / 空串）= 跟随全局，wire 值往返不变', () {
      expect(
        ScreenOcrEngineSetting.fromStorage(''),
        ScreenOcrEngineSetting.followGlobal,
      );
      for (final ScreenOcrEngineSetting value
          in ScreenOcrEngineSetting.values) {
        expect(ScreenOcrEngineSetting.fromStorage(value.storageValue), value);
      }
    });

    test('不认识的值按跟随全局处理', () {
      expect(
        ScreenOcrEngineSetting.fromStorage('external_mokuro'),
        ScreenOcrEngineSetting.followGlobal,
      );
    });

    test('单独指定的 wire 值与全局 OCR 引擎偏好的键同名', () {
      expect(
        ScreenOcrEngineSetting.localModel.storageValue,
        MangaOcrEnginePreference.localOnnx.key,
      );
      expect(
        ScreenOcrEngineSetting.systemOcr.storageValue,
        MangaOcrEnginePreference.systemOcr.key,
      );
      expect(
        ScreenOcrEngineSetting.googleLens.storageValue,
        MangaOcrEnginePreference.googleLens.key,
      );
    });
  });

  group('resolveScreenOcrEngine 跟随全局', () {
    test('全局选 Google Lens / 设备自带：照用', () {
      expect(
        _resolve(
          ScreenOcrEngineSetting.followGlobal,
          MangaOcrEnginePreference.googleLens,
        ),
        ScreenOcrEngine.googleLens,
      );
      expect(
        _resolve(
          ScreenOcrEngineSetting.followGlobal,
          MangaOcrEnginePreference.systemOcr,
          localModelReady: true,
        ),
        ScreenOcrEngine.systemOcr,
      );
    });

    test('全局选本机模型（出厂）：模型已下载用本机模型（用户说的 CTC 设置真正生效）', () {
      expect(
        _resolve(
          ScreenOcrEngineSetting.followGlobal,
          kDefaultMangaOcrEnginePreference,
          localModelReady: true,
        ),
        ScreenOcrEngine.localModel,
      );
    });

    test('全局选本机模型但没下载：有设备自带的平台开箱可用，不叫人先下模型', () {
      expect(
        _resolve(
          ScreenOcrEngineSetting.followGlobal,
          MangaOcrEnginePreference.localOnnx,
        ),
        ScreenOcrEngine.systemOcr,
      );
    });

    test('Linux（没有系统 OCR）：本机模型类一律本机模型，设备自带也落到本机模型', () {
      for (final MangaOcrEnginePreference global in <MangaOcrEnginePreference>[
        MangaOcrEnginePreference.localOnnx,
        MangaOcrEnginePreference.auto,
        MangaOcrEnginePreference.systemOcr,
        MangaOcrEnginePreference.externalMokuro,
        MangaOcrEnginePreference.pairedHost,
      ]) {
        expect(
          _resolve(
            ScreenOcrEngineSetting.followGlobal,
            global,
            systemOcrSupported: false,
          ),
          ScreenOcrEngine.localModel,
          reason: global.key,
        );
      }
    });

    test('自动 / 外部 mokuro / 互联服务端：按自动解析，永不自作主张上传 Lens', () {
      for (final MangaOcrEnginePreference global in <MangaOcrEnginePreference>[
        MangaOcrEnginePreference.auto,
        MangaOcrEnginePreference.externalMokuro,
        MangaOcrEnginePreference.pairedHost,
      ]) {
        expect(
          _resolve(
            ScreenOcrEngineSetting.followGlobal,
            global,
            localModelReady: true,
          ),
          ScreenOcrEngine.localModel,
          reason: global.key,
        );
        expect(
          _resolve(ScreenOcrEngineSetting.followGlobal, global),
          ScreenOcrEngine.systemOcr,
          reason: global.key,
        );
        expect(
          screenOcrEngineOfGlobal(global, systemOcrSupported: true),
          isNull,
          reason: '设置页「跟随全局（自动）」',
        );
      }
    });
  });

  group('resolveScreenOcrEngine 单独指定', () {
    test('指定的引擎照用，不看全局与模型是否下载', () {
      for (final MangaOcrEnginePreference global
          in MangaOcrEnginePreference.values) {
        expect(
          _resolve(ScreenOcrEngineSetting.localModel, global),
          ScreenOcrEngine.localModel,
        );
        expect(
          _resolve(
            ScreenOcrEngineSetting.systemOcr,
            global,
            localModelReady: true,
          ),
          ScreenOcrEngine.systemOcr,
        );
        expect(
          _resolve(ScreenOcrEngineSetting.googleLens, global),
          ScreenOcrEngine.googleLens,
        );
      }
    });

    test('没有系统 OCR 的平台上残留的「设备自带」退成本机模型', () {
      expect(
        _resolve(
          ScreenOcrEngineSetting.systemOcr,
          MangaOcrEnginePreference.googleLens,
          systemOcrSupported: false,
        ),
        ScreenOcrEngine.localModel,
      );
    });
  });

  group('MethodChannelSystemOcr.screenText', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const MethodChannel channel = MethodChannel('test/system_ocr_screen');

    Future<Map<Object?, Object?>> recognizeArgs(bool screenText) async {
      Map<Object?, Object?>? args;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            args = call.arguments as Map<Object?, Object?>;
            return <String, Object?>{
              'width': 10,
              'height': 10,
              'lines': <Object?>[],
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await MethodChannelSystemOcr(
        channel: channel,
        screenText: screenText,
      ).recognize(Uint8List.fromList(<int>[1]), language: 'ja');
      return args!;
    }

    test('截屏识字下发 purpose: screen（Apple 据此不做整屏文档版面分析）', () async {
      expect((await recognizeArgs(true))['purpose'], kSystemOcrScreenPurpose);
    });

    test('漫画等其它调用方不带 purpose，原生照旧', () async {
      expect((await recognizeArgs(false)).containsKey('purpose'), isFalse);
    });
  });
}
