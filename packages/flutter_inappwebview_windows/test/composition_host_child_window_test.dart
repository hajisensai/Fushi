import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3867：composition 模式下 WebView2 的宿主 HWND 必须是 Flutter 视图的子窗口。
///
/// 上游建的是 style 0 的 owned 顶层窗口。Chromium 拿键盘焦点（SetFocus 自己挂在宿主下
/// 的子窗）时，激活窗口随之换成这个隐藏顶层、主窗口失活；用户下一次真鼠标点击要重新激活
/// 主窗口，runner 在 WM_ACTIVATE 里把焦点还给 Flutter 视图，网页先收到 blur 再收到
/// mousedown，YouTube 设置菜单的二级项每点必关。Flutter 层合成指针不经系统激活流程，
/// 测不到这条；端到端证据是
/// `fushi/integration_test/web_browser_youtube_menu_probe_itest.dart` 的真鼠标模式
/// （`-Visible -DartDefine FUSHI_YT_REAL_INPUT=1`，需要可见桌面，不进 CI）。
/// 这里钉住原生侧的建窗样式。
void main() {
  test('composition 宿主窗口带 WS_CHILD（不是 owned 顶层）', () {
    final String source = File(
      'windows/in_app_webview/in_app_webview_manager.cpp',
    ).readAsStringSync();
    final RegExp createCall = RegExp(
      r'CreateWindowEx\(0, windowClass_\.lpszClassName, L"",\s*'
      r'windowedHosting \? \(([^)]*)\) : ([A-Z_| 0-9]+),',
    );
    final RegExpMatch? match = createCall.firstMatch(source);
    expect(match, isNotNull, reason: '找不到宿主 HWND 的 CreateWindowEx 调用');
    expect(match!.group(1), contains('WS_CHILD'));
    final String compositionStyle = match.group(2)!.trim();
    expect(
      compositionStyle,
      contains('WS_CHILD'),
      reason: 'composition 宿主不是子窗口时，网页得焦会把激活窗口换走（BUG-3867）',
    );
    expect(
      compositionStyle,
      isNot(contains('WS_VISIBLE')),
      reason: 'composition 宿主只作 DComp 宿主，不能显示出来挡住 Flutter 画面',
    );
  });
}
