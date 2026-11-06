// BUG-1451 守卫：查词弹窗「快捷键复制 + 右键复制」两条路径。
//
// 为什么是源码扫描而不是 widget 行为测试：这两条都断在**平台事实**上——Windows 的
// WebView2 合成模式下 fork 不转发键盘、选区活在 WebView2 进程里，widget 测试既造不出
// 真实选区也照不到真实剪贴板。能在最强可落地层锁住的，是「实现必须保持这几条不变式」：
//   ① 右键菜单的选区必须在**右键那一刻**取快照，不能在 `await showMenu` 之后才读；
//   ② 空选区不得**静默**早退（必须有反馈），成功复制必须有反馈；
//   ③ 桌面弹窗必须挂复制键兼容层（Windows Ctrl+C、macOS ⌘C，BUG-4127），且判据复用
//      与阅读器同一个纯谓词；这层不得被包进 Windows 专属分支。
// 纯谓词本身的真值表已由 test/shortcuts/reader_desktop_copy_test.dart 覆盖，此处不重复。
import 'dart:io';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart' show ModifierKey;
import 'package:fushi/src/shortcuts/reader_space_override.dart';

import '../helpers/source_guard.dart';

void main() {
  final File webviewFile = File(
    'lib/src/pages/implementations/dictionary_popup_webview.dart',
  );
  late String code;

  setUpAll(() {
    expect(
      webviewFile.existsSync(),
      isTrue,
      reason: '弹窗 WebView 源文件必须存在（测试须在 fushi/ 下运行）',
    );
    code = maskComments(webviewFile.readAsStringSync());
  });

  group('BUG-1451 ① 选区必须在右键那一刻取快照', () {
    test('showMenu 之前就发起 _selectedTextAcrossFrames', () {
      // 玻璃重设计后菜单走共享 showFushiMenu（自绘菜单），不变式不变：
      // 选区快照必须在 await 菜单之前发起。
      final int menuIdx = code.indexOf(
        'showFushiMenu<_PopupContextMenuAction>',
      );
      expect(menuIdx, greaterThan(0), reason: 'Windows 右键菜单入口必须还在');

      final int ctxIdx = code.indexOf('Future<void> _showWindowsContextMenu');
      expect(ctxIdx, greaterThan(0));

      final String beforeMenu = code.substring(ctxIdx, menuIdx);
      expect(
        beforeMenu.contains('_selectedTextAcrossFrames()'),
        isTrue,
        reason:
            '选区是易失状态：必须在 await showMenu **之前**取快照。'
            '放到菜单关闭之后再读 → 焦点转移/弹窗 dismiss 后拿空串 → 静默早退 '
            '= 用户看到的「点复制没反应」（BUG-1451）。',
      );
    });

    test('快照结果被消费（菜单之后不是重新裸读一次就完）', () {
      expect(
        code.contains('await selectionAtRightClick'),
        isTrue,
        reason: '取了快照却不用等于没修；菜单选中后必须先消费快照。',
      );
    });
  });

  group('BUG-1451 ② 复制结果不得静默', () {
    test('空选区分支给反馈而不是裸 return', () {
      expect(
        code.contains('_showCopyToast(copied: false)'),
        isTrue,
        reason: '空选区必须提示，否则用户无法分辨「我没选中」和「复制链路断了」。',
      );
    });

    test('写剪贴板与成功反馈收口在单一 helper', () {
      expect(code.contains('Future<void> _copySelectionToClipboard('), isTrue);
      expect(
        code.contains('_showCopyToast(copied: true)'),
        isTrue,
        reason: '复制成功必须有反馈（Android 分支一直有，Windows 原本没有）。',
      );
      // 三条入口（Windows 右键 / Windows Ctrl+C / Android 原生菜单）都必须走同一
      // helper，不许任何一条自己裸调 Clipboard.setData 绕过反馈。
      final int rawSetData = 'Clipboard.setData'.allMatches(code).length;
      expect(
        rawSetData,
        1,
        reason:
            '写剪贴板必须只有 _copySelectionToClipboard 一处；'
            '多出的裸 Clipboard.setData 意味着某条入口绕过了统一反馈语义。',
      );
    });
  });

  group('BUG-1451 / BUG-4127 ③ 桌面复制键兼容层', () {
    test('弹窗挂了 onKeyEvent 复制兼容层', () {
      expect(
        code.contains('onKeyEvent: _handleDesktopCopyKey'),
        isTrue,
        reason:
            'Windows fork 不转发键盘 → WebView2 内原生 Ctrl+C 永不触发，'
            '必须由 Flutter 侧 Focus 接住（BUG-402 只修了阅读器，弹窗漏修）。',
      );
    });

    test('复制拦截层不在 Windows 专属分支里（macOS 也要挂，BUG-4127）', () {
      // 旧版把 Focus(onKeyEvent: _handleDesktopCopyKey) 写在 `if (isWindowsPlatform)` 分支
      // 里，macOS 弹窗根本没有这层，⌘C 只能落到菜单 Edit > Copy → first responder
      // FlutterView（BUG-2948），WKWebView 收不到 copy:。平台判定只许留在谓词里。
      final int guardedIdx = code.indexOf('final Widget guardedWebView = ');
      expect(
        guardedIdx,
        greaterThan(0),
        reason: 'guardedWebView 必须是单一赋值（不再按平台分支各写一份）',
      );
      final int end = code.indexOf('return LayoutBuilder(', guardedIdx);
      expect(end, greaterThan(guardedIdx));
      final String guarded = code.substring(guardedIdx, end);
      expect(guarded.contains('onKeyEvent: _handleDesktopCopyKey'), isTrue);
      expect(
        guarded.contains('isWindowsPlatform'),
        isFalse,
        reason: '复制拦截层不得按 isWindowsPlatform 包裹，平台判定只在谓词里做一次',
      );
    });

    test('判据复用与阅读器同一个纯谓词，不另起一套键位', () {
      final String body = methodBody(
        code,
        'KeyEventResult _handleDesktopCopyKey',
      );
      expect(
        body.contains('desktopShouldHandleCopyGesture('),
        isTrue,
        reason: '两条复制路径断在同一平台事实上，判据必须同源，否则会漂开。',
      );
      expect(
        body.contains('isWindows: isWindowsPlatform') &&
            body.contains('isMacOS: isMacOSPlatform'),
        isTrue,
        reason: '谓词必须同时拿到 Windows 与 macOS 平台事实（BUG-4127：macOS ⌘C 也要接管）。',
      );
      expect(
        code.contains(
          "import 'package:fushi/src/shortcuts/reader_space_override.dart'",
        ),
        isTrue,
      );
    });

    test('未命中的按键必须交回冒泡（不吞制卡 Ctrl+Enter 等）', () {
      final int start = code.indexOf('KeyEventResult _handleDesktopCopyKey');
      expect(start, greaterThan(0));
      final String body = code.substring(start, start + 700);
      expect(
        body.contains('KeyEventResult.ignored'),
        isTrue,
        reason: '非 KeyDown / 非命中一律 ignored，绝不吞键。',
      );
      expect(body.contains('KeyEventResult.handled'), isTrue);
    });
  });

  group('BUG-1451 谓词边界（复用侧的回归护栏）', () {
    test('Ctrl+C 在 Windows 命中、其它组合不命中', () {
      bool hit(
        LogicalKeyboardKey key,
        Set<ModifierKey> mods, {
        bool isWindows = true,
      }) => desktopShouldHandleCopyGesture(
        key: key,
        modifiers: mods,
        isWindows: isWindows,
        isMacOS: false,
      );

      expect(
        hit(LogicalKeyboardKey.keyC, <ModifierKey>{ModifierKey.ctrl}),
        isTrue,
      );
      // 制卡默认 Ctrl+Enter：必须不被复制兼容层吃掉。
      expect(
        hit(LogicalKeyboardKey.enter, <ModifierKey>{ModifierKey.ctrl}),
        isFalse,
      );
      // 视频 scope 的裸 C（shader 对比）不受影响。
      expect(hit(LogicalKeyboardKey.keyC, <ModifierKey>{}), isFalse);
      expect(
        hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.ctrl,
          ModifierKey.shift,
        }),
        isFalse,
      );
      // Linux / 移动端不接管（macOS 走 ⌘C，见 reader_desktop_copy_test.dart）。
      expect(
        hit(LogicalKeyboardKey.keyC, <ModifierKey>{
          ModifierKey.ctrl,
        }, isWindows: false),
        isFalse,
      );
    });
  });
}
