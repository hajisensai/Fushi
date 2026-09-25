import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-2651 (issue #1581) — 应用外查词卡片里的文字必须能复制（源码扫描守卫）。
///
/// 真机根因：瞬态覆盖窗带 `WS_EX_NOACTIVATE`，永不拿键盘焦点（设计保证：前台应用
/// 始终留着焦点）。于是
///   ① 在卡片里划选后按 Ctrl+C，按键落在前台应用上，复制走的是**前台应用**的选区；
///   ② WebView2 自带的右键菜单弹在这个置顶窗口**下面**，「复制」永远点不到。
///
/// 修复契约：
/// 1. host（global_lookup_host.js）把各卡片 realm 的 selectionchange 汇总成一个
///    布尔，变化时 postToHost('overlaySelection')，并导出 selectedText()。
/// 2. native 在 WebMessageReceived 就地消费 overlaySelection（不转发 Dart），只在
///    「有选区 && IsShowing()」时 RegisterHotKey(Ctrl+C)；Hide() 立刻注销——隐藏的
///    卡片绝不能继续截走用户在别的应用里的复制。WM_HOTKEY 经 selectedText() 取文本、
///    native 写剪贴板。
/// 3. native 接管 ContextMenuRequested（put_Handled + deferral），PostMessage 出
///    COM 回调栈后自己弹 Win32 菜单；弹菜单期间临时拿前台（TrackPopupMenu 契约），
///    全局点击钩子不得把点菜单那一下当成点卡外，前台钩子放过「把前台还回去」那一次。
///
/// 覆盖窗真渲染依赖 native WebView2，headless 测不了，故源码扫描钉住契约；host 的
/// 选区汇总行为由 node harness（global_lookup_host_test.mjs 的 BUG-2651 段）覆盖。
void main() {
  String readRaw(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  late String cpp;
  late String hostJs;
  setUpAll(() {
    cpp = maskComments(readRaw('windows/runner/global_lookup_window.cpp'));
    hostJs = maskJsComments(readRaw('assets/popup/global_lookup_host.js'));
  });

  /// 抽出一个顶层函数体（从签名行到下一个左对齐 `}`）。
  String functionBody(String src, String signature) {
    final int at = src.indexOf(signature);
    expect(at, greaterThanOrEqualTo(0), reason: '必须存在：$signature');
    final int end = src.indexOf('\n}', at);
    expect(end, greaterThan(at));
    return src.substring(at, end);
  }

  test('host 汇总选区并只在变化时上报 overlaySelection，导出 selectedText', () {
    expect(hostJs, contains("postToHost('overlaySelection', [has])"));
    expect(hostJs, contains('if (has === lastReportedSelection)'));
    expect(hostJs, contains("addEventListener('selectionchange'"));
    expect(hostJs, contains('selectedText: selectedText,'));
    // 卡片离栈（停放 / 销毁）不会触发 selectionchange，removeMissing 收尾必须
    // 重新汇总；行为由 .mjs 的 BUG-2651 第二段覆盖。
    final int removeMissing = hostJs.indexOf('function removeMissing(');
    expect(removeMissing, greaterThanOrEqualTo(0));
    expect(
      hostJs.indexOf(
        'reportSelectionState();',
        hostJs.indexOf('parkRecord(parkCandidate);', removeMissing),
      ),
      lessThan(hostJs.indexOf('function frameDescriptors(', removeMissing)),
      reason: 'removeMissing 结束前必须 reportSelectionState()',
    );
    // load 与复用两条路都要给新 realm 挂监听。
    expect(
      RegExp(
        r'wrapFrameBridge\(record\);\s*watchFrameSelection\(record\);',
      ).allMatches(hostJs).length,
      2,
      reason: '每个调 wrapFrameBridge 的地方都必须紧跟 watchFrameSelection',
    );
  });

  test('native 就地消费 overlaySelection，不转发 Dart', () {
    final int intercept = cpp.indexOf('"\\"handler\\":\\"overlaySelection\\""');
    expect(intercept, greaterThanOrEqualTo(0));
    final int handle = cpp.indexOf('OnOverlaySelectionChanged(', intercept);
    final int forward = cpp.indexOf('if (message_cb_)', intercept);
    expect(handle, greaterThan(intercept));
    expect(
      handle,
      lessThan(forward),
      reason: 'overlaySelection 必须在 message_cb_ 转发之前拦截并 return',
    );
  });

  test('Ctrl+C 热键只在「有选区且在屏」时注册，Hide 立即交还', () {
    final String update = functionBody(
      cpp,
      'void GlobalLookupWindow::UpdateCopyHotkey(',
    );
    expect(update, contains('selection_present_ && IsShowing()'));
    expect(update, contains('MOD_CONTROL | MOD_NOREPEAT'));
    expect(update, contains("'C'"));
    expect(update, contains('UnregisterHotKey(hwnd_, kCopySelectionHotkeyId)'));

    final String hide = functionBody(cpp, 'void GlobalLookupWindow::Hide(');
    final int cleared = hide.indexOf('visible_ = false;');
    final int released = hide.indexOf('UpdateCopyHotkey();');
    expect(cleared, greaterThanOrEqualTo(0));
    expect(
      released,
      greaterThan(cleared),
      reason: 'Hide 必须在清 visible_ 之后调 UpdateCopyHotkey 注销热键',
    );

    final String copy = functionBody(
      cpp,
      'void GlobalLookupWindow::CopyOverlaySelectionToClipboard(',
    );
    expect(copy, contains('selectedText()'));
    expect(copy, contains('WriteClipboardUnicodeText(hwnd_, text)'));
    // 热键命中却取到空文本 = native 自行复位；host 的去重状态必须一起归零，
    // 否则下一次真选区被当成「没变化」不上报（行为见 .mjs 的 BUG-2651 第二段）。
    final int selfReset = copy.indexOf('OnOverlaySelectionChanged(false);');
    expect(selfReset, greaterThanOrEqualTo(0));
    expect(
      copy.indexOf('h.resetSelectionReport()', selfReset),
      greaterThan(selfReset),
      reason: 'native 自行复位后必须回写 host 的 resetSelectionReport()',
    );
    expect(hostJs, contains('resetSelectionReport: resetSelectionReport,'));
    expect(cpp, contains('case WM_HOTKEY:'));
    expect(
      cpp.indexOf(
        'CopyOverlaySelectionToClipboard();',
        cpp.indexOf('case WM_HOTKEY:'),
      ),
      greaterThan(0),
    );
  });

  test('右键菜单由 native 接管并在置顶带之上弹出', () {
    expect(cpp, contains('add_ContextMenuRequested('));
    final String request = functionBody(
      cpp,
      'void GlobalLookupWindow::HandleContextMenuRequested(',
    );
    expect(request, contains('put_Handled(TRUE)'));
    expect(request, contains('GetDeferral(&deferral)'));
    expect(request, contains('PostMessage(hwnd_, kShowContextMenuMessage'));
    expect(
      request,
      isNot(contains('TrackPopupMenu')),
      reason: '模态菜单不得在 WebView2 的 COM 回调栈里直接跑',
    );

    final String show = functionBody(
      cpp,
      'void GlobalLookupWindow::ShowPendingContextMenu(',
    );
    final int foreground = show.indexOf('SetForegroundWindow(hwnd_)');
    final int armed = show.indexOf('context_menu_active_ = true;');
    final int track = show.indexOf('TrackPopupMenuEx(');
    final int disarmed = show.indexOf('context_menu_active_ = false;');
    expect(foreground, greaterThanOrEqualTo(0));
    expect(armed, greaterThan(foreground));
    expect(track, greaterThan(armed));
    expect(disarmed, greaterThan(track));
    expect(show, contains('deferral->Complete();'));
    expect(
      show,
      contains('context_menu_return_foreground_ = previous_foreground'),
    );

    final String click = functionBody(
      cpp,
      'void GlobalLookupWindow::HandleGlobalClick(',
    );
    expect(click, contains('if (context_menu_active_) return;'));

    final String hook = functionBody(
      cpp,
      'void CALLBACK GlobalLookupWindow::ForegroundHookProc(',
    );
    final int skip = hook.indexOf('context_menu_return_foreground_');
    final int hideCall = hook.indexOf('self->Hide();');
    expect(skip, greaterThanOrEqualTo(0));
    expect(hideCall, greaterThan(skip), reason: '交还前台的那一次必须在关卡判断之前被放过');
  });
}
