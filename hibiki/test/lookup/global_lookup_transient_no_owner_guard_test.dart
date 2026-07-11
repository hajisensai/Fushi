import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-741 — 瞬态查词覆盖窗（悬浮字幕点词/全局热键/面板点释义）不得 owned by
/// 主窗（源码扫描守卫）。
///
/// 真机根因：`flutter_window.cpp` 里瞬态实例 `global_lookup_window_` 的 `ShowAt`
/// / `PrewarmWebView` 曾把主窗 HWND（`GetHandle()`）当 owner 传入。owned 顶层窗
/// 的 Z 序变更**连带把 owner 主窗拉到前台**（真机第 4 轮对面板确认的同一机制，
/// 见 `flutter_window.cpp` 面板 prewarm 注释）——用户症状=悬浮字幕点词/热键查词
/// 时 app 主窗被拽到前台，盖住底下的游戏/视频，违反 app 外查词覆盖窗「绝不夺
/// 前台」契约（design §5 guarantee 3）。
///
/// 修复：瞬态窗与面板窗一致，owner 传 `nullptr`（无 owner）。瞬态窗短命且
/// `arm_dismiss_hooks=true`（前台切换即自关），主窗最小化时照样收纳，无孤儿窗。
///
/// 覆盖窗真弹出依赖 native，headless 测不了，故用源码扫描钉住契约。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  late String cpp;
  setUpAll(() {
    cpp = read('windows/runner/flutter_window.cpp');
  });

  /// 抽出从某个方法调用起点到其结尾 `);` 的片段。
  String callArgs(String src, String callee) {
    final int at = src.indexOf(callee);
    expect(at, greaterThanOrEqualTo(0), reason: '必须存在调用：$callee');
    final int end = src.indexOf(');', at);
    expect(end, greaterThan(at));
    return src.substring(at, end + 2);
  }

  test('瞬态 global_lookup_window_->ShowAt 用 nullptr owner（不拉主窗前台）', () {
    final String seg = callArgs(cpp, 'global_lookup_window_->ShowAt(');
    expect(seg, contains('nullptr'),
        reason: 'BUG-741：owner 必须 nullptr，否则 owned 窗 Z 序连带拉主窗前台');
    expect(seg.contains('GetHandle()'), isFalse,
        reason: '不得把主窗 HWND 当 owner（回归 signature）');
  });

  test('瞬态 global_lookup_window_->PrewarmWebView 用 nullptr owner', () {
    final String seg = callArgs(cpp, 'global_lookup_window_->PrewarmWebView(');
    expect(seg, contains('nullptr'),
        reason: 'prewarm 与 showAt owner 必须一致，否则 ForgetDeadWindow 重建 owner 漂移');
    expect(seg.contains('GetHandle()'), isFalse, reason: '不得把主窗 HWND 当 owner');
  });

  test('面板 clipboard_panel_window_ 同样保持 nullptr owner（回归保护）', () {
    for (final String callee in <String>[
      'clipboard_panel_window_->ShowAt(',
      'clipboard_panel_window_->PrewarmWebView(',
    ]) {
      final String seg = callArgs(cpp, callee);
      expect(seg, contains('nullptr'), reason: '面板窗必须无 owner：$callee');
      expect(seg.contains('GetHandle()'), isFalse,
          reason: '面板窗不得 owned：$callee');
    }
  });
}
