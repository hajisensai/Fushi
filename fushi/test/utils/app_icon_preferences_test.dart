import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart'
    show
        AssetImage,
        FileImage,
        ImageCache,
        ImageInfo,
        OneFrameImageStreamCompleter,
        PaintingBinding,
        ResizeImage;
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
    test('唯一预设 default 指向 squircle 资源', () {
      expect(
        windowIconAssetForPreset('default'),
        'assets/meta/launcher_icon_squircle.png',
      );
    });

    test('已下线档在老用户偏好里残留时安全回退到 default 的 asset', () {
      // hibiki_minimal（TODO-868 去重）、hibiki_transparent 与 hibiki_full（随
      // 换新图标下线）都可能留在老用户的 app_icon_preset 里。它们的 asset 已被
      // 删除，读取时必须回退到 default，不崩、不空图标。
      for (final String retired in <String>[
        'hibiki_minimal',
        'hibiki_transparent',
        'hibiki_full',
      ]) {
        expect(
          windowIconAssetForPreset(retired),
          'assets/meta/launcher_icon_squircle.png',
          reason: '$retired 应回退到 default 的 asset',
        );
      }
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
    test('只剩 default 一档，已下线档不再出现', () {
      expect(presetIconAssets.keys, <String>['default']);
      for (final String retired in <String>[
        'hibiki_minimal',
        'hibiki_transparent',
        'hibiki_full',
      ]) {
        expect(presetIconAssets.containsKey(retired), isFalse,
            reason: '$retired 已随换新图标下线，资源也已删除');
      }
    });

    test('default 指向兔子图标的 squircle 资源', () {
      expect(
        presetIconAssets['default'],
        'assets/meta/launcher_icon_squircle.png',
      );
    });
  });

  group('isPresetKey', () {
    test('只有 default 合法；已下线档 / custom / 未知都不合法', () {
      expect(isPresetKey('default'), isTrue);
      for (final String invalid in <String>[
        'hibiki_transparent',
        'hibiki_full',
        'hibiki_minimal',
        'custom',
        'nope',
      ]) {
        expect(isPresetKey(invalid), isFalse, reason: '$invalid 不应再是合法预设');
      }
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

      final AssetImage preset =
          appIconImageProvider(const AppIconSelection(presetKey: 'default'))
              as AssetImage;
      expect(preset.assetName, presetIconAssets['default']);
    });

    test('启动读取会归一化选择并发布给侧栏监听器', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        iconPresetPrefKey: 'default',
      });

      final AppIconSelection loaded = await loadAppIconSelection();

      expect(loaded.presetKey, 'default');
      expect(loaded.revision, 1);
      expect(currentAppIconSelection.value.presetKey, 'default');
    });

    test('老用户偏好里残留的已下线档在启动读取时归一化成 default', () async {
      // 换新图标后 hibiki_full / hibiki_transparent 的 asset 已删除；若启动读取
      // 原样返回这些 key，侧栏与窗口图标会去解码不存在的 asset。
      for (final String retired in <String>[
        'hibiki_full',
        'hibiki_transparent',
        'hibiki_minimal',
      ]) {
        SharedPreferences.setMockInitialValues(<String, Object>{
          iconPresetPrefKey: retired,
        });

        final AppIconSelection loaded = await loadAppIconSelection();

        expect(loaded.presetKey, 'default', reason: '$retired 应归一化成 default');
        expect(currentAppIconSelection.value.presetKey, 'default');
      }
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

    test('发布新选择时逐出同路径的旧图片缓存（兜底路径也不例外）', () async {
      // 逐出原本只写在 saveAppIconSelection 里，而「原生图标已切换、偏好落盘失败」
      // 的兜底路径直接调 publishAppIconSelection，绕过了逐出。自定义图始终落在
      // **固定**路径上，FileImage 的 key 不变，imageCache.putIfAbsent 会把上一张图
      // 的解码结果原样还回来——新 revision 只能让组件重新 resolve，拦不住缓存命中，
      // 于是用户第二次换图，rail 还显示第一张。逐出收进唯一发布点后不可能再漏。
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'fushi_app_icon_evict_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final File icon = File('${tempDir.path}/icon.png');
      await icon.writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47]);
      final AppIconSelection custom = AppIconSelection(
        presetKey: customIconKey,
        customPath: icon.path,
      );

      final ImageCache cache = PaintingBinding.instance.imageCache;
      final FileImage fileKey = FileImage(File(icon.path));
      cache.putIfAbsent(
        fileKey,
        () => OneFrameImageStreamCompleter(Completer<ImageInfo>().future),
      );
      expect(cache.containsKey(fileKey), isTrue, reason: '前置条件：缓存里确实有一份旧解码');

      await publishAppIconSelection(custom);

      expect(
        cache.containsKey(fileKey),
        isFalse,
        reason: '发布走的是唯一发布点，它必须逐出同路径旧解码；'
            '否则换图后 rail 仍显示上一张',
      );
    });
  });
}
