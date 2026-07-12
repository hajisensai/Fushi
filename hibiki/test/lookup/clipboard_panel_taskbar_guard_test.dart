import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 面板任务栏图标（源码扫描守卫）。
///
/// 用户诉求：面板图钉关（非置顶）时被游戏/浏览器压到底下就找不回来了——
/// 「面板能不能有个独立的任务栏图标，这样可以点击拉到前台」。
///
/// 契约：
/// 1. 常驻剪贴板面板实例带任务栏按钮：`SetTaskbarPresence(true)` 只在
///    RegisterClipboardPanelChannel 里设置；瞬态查词覆盖窗绝不设置（保持
///    TOOLWINDOW，无任务栏项/Alt-Tab 项——查词卡不是"窗口"）。
/// 2. 两处 CreateWindowExW（ShowAt 懒建 + PrewarmWebView 预热）都按
///    `taskbar_presence_` 分流 WS_EX_APPWINDOW / WS_EX_TOOLWINDOW，并用
///    `window_title_` 作窗口标题（任务栏按钮文案）。
/// 3. 窗口类注册 hIcon（任务栏按钮/Alt-Tab 图标=app 图标 IDI_APP_ICON）。
/// 4. 标题本地化：Dart 面板 start() 在预热（窗口创建）之前
///    `setWindowTitle(t.clipboard_panel_window_title)`；native
///    `SetWindowTitle` 对已建窗口走 SetWindowTextW 即时生效。
///
/// 任务栏激活自带 raise + activate，是被压底面板的兜底找回入口，与图钉
/// （置顶）正交。真实按钮行为依赖 native，headless 测不了，源码扫描钉契约。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  late String cpp;
  late String hdr;
  late String fw;
  late String controller;
  setUpAll(() {
    cpp = read('windows/runner/global_lookup_window.cpp');
    hdr = read('windows/runner/global_lookup_window.h');
    fw = read('windows/runner/flutter_window.cpp');
    controller = read('lib/src/lookup/clipboard_panel_controller.dart');
  });

  test('只有面板实例 SetTaskbarPresence(true)，瞬态覆盖窗不上任务栏', () {
    expect('->SetTaskbarPresence(true)'.allMatches(fw).length, 1,
        reason: '任务栏按钮只属于常驻面板（瞬态查词卡不是窗口）');
    final int panelChannel = fw.indexOf('RegisterClipboardPanelChannel()');
    final int call = fw.indexOf('->SetTaskbarPresence(true)');
    expect(panelChannel, greaterThanOrEqualTo(0));
    expect(call, greaterThan(panelChannel),
        reason: 'SetTaskbarPresence 必须在面板 channel 注册段里');
  });

  test('两处 CreateWindowExW 都按 taskbar_presence_ 分流 APPWINDOW/TOOLWINDOW', () {
    expect(
        'taskbar_presence_ ? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW'
            .allMatches(cpp)
            .length,
        2,
        reason: 'ShowAt 懒建与 PrewarmWebView 预热两个创建点必须一致，'
            '否则预热窗与重建窗任务栏行为漂移');
    expect('window_title_.c_str()'.allMatches(cpp).length,
        greaterThanOrEqualTo(2),
        reason: '两个创建点都必须用可设置的 window_title_（任务栏按钮文案）');
    expect(cpp.contains('L"Hibiki Lookup", WS_POPUP'), isFalse,
        reason: '不得残留写死的创建标题（回归 signature）');
  });

  test('窗口类注册 app 图标（任务栏/Alt-Tab 图标）', () {
    final int at = cpp.indexOf('RegisterClassExW(&wc)');
    expect(at, greaterThanOrEqualTo(0));
    final String before = cpp.substring(0, at);
    expect(before, contains('MAKEINTRESOURCE(IDI_APP_ICON)'),
        reason: '类注册前必须 LoadIcon(IDI_APP_ICON)，否则任务栏按钮是默认白框图标');
  });

  test('native SetWindowTitle 对已建窗口 SetWindowTextW 即时生效', () {
    final int at = cpp.indexOf('void GlobalLookupWindow::SetWindowTitle(');
    expect(at, greaterThanOrEqualTo(0));
    final String body = cpp.substring(at, cpp.indexOf('\n}', at));
    expect(body, contains('SetWindowTextW'), reason: '面板启动即预热，标题晚到必须能更新已存在的窗口');
  });

  test('头文件声明 SetTaskbarPresence / SetWindowTitle / 成员', () {
    expect(hdr, contains('void SetTaskbarPresence(bool present)'));
    expect(hdr, contains('void SetWindowTitle(const std::wstring& title);'));
    expect(hdr, contains('bool taskbar_presence_ = false;'),
        reason: '默认 false：瞬态覆盖窗零变化');
  });

  test('Dart 面板 start() 在预热前下发本地化标题', () {
    final int title = controller.indexOf('setWindowTitle(');
    final int prewarm = controller.indexOf('ensurePrewarmed()');
    expect(title, greaterThanOrEqualTo(0),
        reason: 'start() 必须下发 t.clipboard_panel_window_title');
    expect(controller, contains('t.clipboard_panel_window_title'),
        reason: '标题必须走 slang 本地化 key');
    expect(title, lessThan(prewarm), reason: '标题必须在窗口创建（预热）之前就位，任务栏按钮首帧即正确文案');
  });
}
