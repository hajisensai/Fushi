import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2447：macOS 上在查词弹窗里展开/折叠词典分组之后，宿主页面的快捷键整条失效。
///
/// 根因不在快捷键绑定层，而在**谁持有 OS 键盘焦点**：`<summary>` 是弹窗里唯一「鼠标
/// 点一下就会拿到 DOM 焦点」的元素（按钮与链接在 macOS WebKit 下按平台惯例
/// `isMouseFocusable` 恒为 false，释义正文与留白根本不可聚焦）。节点一获焦，WebKit
/// 就让承载它的 WKWebView 成为窗口 first responder，此后按键全部进 WebKit，
/// `FlutterViewController` 再也收不到。macOS 侧**没有任何东西能把 first responder
/// 还回来**：Flutter 引擎的 `FlutterMutatorView` / `FlutterPlatformViewController`
/// 整层没有 firstResponder 代码；`PageFocusOwnership.reclaim` 只动 Flutter 自己的焦点
/// 树；Windows 那条兜底（fork 的 `custom_platform_view` 每次 `onPointerDown` 都
/// `requestFocus`）依赖 WebView2 的无窗口合成，真原生 WKWebView 上并不存在。于是
/// 只剩弹窗 JS 桥一条路，而它按构造只转发宿主显式声明的那两三个动作（BUG-1269 修的
/// 就是那条桥），其余绑定全部落空。
///
/// 修复：`<summary>` 的主键 mousedown 取消默认动作，掐断「点击 → 节点获焦」这一步。
/// `<details>` 的开合是 `click` 的 activation behavior，与 mousedown 的默认动作无关，
/// 照常发生；Tab 聚焦也不受影响（只有**鼠标**聚焦是 mousedown 的默认动作）。
///
/// 本 wrapper 只负责驱动 node 真执行 popup.js 里的 `createGlossarySection` 并拿它
/// 实际挂上去的监听派发事件——判据与分层说明都写在同名 `.js` 里。无 node 时 skip。
void main() {
  test(
    'dict <summary> cancels primary-button mousedown so it never takes DOM focus '
    '(executes popup.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest =
          File('test/dictionary/popup_summary_mouse_focus_test.js');
      expect(jsTest.existsSync(), isTrue,
          reason: 'behavior harness ${jsTest.path} must exist');

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason: 'popup <summary> mouse-focus behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'),
          reason: 'behavior harness must reach its success marker');
    },
  );
}

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
