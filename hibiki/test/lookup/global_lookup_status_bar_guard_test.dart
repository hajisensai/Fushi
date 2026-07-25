// BUG-1097 源码守卫：查词浮窗不得再画 WebView2 的链接地址预览（status bar）。
//
// 用户看到的 `https://hibiki.popup/popup.html?query=…&wildcards=off` 是 WebView2 自带的
// status bar：Yomitan 结构化内容把词典内链原样写进 href，hover 就触发预览；onclick 的
// preventDefault 只拦点击，拦不住预览。覆盖窗是撑满级联包围盒的 topmost 无边框窗，
// 于是预览画在它自己的左下角，看着像「主窗口左下角冒出一条 URL」。
//
// 修复必须落在 ConfigureWebView() 里——它是 composition / windowed 两条创建路径与
// BUG-693 自愈重建的唯一漏斗。C++ 无法在 Dart 测试里执行，故在源码层锁定：
//   ① put_IsStatusBarEnabled(FALSE) 确实在 ConfigureWebView() 函数体内；
//   ② 失败被上报而不是静默吞掉；
//   ③ href 没被顺手删掉（点击处理仍要用它，那是 BUG-842 划在范围外的另一件事）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 取出 `GlobalLookupWindow::[name]` 的函数体源码（到下一个成员函数定义为止）。
/// 在 main() 顶层调用，故不能用 expect（那是 OutsideTestException），直接抛。
String _memberSource(String src, String name) {
  final int start = src.indexOf('void GlobalLookupWindow::$name() {');
  if (start < 0) {
    throw StateError('GlobalLookupWindow::$name 必须存在（守卫依赖它作为唯一漏斗）');
  }
  final int next = src.indexOf('\nvoid GlobalLookupWindow::', start + 1);
  return src.substring(start, next == -1 ? src.length : next);
}

void main() {
  final String src =
      File('windows/runner/global_lookup_window.cpp').readAsStringSync();
  final String configure = _memberSource(src, 'ConfigureWebView');

  test('① status bar 在 ConfigureWebView() 里被关掉（BUG-1097）', () {
    expect(
      configure.contains('put_IsStatusBarEnabled(FALSE)'),
      isTrue,
      reason: '必须在 ConfigureWebView() 内关闭——它是 composition / windowed 两条创建路径 '
          '与 BUG-693 自愈重建的唯一漏斗；散在单条路径里会漏掉重建出来的新 surface',
    );
    expect(
      configure.contains('webview_->get_Settings(&settings)'),
      isTrue,
      reason:
          'put_IsStatusBarEnabled 在基类 ICoreWebView2Settings 上，走 get_Settings 即可，'
          '不需要 QI 新版本接口',
    );
  });

  test('② 关闭失败必须上报，不得静默吞掉', () {
    expect(
      configure.contains('ReportOverlayError("put_IsStatusBarEnabled(FALSE) '),
      isTrue,
      reason: '一旦失败那条 URL 就会回来；HRESULT 被吞掉就只能从零重查一遍',
    );
  });

  test('③ 词典内链的 href 保持不动（本轮只关 status bar）', () {
    final String popupJs = File('assets/popup/popup.js').readAsStringSync();
    expect(
      popupJs.contains("setAttribute('href', node.href)"),
      isTrue,
      reason: 'href 是点击处理的输入，不得为了消掉预览而删链接；'
          '「原生提示窗定位」是 BUG-842 家族的另一件事，本轮不动',
    );
  });
}
