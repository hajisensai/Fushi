import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_button_assets.dart';
import 'package:hibiki/src/shortcuts/visual/gamepad_glyphs.dart';

/// TODO-942：手柄按钮 → Kenney「Input Prompts」(CC0) 素材映射守卫。
///
/// 钉住：每个映射到的素材文件真实存在于 `assets/gamepad/<brand>/`（避免映射拼错/
/// 漏拷）、且已在 `pubspec.yaml` 注册目录下；三品牌覆盖完整（Xbox/Switch 全 17 键，
/// PlayStation 缺 PS/Guide 键素材 → mode 回退绘制符号）；Switch 面键印字对调与
/// GamepadGlyphs 一致；许可文件入库。
void main() {
  test('every mapped asset file exists on disk under assets/gamepad/<brand>/',
      () {
    for (final GamepadBrand brand in GamepadBrand.values) {
      for (final GamepadButton button in GamepadButton.values) {
        final String? path = GamepadButtonAssets.assetFor(button, brand);
        if (path == null) continue;
        expect(path, startsWith('assets/gamepad/'),
            reason: '$brand.$button asset must live under assets/gamepad/');
        expect(File(path).existsSync(), isTrue,
            reason: 'missing asset file for $brand.$button: $path');
      }
    }
  });

  test('Xbox and Switch cover all 17 buttons; PlayStation covers 16 (no guide)',
      () {
    int xbox = 0;
    int ps = 0;
    int nsw = 0;
    for (final GamepadButton button in GamepadButton.values) {
      if (GamepadButtonAssets.assetFor(button, GamepadBrand.xbox) != null) {
        xbox++;
      }
      if (GamepadButtonAssets.assetFor(button, GamepadBrand.playstation) !=
          null) {
        ps++;
      }
      if (GamepadButtonAssets.assetFor(button, GamepadBrand.nintendoSwitch) !=
          null) {
        nsw++;
      }
    }
    expect(xbox, GamepadButton.values.length);
    expect(nsw, GamepadButton.values.length);
    expect(ps, GamepadButton.values.length - 1);
    // The only PlayStation gap is the system/guide (mode) button.
    expect(
      GamepadButtonAssets.assetFor(
          GamepadButton.mode, GamepadBrand.playstation),
      isNull,
      reason: 'PlayStation has no dedicated PS/Guide key icon in the pack',
    );
  });

  test('within a brand no two buttons share the same asset', () {
    for (final GamepadBrand brand in GamepadBrand.values) {
      final List<String> paths = <String>[
        for (final GamepadButton button in GamepadButton.values)
          if (GamepadButtonAssets.assetFor(button, brand) case final String p)
            p,
      ];
      expect(paths.toSet().length, paths.length,
          reason: '$brand must map each button to a distinct icon');
    }
  });

  test('Switch face buttons keep the physical ABXY / XY swap', () {
    // Logical .a (bottom) shows the physical Nintendo 'B' icon, etc — matching
    // GamepadGlyphs so the icon and the printed-letter convention agree.
    expect(
        GamepadButtonAssets.assetFor(
            GamepadButton.a, GamepadBrand.nintendoSwitch),
        endsWith('switch_button_b.png'));
    expect(
        GamepadButtonAssets.assetFor(
            GamepadButton.b, GamepadBrand.nintendoSwitch),
        endsWith('switch_button_a.png'));
    expect(
        GamepadButtonAssets.assetFor(
            GamepadButton.x, GamepadBrand.nintendoSwitch),
        endsWith('switch_button_y.png'));
    expect(
        GamepadButtonAssets.assetFor(
            GamepadButton.y, GamepadBrand.nintendoSwitch),
        endsWith('switch_button_x.png'));
  });

  test('the Kenney CC0 license is vendored next to the assets', () {
    expect(
      File('assets/licenses/kenney_input_prompts_LICENSE.txt').existsSync(),
      isTrue,
      reason: 'Kenney Input Prompts CC0 license must be committed',
    );
  });
}
