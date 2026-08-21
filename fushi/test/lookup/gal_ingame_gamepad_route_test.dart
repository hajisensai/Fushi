import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/dictionary_popup_gamepad.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

import '../helpers/source_guard.dart';

/// 手柄重设计 P5：游戏内查词卡片的独占手柄路由（行为 + 三层接线源码守卫）。
void main() {
  tearDown(() {
    GalIngameLookupGamepadRoute.debugClear();
    DictionaryPopupGamepadRegistry.debugClear();
  });

  DictionaryPopupGamepadHooks recordingHooks(
    List<String> calls, {
    bool Function()? visible,
  }) {
    return DictionaryPopupGamepadHooks(
      hasVisiblePopup: visible ?? () => true,
      entryMove: (bool forward) async =>
          calls.add(forward ? 'entry:next' : 'entry:prev'),
      mineFirstEntry: () async => calls.add('mine'),
      playFirstAudio: () async => calls.add('audio'),
      scrollBy: (double dy) async => calls.add('scroll:$dy'),
    );
  }

  group('GalIngameLookupGamepadRoute', () {
    test('卡片可见性门控：不可见 / 未设置 / 清除后 current 均为 null', () {
      expect(GalIngameLookupGamepadRoute.current, isNull);
      bool visible = false;
      GalIngameLookupGamepadRoute.set(
          recordingHooks(<String>[], visible: () => visible));
      expect(GalIngameLookupGamepadRoute.current, isNull);
      visible = true;
      expect(GalIngameLookupGamepadRoute.current, isNotNull);
      GalIngameLookupGamepadRoute.set(null);
      expect(GalIngameLookupGamepadRoute.current, isNull);
    });

    test('dispatchDictionaryPopupGamepadButton 对独占钩子按弹窗绑定派发', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      final List<String> calls = <String>[];
      final DictionaryPopupGamepadHooks hooks = recordingHooks(calls);
      expect(
          dispatchDictionaryPopupGamepadButton(
              hooks, registry, GamepadButton.dpadDown),
          isTrue);
      expect(
          dispatchDictionaryPopupGamepadButton(
              hooks, registry, GamepadButton.y),
          isTrue);
      // 未绑定按钮返回 false——独占吞掉与否由 GamepadService 的前置步骤决定，
      // 不由本函数决定（app 内兜底路径要靠 false 放行滚动/焦点兜底）。
      expect(
          dispatchDictionaryPopupGamepadButton(
              hooks, registry, GamepadButton.b),
          isFalse);
      expect(calls, <String>['entry:next', 'audio']);
    });
  });

  group('接线源码守卫', () {
    test('GamepadService 四条分发通道都过独占路由（按钮吞掉一切/摇杆吞掉/右摇杆优先卡片）', () {
      final String code = maskComments(
          File('lib/src/shortcuts/gamepad_service.dart').readAsStringSync());
      // 按钮：独占命中后 return（吞掉一切，绝不落到页面 Actions / 焦点 / 返回）。
      expect(
        code.contains('dispatchDictionaryPopupGamepadButton('
            'galHooks, registry, button);'),
        isTrue,
        reason: '按钮通道缺独占前置：游戏里按手柄会驱动后台 app UI',
      );
      // 左摇杆与长按：独占期间直接吞掉。
      expect(
        RegExp(r'void _dispatchStickMove\([\s\S]{0,200}'
                r'GalIngameLookupGamepadRoute\.current != null\) return;')
            .hasMatch(code),
        isTrue,
        reason: '左摇杆通道缺独占吞噬：后台 app 焦点会被游戏里的摇杆挪走',
      );
      expect(
        RegExp(r'void _dispatchLongPress\([\s\S]{0,200}'
                r'GalIngameLookupGamepadRoute\.current != null\) return;')
            .hasMatch(code),
        isTrue,
        reason: '长按通道缺独占吞噬',
      );
      // 右摇杆：独占路由优先于 app 内弹窗登记栈。
      expect(
        code.contains('GalIngameLookupGamepadRoute.current ??'),
        isTrue,
        reason: '右摇杆通道没有优先卡片：游戏内卡片滚不动',
      );
    });

    test('host JS 暴露 gamepadAction 且转发到 popup.js 既有入口', () {
      final String js =
          File('assets/popup/global_lookup_host.js').readAsStringSync();
      expect(js.contains('gamepadAction: gamepadAction,'), isTrue,
          reason: 'host 未导出 gamepadAction：native ExecuteScript 打不到');
      for (final String entry in <String>[
        'fushiFocusDictionaryEntryMove',
        'fushiPopupMineFirstEntry',
        'fushiPopupPlayFirstAudio',
        'fushiPopupScrollBy',
      ]) {
        expect(js.contains(entry), isTrue,
            reason: 'gamepadAction 必须复用既有入口 $entry，不另起桥');
      }
    });

    test('native 两侧接线：方法分发 + 动作白名单', () {
      final String fw =
          File('windows/runner/flutter_window.cpp').readAsStringSync();
      expect(fw.contains('method == "gamepadAction"'), isTrue,
          reason: 'MethodChannel 缺 gamepadAction 分发');
      final String glw =
          File('windows/runner/global_lookup_window.cpp').readAsStringSync();
      // 只查符号存在不够（改名/删执行都可能漏）：切出 DispatchGamepadAction 函数
      // 体，白名单数组与「未命中即 return」的执行判据必须都在其中。
      final int fnIdx =
          glw.indexOf('void GlobalLookupWindow::DispatchGamepadAction');
      expect(fnIdx, greaterThanOrEqualTo(0),
          reason: 'DispatchGamepadAction 实现缺席');
      // 终点锚用真实调用 `webview_->ExecuteScript`（裸 'ExecuteScript' 会被
      // 函数体注释里的同词提前截断）。
      final int endIdx = glw.indexOf('webview_->ExecuteScript', fnIdx);
      expect(endIdx, greaterThan(fnIdx),
          reason: 'DispatchGamepadAction 里没有真实的 ExecuteScript 调用');
      final String fnSlice = glw.substring(fnIdx, endIdx);
      expect(fnSlice.contains('kAllowedActions'), isTrue,
          reason: '动作名必须走白名单再拼 ExecuteScript');
      expect(
        RegExp(r'if \(!allowed\) \{\s*return;\s*\}').hasMatch(fnSlice),
        isTrue,
        reason: '白名单必须真的拦截（未命中即 return），不能只是摆着的数组',
      );
      expect(glw.contains('window.__globalLookupHost.gamepadAction('), isTrue);
    });

    test('gal 控制器：会话 start 登记独占路由、stop 清除', () {
      final String code = maskComments(
          File('lib/src/lookup/gal_ingame_lookup_controller.dart')
              .readAsStringSync());
      expect(code.contains('GalIngameLookupGamepadRoute.set('), isTrue);
      expect(code.contains('GalIngameLookupGamepadRoute.set(null);'), isTrue,
          reason: '会话结束不清路由 = 手柄永久被吞');
      expect(code.contains("_dispatchGamepadAction('mine')"), isTrue);
    });
  });
}
