import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1419 源码守卫：Windows fork 的鼠标键状态必须全量跟随 Flutter 的 `ev.buttons`
/// 掩码，不得回到「按 pointer id 记单个 PointerButton」的粘滞增量实现。
///
/// 为什么在 hibiki 侧做源码扫描：真值来源 `custom_platform_view.dart` 属 vendored fork
/// （`packages/flutter_inappwebview_windows`），它自己的 test 目录不进 CI 的 unit test
/// 门（真门是 Build Release APK 的 Run unit tests，只跑 `fushi/test`）。行为侧差分逻辑
/// 已由该包的 `test/mouse_button_mask_diff_test.dart` 覆盖；这里钉死接线结构，防回退。
///
/// 回归形态：WebView2 的 `VirtualKeyState`（windows/in_app_webview/in_app_webview.h）是
/// 纯增量位集，只有 down/up 会翻转、没有自愈。一旦某个 button-up 发不出去（多键并按被
/// `_getButton` 映射成 none、模态路由夺走 up、指针在 WebView 外抬起），`MK_*` 位就永久
/// 卡死；此后每个 MOVE 都带着「某键仍按住」进 Blink → 鼠标一动就把正文刷成原生蓝色选区、
/// click 不成立 → 阅读器点击查词永久失效（用户报「右键复制以后点击查词只出蓝色高亮」）。
void main() {
  final File view = File(
      '../packages/flutter_inappwebview_windows/lib/src/in_app_webview/custom_platform_view.dart');

  late String src;

  setUpAll(() {
    expect(view.existsSync(), isTrue,
        reason: 'custom_platform_view.dart 不存在，fork 路径变了须更新守卫');
    src = view.readAsStringSync().replaceAll('\r\n', '\n');
  });

  test('按钮状态不得再按 pointer id 记单值 PointerButton', () {
    expect(src.contains('_downButtons'), isFalse,
        reason: 'BUG-1419 回退：_downButtons 单值记账无法表达多键并按，'
            '复合掩码会被映射成 none 并覆盖已记按钮 → button-up 永久丢失');
  });

  test('掩码不得整体喂给单键映射函数', () {
    // `_getButton` 只接受单个位（kPrimaryMouseButton 等）；把 ev.buttons 整体传进去，
    // 左|右 = 3 会落进 default → PointerButton.none，正是 BUG-1419 的根因。
    expect(src.contains('_getButton(ev.buttons)'), isFalse,
        reason: 'BUG-1419 回退：ev.buttons 是位掩码，必须逐位差分而非整体映射成单键');
  });

  test('五个非触摸指针入口都全量同步 ev.buttons', () {
    expect(src.contains('void _syncMouseInput(Offset position, int buttons)'),
        isTrue,
        reason: '全量同步入口被改名/删除，守卫须同步更新');
    // hover / down / up / cancel / move 各一处：hover 的掩码恒 0，是残留位唯一可靠的
    // 自愈点；缺任何一处都会让某类漏发的 up 无法补上。
    final int calls =
        '_syncMouseInput(ev.localPosition, ev.buttons)'.allMatches(src).length;
    expect(calls, greaterThanOrEqualTo(5),
        reason: 'onPointerHover / Down / Up / Cancel / Move 五个入口都必须调用，'
            '实际只有 $calls 处');
  });

  test('同步走纯函数差分，且差分只对变化位产出翻转', () {
    expect(src.contains('planMouseInputDispatches('), isTrue,
        reason: '_syncMouseInput 必须复用可单测的有序输入规划器');
    expect(src.contains('diffMouseButtonMasks(previousButtons, nextButtons)'),
        isTrue,
        reason: '有序输入规划器必须继续复用 BUG-1419 的逐位差分真值');
    expect(src.contains('List<MouseButtonTransition> diffMouseButtonMasks('),
        isTrue,
        reason: 'diffMouseButtonMasks 是 BUG-1419 的真值来源，不得内联回 State');
    expect(src.contains('if (wasDown == isDown) continue;'), isTrue,
        reason: '未变化的位必须跳过：按住不动时重发 down 会污染 Blink 的拖拽判定');
  });
}
