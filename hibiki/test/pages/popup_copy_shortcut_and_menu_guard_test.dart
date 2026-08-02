// BUG-1451 守卫：查词弹窗「快捷键复制 + 右键复制」两条路径。
//
// 为什么是源码扫描而不是 widget 行为测试：这两条都断在**平台事实**上——Windows 的
// WebView2 合成模式下 fork 不转发键盘、选区活在 WebView2 进程里，widget 测试既造不出
// 真实选区也照不到真实剪贴板。能在最强可落地层锁住的，是「实现必须保持这几条不变式」：
//   ① 右键菜单的选区必须在**右键那一刻**取快照，不能在 `await showMenu` 之后才读；
//   ② 空选区不得**静默**早退（必须有反馈），成功复制必须有反馈；
//   ③ Windows 弹窗必须挂 Ctrl+C 兼容层，且判据复用与阅读器同一个纯谓词。
// 纯谓词本身的真值表已由 test/shortcuts/reader_desktop_copy_test.dart 覆盖，此处不重复。
import 'dart:io';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart' show ModifierKey;
import 'package:hibiki/src/shortcuts/reader_space_override.dart';

/// 剥掉行注释与块注释，避免断言被文档注释里的同名字样喂成假绿。
String _stripComments(String source) {
  final String noBlock =
      source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return noBlock.split('\n').map((String line) {
    final int idx = line.indexOf('//');
    return idx >= 0 ? line.substring(0, idx) : line;
  }).join('\n');
}

void main() {
  final File webviewFile =
      File('lib/src/pages/implementations/dictionary_popup_webview.dart');
  late String code;

  setUpAll(() {
    expect(webviewFile.existsSync(), isTrue,
        reason: '弹窗 WebView 源文件必须存在（测试须在 hibiki/ 下运行）');
    code = _stripComments(webviewFile.readAsStringSync());
  });

  group('BUG-1451 ① 选区必须在右键那一刻取快照', () {
    test('showMenu 之前就发起 _selectedTextAcrossFrames', () {
      final int menuIdx = code.indexOf('showMenu<_PopupContextMenuAction>');
      expect(menuIdx, greaterThan(0), reason: 'Windows 右键菜单入口必须还在');

      final int ctxIdx = code.indexOf('Future<void> _showWindowsContextMenu');
      expect(ctxIdx, greaterThan(0));

      final String beforeMenu = code.substring(ctxIdx, menuIdx);
      expect(
        beforeMenu.contains('_selectedTextAcrossFrames()'),
        isTrue,
        reason: '选区是易失状态：必须在 await showMenu **之前**取快照。'
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
        reason: '写剪贴板必须只有 _copySelectionToClipboard 一处；'
            '多出的裸 Clipboard.setData 意味着某条入口绕过了统一反馈语义。',
      );
    });
  });

  group('BUG-1451 ③ Windows Ctrl+C 兼容层', () {
    test('弹窗挂了 onKeyEvent 复制兼容层', () {
      expect(
        code.contains('onKeyEvent: _handleDesktopCopyKey'),
        isTrue,
        reason: 'Windows fork 不转发键盘 → WebView2 内原生 Ctrl+C 永不触发，'
            '必须由 Flutter 侧 Focus 接住（BUG-402 只修了阅读器，弹窗漏修）。',
      );
    });

    test('判据复用与阅读器同一个纯谓词，不另起一套键位', () {
      expect(
        code.contains('readerShouldHandleDesktopCopy('),
        isTrue,
        reason: '两条复制路径断在同一平台事实上，判据必须同源，否则会漂开。',
      );
      expect(
        code.contains(
            "import 'package:hibiki/src/shortcuts/reader_space_override.dart'"),
        isTrue,
      );
    });

    test('未命中的按键必须交回冒泡（不吞制卡 Ctrl+Enter 等）', () {
      final int start = code.indexOf('KeyEventResult _handleDesktopCopyKey');
      expect(start, greaterThan(0));
      final String body = code.substring(start, start + 700);
      expect(body.contains('KeyEventResult.ignored'), isTrue,
          reason: '非 KeyDown / 非命中一律 ignored，绝不吞键。');
      expect(body.contains('KeyEventResult.handled'), isTrue);
    });
  });

  group('BUG-1451 谓词边界（复用侧的回归护栏）', () {
    test('Ctrl+C 在 Windows 命中、其它组合不命中', () {
      bool hit(LogicalKeyboardKey key, Set<ModifierKey> mods,
              {bool isWindows = true}) =>
          readerShouldHandleDesktopCopy(
              key: key, modifiers: mods, isWindows: isWindows);

      expect(hit(LogicalKeyboardKey.keyC, <ModifierKey>{ModifierKey.ctrl}),
          isTrue);
      // 制卡默认 Ctrl+Enter：必须不被复制兼容层吃掉。
      expect(hit(LogicalKeyboardKey.enter, <ModifierKey>{ModifierKey.ctrl}),
          isFalse);
      // 视频 scope 的裸 C（shader 对比）不受影响。
      expect(hit(LogicalKeyboardKey.keyC, <ModifierKey>{}), isFalse);
      expect(
          hit(LogicalKeyboardKey.keyC,
              <ModifierKey>{ModifierKey.ctrl, ModifierKey.shift}),
          isFalse);
      // 非 Windows 的原生 WebView 自带 copy，接管会双重处理。
      expect(
          hit(LogicalKeyboardKey.keyC, <ModifierKey>{ModifierKey.ctrl},
              isWindows: false),
          isFalse);
    });
  });
}
