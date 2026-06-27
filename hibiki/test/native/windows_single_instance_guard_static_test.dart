import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-904 / BUG-437 源码守卫：Windows runner 真单实例。
///
/// 根因放大器：原 `main.cpp` 只 `CreateMutexW(...)` 不查 `ERROR_ALREADY_EXISTS` =
/// 没有真单实例。第二个 hibiki.exe 与首实例共享同一 WebView2 默认 userDataFolder，
/// 而 WebView2 契约不允许多进程并发同一 userDataFolder → 第二实例 env 创建锁冲突失败
/// → `Cannot create the InAppWebView instance!`。
///
/// 修复：检测 `GetLastError()==ERROR_ALREADY_EXISTS` 则前置首实例窗口并退出本进程。
///
/// 守卫断言修复结构在位。删掉即红。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('main.cpp 检测 ERROR_ALREADY_EXISTS 并退出第二实例', () {
    final String src = read('windows/runner/main.cpp');

    // 必须是真正的运行期检查（GetLastError），而非仅注释提到。
    expect(src.contains('GetLastError() == ERROR_ALREADY_EXISTS'), isTrue,
        reason: '必须检测 GetLastError()==ERROR_ALREADY_EXISTS（真单实例守卫）');
    // 命中已有实例时退出本进程：取该检查之后到函数体一段，断言含早退。
    final int idx = src.indexOf('GetLastError() == ERROR_ALREADY_EXISTS');
    final String after = src.substring(idx, (idx + 600).clamp(0, src.length));
    expect(after.contains('return EXIT_SUCCESS;'), isTrue,
        reason: '命中已有实例必须退出本进程，不再创建第二个共享 userDataFolder 的实例');
  });
}
