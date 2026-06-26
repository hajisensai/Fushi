import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/app_icon_preferences.dart';

void main() {
  group('windowIconAssetForPreset', () {
    test('返回两套预设各自的 asset', () {
      expect(windowIconAssetForPreset('default'),
          'assets/meta/launcher_icon_minimal.png');
      expect(windowIconAssetForPreset('hibiki_full'),
          'assets/meta/launcher_icon_full.png');
    });

    test('老用户残留的 hibiki_minimal 安全回退到 default 的 asset（图相同）', () {
      // TODO-868 去重：hibiki_minimal 与 default 映射同一张图，已移除该档；
      // 老用户 app_icon_preset=hibiki_minimal 读取时必须回退到 default，不崩、不空图标。
      expect(windowIconAssetForPreset('hibiki_minimal'),
          'assets/meta/launcher_icon_minimal.png');
    });

    test('未知 key 回退到 default 的 asset', () {
      expect(windowIconAssetForPreset('nope'),
          'assets/meta/launcher_icon_minimal.png');
    });

    test('custom key 没有内置 asset（返回 null）', () {
      expect(windowIconAssetForPreset('custom'), isNull);
    });
  });

  group('presetIconAssets', () {
    test('只剩 default + full 两档，不含 hibiki_minimal', () {
      expect(presetIconAssets.keys,
          containsAll(<String>['default', 'hibiki_full']));
      expect(presetIconAssets.containsKey('hibiki_minimal'), isFalse);
      expect(presetIconAssets.length, 2);
    });
  });

  group('isPresetKey', () {
    test('default/full 是合法 preset；hibiki_minimal/custom/未知不是', () {
      expect(isPresetKey('default'), isTrue);
      expect(isPresetKey('hibiki_full'), isTrue);
      expect(isPresetKey('hibiki_minimal'), isFalse);
      expect(isPresetKey('custom'), isFalse);
      expect(isPresetKey('nope'), isFalse);
    });
  });
}
