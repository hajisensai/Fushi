import 'dart:io';

import 'package:flutter/painting.dart' show AssetImage, FileImage, ResizeImage;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    currentAppIconSelection.value = const AppIconSelection(
      presetKey: 'default',
    );
  });

  group('windowIconAssetForPreset', () {
    test('返回三套预设各自的 asset（TODO-1241）', () {
      expect(
        windowIconAssetForPreset('default'),
        'assets/meta/launcher_icon_squircle.png',
      );
      expect(
        windowIconAssetForPreset('hibiki_transparent'),
        'assets/meta/launcher_icon_minimal.png',
      );
      expect(
        windowIconAssetForPreset('hibiki_full'),
        'assets/meta/launcher_icon_full.png',
      );
    });

    test('老用户残留的 hibiki_minimal 安全回退到 default 的 asset', () {
      // TODO-868 去重：hibiki_minimal 曾与旧 default 映射同一张图，已移除该档；
      // 老用户 app_icon_preset=hibiki_minimal 读取时必须回退到 default（现为 squircle），
      // 不崩、不空图标。
      expect(
        windowIconAssetForPreset('hibiki_minimal'),
        'assets/meta/launcher_icon_squircle.png',
      );
    });

    test('未知 key 回退到 default 的 asset', () {
      expect(
        windowIconAssetForPreset('nope'),
        'assets/meta/launcher_icon_squircle.png',
      );
    });

    test('custom key 没有内置 asset（返回 null）', () {
      expect(windowIconAssetForPreset('custom'), isNull);
    });
  });

  group('presetIconAssets', () {
    test('三档 default + hibiki_transparent + full，不含 hibiki_minimal', () {
      expect(
        presetIconAssets.keys,
        containsAll(<String>['default', 'hibiki_transparent', 'hibiki_full']),
      );
      expect(presetIconAssets.containsKey('hibiki_minimal'), isFalse);
      expect(presetIconAssets.length, 3);
    });

    test('default 指向不透明白 squircle，透明档指向透明 wordmark', () {
      expect(
        presetIconAssets['default'],
        'assets/meta/launcher_icon_squircle.png',
      );
      expect(
        presetIconAssets['hibiki_transparent'],
        'assets/meta/launcher_icon_minimal.png',
      );
    });
  });

  group('isPresetKey', () {
    test('default/hibiki_transparent/full 合法；hibiki_minimal/custom/未知不合法', () {
      expect(isPresetKey('default'), isTrue);
      expect(isPresetKey('hibiki_transparent'), isTrue);
      expect(isPresetKey('hibiki_full'), isTrue);
      expect(isPresetKey('hibiki_minimal'), isFalse);
      expect(isPresetKey('custom'), isFalse);
      expect(isPresetKey('nope'), isFalse);
    });
  });

  group('AppIconSelection', () {
    test('未知预设和已丢失的自定义文件都回退 default', () {
      expect(
        resolveAppIconSelection(presetKey: 'retired').presetKey,
        'default',
      );
      expect(
        resolveAppIconSelection(
          presetKey: customIconKey,
          customPath: r'C:\missing\icon.png',
          pathExists: (String path) => false,
        ).presetKey,
        'default',
      );
    });

    test('存在的自定义文件保留路径，预设映射返回对应 ImageProvider', () {
      final AppIconSelection custom = resolveAppIconSelection(
        presetKey: customIconKey,
        customPath: r'C:\icons\selected.png',
        pathExists: (String path) => true,
      );
      expect(custom.usesCustomFile, isTrue);
      expect(custom.customPath, r'C:\icons\selected.png');
      final ResizeImage customProvider =
          appIconImageProvider(custom) as ResizeImage;
      expect(customProvider.imageProvider, isA<FileImage>());
      expect(customProvider.width, appIconDecodePixelWidth);

      final AssetImage full =
          appIconImageProvider(const AppIconSelection(presetKey: 'hibiki_full'))
              as AssetImage;
      expect(full.assetName, presetIconAssets['hibiki_full']);
    });

    test('启动读取会归一化选择并发布给侧栏监听器', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        iconPresetPrefKey: 'hibiki_full',
      });

      final AppIconSelection loaded = await loadAppIconSelection();

      expect(loaded.presetKey, 'hibiki_full');
      expect(loaded.revision, 1);
      expect(currentAppIconSelection.value.presetKey, 'hibiki_full');
    });

    test('保存自定义图标会持久化并为同一路径连续发布新 revision', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'fushi_app_icon_test_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final File icon = File('${tempDir.path}/icon.png');
      await icon.writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47]);
      final AppIconSelection custom = AppIconSelection(
        presetKey: customIconKey,
        customPath: icon.path,
      );

      final AppIconSelection first = await saveAppIconSelection(custom);
      final AppIconSelection second = await saveAppIconSelection(custom);
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      expect(prefs.getString(iconPresetPrefKey), customIconKey);
      expect(prefs.getString(iconCustomPathPrefKey), icon.path);
      expect(first.revision, 1);
      expect(second.revision, 2);
      expect(currentAppIconSelection.value.revision, 2);
    });
  });
}
