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
    // （TODO-904 P0 回归修复在 return 前插入了路径转交，窗口适当放宽到 1400 字符。）
    final int idx = src.indexOf('GetLastError() == ERROR_ALREADY_EXISTS');
    final String after = src.substring(idx, (idx + 1400).clamp(0, src.length));
    expect(after.contains('return EXIT_SUCCESS;'), isTrue,
        reason: '命中已有实例必须退出本进程，不再创建第二个共享 userDataFolder 的实例');
  });

  // TODO-904 P0 回归守卫：单实例守卫退出前，必须把「用 Hibiki 打开视频」的文件
  // 路径经 WM_COPYDATA 转交首实例，否则第二实例只前置窗口就退出 = 视频路径整个
  // 丢掉、首实例从不知情 →「点了没反应」。
  test('main.cpp 退出前用 WM_COPYDATA 把视频路径转交首实例', () {
    final String src = read('windows/runner/main.cpp');

    // 退出第二实例前必须解析 argv 文件参数并经 SendExternalVideoPath 转交。
    expect(src.contains('FirstFileArgFromCommandLine()'), isTrue,
        reason: '第二实例必须从 argv 解出视频文件参数');
    expect(src.contains('::hibiki::SendExternalVideoPath('), isTrue,
        reason: '第二实例退出前必须经 WM_COPYDATA 把视频路径转交首实例（不能丢路径）');

    // 转交必须发生在 ERROR_ALREADY_EXISTS 早退分支内（退出之前）。
    final int idx = src.indexOf('GetLastError() == ERROR_ALREADY_EXISTS');
    final int exitIdx = src.indexOf('return EXIT_SUCCESS;', idx >= 0 ? idx : 0);
    final int handoffIdx = src.indexOf('::hibiki::SendExternalVideoPath(');
    expect(idx >= 0 && handoffIdx > idx && handoffIdx < exitIdx, isTrue,
        reason: '路径转交必须在单实例早退分支内、return 之前发生');

    // 只在有文件参数时发送：纯第二次启动（无文件参数）维持「只前置 + 退出」。
    expect(src.contains('if (!file_arg.empty())'), isTrue,
        reason: '无文件参数时不应发送 WM_COPYDATA（只前置 + 退出）');
  });

  test('runner 发送/接收 WM_COPYDATA 路径转交链路在位', () {
    final String handoff = read('windows/runner/external_video_handoff.cpp');
    // 发送端：用 WM_COPYDATA 携带 magic dwData，避免与系统拖放等其它 WM_COPYDATA 混淆。
    expect(handoff.contains('WM_COPYDATA'), isTrue,
        reason: '转交必须走 WM_COPYDATA');
    expect(handoff.contains('kExternalVideoCopyDataMagic'), isTrue,
        reason: 'dwData 必须带 magic 区分本协议消息');

    // 接收端：窗口过程必须处理 WM_COPYDATA → 经 channel 推给 Dart。
    final String fw = read('windows/runner/flutter_window.cpp');
    expect(fw.contains('case WM_COPYDATA:'), isTrue,
        reason: 'MessageHandler 必须处理 WM_COPYDATA');
    expect(fw.contains('::hibiki::DecodeExternalVideoPath('), isTrue,
        reason: '必须用 DecodeExternalVideoPath 解出路径（magic 不匹配则忽略）');
    expect(
        fw.contains('app.hibiki/external_video') &&
            fw.contains('openExternalVideo'),
        isTrue,
        reason: '收到路径必须经 app.hibiki/external_video channel 推给 Dart');

    // Dart 端：复用现有 _openExternalVideo 打开链路，不另造第二套。
    final String main = read('lib/main.dart');
    expect(main.contains("MethodChannel('app.hibiki/external_video')"), isTrue,
        reason: 'Dart 必须注册 app.hibiki/external_video channel');
    expect(
        main.contains('_handleExternalVideoChannel') &&
            main.contains('_openExternalVideo('),
        isTrue,
        reason: '收到转交路径必须复用现有 _openExternalVideo 打开链路');
  });
}
