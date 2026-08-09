import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';

/// BUG-1471 — 手势事务的终止条件必须收在**一个**函数里，且必须覆盖
/// 「capture 被系统收走」这条真实路径。
///
/// 为什么只能源码扫描：出问题的是 `windows/runner/` 下两个自持 Win32 窗口，
/// `flutter test` 里既没有消息循环也没有 Direct2D，而失败的定义是
/// 「**另一个进程**抢到前台之后我们收不到 WM_LBUTTONUP」——这在宿主里造不出来。
/// 所以这里钉住的是**接线**，不是运行时行为：真行为只能靠 Windows 真机复验
/// （见 docs/bugs/BUG-1471-gal-overlay-gesture-state-stuck.md）。
///
/// 守住的两条不变量，各对应一种已经出过事的写法：
///  1. 手势标志（pressed_ / dragging_ / press_was_text_）散在多处各清一半 ——
///     `Hide()` 曾经只清 `dragging_`，于是 `pressed_` 跨隐藏卡住，
///     `MaybeHoverLookup` 从此永久早退，悬停查词静默失效而台词照常更新。
///  2. 没有 `WM_CAPTURECHANGED` 分支 —— 这两个窗都是 WS_EX_NOACTIVATE 的
///     后台线程窗，前台窗口一变系统就收回 capture，此时 button-up 永不到达。
///     没有这条分支，任何「在 button-up 里清状态」的写法都必然漏。
void main() {
  late String body;
  late String bodyHeader;
  late String toolbar;
  late String toolbarHeader;
  late String lookup;
  late String lookupHeader;

  setUpAll(() {
    body = File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
    bodyHeader =
        File('windows/runner/floating_lyric_window.h').readAsStringSync();
    toolbar = File('windows/runner/hook_toolbar_window.cpp').readAsStringSync();
    toolbarHeader =
        File('windows/runner/hook_toolbar_window.h').readAsStringSync();
    lookup = File('windows/runner/global_lookup_window.cpp').readAsStringSync();
    lookupHeader =
        File('windows/runner/global_lookup_window.h').readAsStringSync();
  });

  /// C++ 函数体：从签名处起做花括号配对。注释先掩成等长空白，免得散文里的
  /// 花括号/符号把配对带偏，也免得断言被「把字面量塞进注释」骗绿。
  String functionBody(String source, String signature) {
    final String masked = maskComments(source);
    final int i = masked.indexOf(signature);
    if (i < 0) fail('找不到函数签名（注释里的同名文本不算）：$signature');
    int depth = 0;
    for (int j = i; j < source.length; j++) {
      if (masked[j] == '{') depth++;
      if (masked[j] == '}') {
        depth--;
        if (depth == 0) return source.substring(i, j + 1);
      }
    }
    fail('花括号不配对：$signature');
  }

  int countOf(String haystack, String needle) =>
      needle.allMatches(haystack).length;

  /// `dragging_ = false;` 有两种合法出现：终止（在 CancelPointerGesture 里）与
  /// **起始**（WM_LBUTTONDOWN 里紧跟 `pressed_ = true;` 的初始化）。后者不是
  /// 终止路径，不该被本守卫算进"多处各清一半"。这里只数**终止**语义的那些：
  /// 往前看一小段，若紧邻 `pressed_ = true;` 就判为起始初始化。
  int terminatingClears(String maskedSource, String flag) {
    int count = 0;
    for (final Match m in flag.allMatches(maskedSource)) {
      final int from = m.start - 80 < 0 ? 0 : m.start - 80;
      if (maskedSource.substring(from, m.start).contains('pressed_ = true;')) {
        continue; // 手势起始的初始化，不是终止
      }
      count++;
    }
    return count;
  }

  group('BUG-1471 · 手势事务只有一个终止函数', () {
    test('浮窗正文：三个手势标志只在 CancelPointerGesture 里清零', () {
      final String masked = maskComments(body);
      final String cancel = functionBody(
          body, 'void FloatingLyricWindow::CancelPointerGesture()');
      for (final String flag in <String>[
        'pressed_ = false;',
        'dragging_ = false;',
        'press_was_text_ = false;',
      ]) {
        expect(countOf(cancel, flag), 1, reason: '$flag 必须在唯一终止函数里清');
        expect(
          terminatingClears(masked, flag),
          1,
          reason: '$flag 在 CancelPointerGesture 之外还有**终止**语义的清零点——'
              '「各清一半」正是 pressed_ 卡死的成因（BUG-1471）',
        );
      }
      expect(cancel.contains('ReleaseCapture()'), isTrue);
      expect(bodyHeader.contains('void CancelPointerGesture();'), isTrue);
    });

    test('工具条：同一条规则', () {
      final String masked = maskComments(toolbar);
      final String cancel = functionBody(
          toolbar, 'void HookToolbarWindow::CancelPointerGesture()');
      for (final String flag in <String>[
        'pressed_ = false;',
        'dragging_ = false;',
      ]) {
        expect(countOf(cancel, flag), 1);
        expect(terminatingClears(masked, flag), 1,
            reason: '$flag 在唯一终止函数之外还有**终止**语义的清零点');
      }
      expect(cancel.contains('ReleaseCapture()'), isTrue);
      expect(toolbarHeader.contains('void CancelPointerGesture();'), isTrue);
    });

    test('Hide() 必须走终止函数（旧写法只清了 dragging_，pressed_ 跨隐藏卡住）', () {
      expect(
        functionBody(body, 'void FloatingLyricWindow::Hide()')
            .contains('CancelPointerGesture();'),
        isTrue,
      );
      expect(
        functionBody(toolbar, 'void HookToolbarWindow::Hide()')
            .contains('CancelPointerGesture();'),
        isTrue,
      );
    });
  });

  group('BUG-1471 · capture 被收走这条路径必须有人接', () {
    test('每个装 SetCapture 的窗口都有 WM_CAPTURECHANGED 分支', () {
      for (final (String name, String src) in <(String, String)>[
        ('floating_lyric_window.cpp', body),
        ('hook_toolbar_window.cpp', toolbar),
      ]) {
        final String masked = maskComments(src);
        expect(masked.contains('SetCapture(hwnd_)'), isTrue,
            reason: '$name 前提变了：不再取 capture 的话本守卫要重写');
        expect(
          masked.contains('case WM_CAPTURECHANGED:'),
          isTrue,
          reason: '$name 取了 capture 却不处理被收走的情况。'
              '这是 WS_EX_NOACTIVATE 后台线程窗的必然路径（游戏抢回前台），'
              '不接就等于 button-up 永不到达、手势状态永久卡住',
        );
      }
    });

    test('WM_CAPTURECHANGED 分支就是调终止函数，不另写一份清零', () {
      for (final String src in <String>[body, toolbar]) {
        final int at = maskComments(src).indexOf('case WM_CAPTURECHANGED:');
        expect(at, greaterThan(0));
        // 分支很短，取其后一小段即可覆盖整个 case。
        final String branch = src.substring(at, at + 160);
        expect(branch.contains('CancelPointerGesture();'), isTrue);
      }
    });
  });

  group('BUG-1471 · 查词卡窗口的钩子 arm/disarm 必须配平', () {
    test('解钩三件套只有一个出口', () {
      final String masked = maskComments(lookup);
      final String release = functionBody(
          lookup, 'void GlobalLookupWindow::ReleaseDismissHooks()');
      expect(release.contains('UnhookWinEvent(foreground_hook_)'), isTrue);
      expect(release.contains('DisarmLowLevelMouseHook()'), isTrue);
      expect(release.contains('s_hook_owner_ = nullptr;'), isTrue);
      expect(
        countOf(masked, 'UnhookWinEvent(foreground_hook_)'),
        1,
        reason: '解钩散在多处 = 迟早有一条路径漏掉（ForgetDeadWindow 就漏过）',
      );
      expect(countOf(masked, 'DisarmLowLevelMouseHook()'), 1);
      expect(lookupHeader.contains('void ReleaseDismissHooks();'), isTrue);
    });

    test('ForgetDeadWindow 必须解钩：低级鼠标钩子有 1s 重装定时器，泄漏不会自愈', () {
      expect(
        functionBody(lookup, 'void GlobalLookupWindow::ForgetDeadWindow()')
            .contains('ReleaseDismissHooks();'),
        isTrue,
        reason: 'HWND 被外部销毁时若不解钩，存活性定时器会把一条指向死窗口的'
            '纯放行钩子永久续命在链上',
      );
    });
  });
}
