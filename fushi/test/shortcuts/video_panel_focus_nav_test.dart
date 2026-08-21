import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';

import '../helpers/source_guard.dart';

/// 手柄重设计 P3：视频浮层面板的焦点导航让位（分类器 + 接线源码守卫）。
void main() {
  group('isVideoPanelFocusNavButton', () {
    test('dpad 四向 + A 让位给焦点导航', () {
      for (final GamepadButton button in <GamepadButton>[
        GamepadButton.dpadUp,
        GamepadButton.dpadDown,
        GamepadButton.dpadLeft,
        GamepadButton.dpadRight,
        GamepadButton.a,
      ]) {
        expect(isVideoPanelFocusNavButton(button), isTrue,
            reason: '${button.label} 应在面板打开时让位');
      }
    });

    test('播放控制按钮不让位（LB/RB seek、B 退出阶梯、X/Y 字幕句在面板开着时仍可用）', () {
      for (final GamepadButton button in <GamepadButton>[
        GamepadButton.lb,
        GamepadButton.rb,
        GamepadButton.lt,
        GamepadButton.rt,
        GamepadButton.b,
        GamepadButton.x,
        GamepadButton.y,
        GamepadButton.start,
        GamepadButton.select,
        GamepadButton.thumbLeft,
        GamepadButton.thumbRight,
      ]) {
        expect(isVideoPanelFocusNavButton(button), isFalse,
            reason: '${button.label} 不该被面板抢走');
      }
    });
  });

  group('接线源码守卫（分类器单测抓不到「闸门被删」）', () {
    test('视频手柄处理器在注册表解析之前放行面板焦点导航按钮', () {
      final String code = maskComments(
          File('lib/src/pages/implementations/video_fushi_page.dart')
              .readAsStringSync());
      expect(
        code.contains(
            'if (_videoNavigablePanelOpen && isVideoPanelFocusNavButton(button)) {'),
        isTrue,
        reason: '闸门缺席：面板打开时 D-pad 仍会被解析成音量/seek，手柄进不了面板',
      );
    });

    test('三类面板都包了 PanelFocusScope（焦点领进面板的唯一入口）', () {
      const Map<String, String> panels = <String, String>{
        'lib/src/pages/implementations/video_fushi/episode.part.dart': '剧集轨',
        'lib/src/pages/implementations/video_fushi/subtitle.part.dart': '字幕列表',
        'lib/src/pages/implementations/video_fushi/side_panel.part.dart': '侧栏',
      };
      panels.forEach((String path, String label) {
        final String code = maskComments(File(path).readAsStringSync());
        expect(code.contains('PanelFocusScope('), isTrue,
            reason: '$label（$path）没包 PanelFocusScope：打开后焦点留在页面节点，'
                'D-pad 让位了也没有可移动的焦点');
      });
    });
  });
}
