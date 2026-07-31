import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1265 守卫：查词卡的低级鼠标钩子必须**持续**在线，而不是「装一次就当永远有效」。
///
/// `WH_MOUSE_LL` 是 Windows 会主动吊销的资源：回调超过 `LowLevelHooksTimeout`
/// （HKCU\Control Panel\Desktop，默认 300ms）没返回，系统就把它从钩子链上摘掉，既不
/// 通知也不让 `HHOOK` 失效。查词卡是 `WS_EX_NOACTIVATE` 的 topmost 窗，点击**只能**
/// 靠这条钩子投递（`global_lookup_window.cpp` 的 `kLowLevelMouseClickMessage`），所以
/// 钩子一旦被摘就再也点不动——而台词照常刷新（那条走 IPC→ExecuteScript），表现成
/// 「浮窗看得见、点不动，只能重启」。玩 galgame 时进程内同时有词典 FFI、WebView2 COM、
/// 语音捕获与转码在抢核，超时是现实会发生的。
///
/// 这条守卫扫源码而不是跑行为：钩子逻辑在 C++ runner 里，Dart 侧无法驱动。为避免
/// 「注释里写了字面量就算过」的假绿，扫描前先剥掉注释。
void main() {
  late String source;

  setUpAll(() {
    final File file = File('windows/runner/low_level_mouse_hook.cpp');
    expect(
      file.existsSync(),
      isTrue,
      reason: '守卫的目标文件不存在，说明钩子实现被挪走了，必须同步更新本测试',
    );
    source = _stripComments(file.readAsStringSync());
  });

  test('回调在任何过滤分支之前就记录存活证据', () {
    final int tickStore = source.indexOf('g_callback_tick.store(');
    expect(
      tickStore,
      greaterThanOrEqualTo(0),
      reason: '回调必须留下「我被调用过」的证据，否则无从判断钩子是否还在链上',
    );

    // 存活证据必须由**移动事件**刷新——它才是每秒都有的那类。记在 `code < 0` /
    // 非点击非滚轮的提前 return 之后，就只剩点击和滚轮能刷新，判据当场失效。
    final int earlyReturn = source.indexOf('if (code < 0');
    expect(earlyReturn, greaterThanOrEqualTo(0));
    expect(
      tickStore,
      lessThan(earlyReturn),
      reason: '存活证据必须记在过滤分支之前，否则移动事件刷新不到它',
    );
  });

  test('钩子线程按周期把实际钩子状态收敛到 g_target', () {
    expect(
      source.contains('kLivenessIntervalMs'),
      isTrue,
      reason: '必须有周期性的存活性核对，而不是只在 Arm 时装一次',
    );
    expect(
      RegExp(r'SetTimer\(nullptr, 0, kLivenessIntervalMs').hasMatch(source),
      isTrue,
      reason: '核对定时器必须真的被建起来',
    );

    // armed（g_target 非空）却没有钩子时补装：这一条同时兜住 SetWindowsHookEx 失败
    // 与 kThreadArm 消息根本没送达（PostThreadMessage 会失败且旧实现不检查返回值）。
    final int livenessBranch = source.indexOf('msg.wParam == liveness_timer');
    expect(
      livenessBranch,
      greaterThanOrEqualTo(0),
      reason: '必须有独立的存活性核对分支',
    );
    final String livenessBody = source.substring(livenessBranch);
    expect(
      livenessBody.contains('g_target.load'),
      isTrue,
      reason: '核对必须以 g_target 为 armed 真值，而不是另建一套状态',
    );

    // 核对分支里必须既能补装、又能先卸后重装（被系统摘掉时 HHOOK 仍非空）。
    final int nextBranch = livenessBody.indexOf('} else if (msg.message ==');
    final String scoped =
        nextBranch > 0 ? livenessBody.substring(0, nextBranch) : livenessBody;
    expect(
      RegExp('SetWindowsHookEx').allMatches(scoped).length,
      greaterThanOrEqualTo(2),
      reason: '核对分支要覆盖「补装」和「重装」两条路径',
    );
    expect(
      scoped.contains('UnhookWindowsHookEx'),
      isTrue,
      reason: '重装前必须先卸掉旧句柄，否则泄漏钩子',
    );
  });

  test('吊销判据用光标位移，不是「一段时间没事件」', () {
    final int livenessBranch = source.indexOf('msg.wParam == liveness_timer');
    expect(livenessBranch, greaterThanOrEqualTo(0));
    final String livenessBody = source.substring(livenessBranch);
    final int nextBranch = livenessBody.indexOf('} else if (msg.message ==');
    final String scoped =
        nextBranch > 0 ? livenessBody.substring(0, nextBranch) : livenessBody;

    // 「光标动了但回调一次没跑」才是零误报判据。只看「N 秒没事件」会把「用户没动
    // 鼠标」误判成吊销，于是空闲时反复重装全局钩子——那本身就是一次次全系统输入抖动。
    expect(
      scoped.contains('GetCursorPos'),
      isTrue,
      reason: '判据必须包含光标位移，否则空闲会被误判成吊销',
    );
    expect(
      RegExp(r'cursor\.x != last_cursor\.x').hasMatch(scoped),
      isTrue,
      reason: '必须真的比较光标坐标',
    );
    expect(
      RegExp(r'seen_tick == last_seen_tick').hasMatch(scoped),
      isTrue,
      reason: '必须同时要求「回调一次都没跑」，两个条件缺一都会误判',
    );
  });
}

/// 剥掉 `//` 行注释与 `/* */` 块注释。
///
/// 不剥就等于允许「把断言要找的字面量写进注释」蒙混过关——本仓库出过这类假绿。
String _stripComments(String source) {
  final String withoutBlocks =
      source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlocks.split('\n').map((String line) {
    final int idx = line.indexOf('//');
    return idx >= 0 ? line.substring(0, idx) : line;
  }).join('\n');
}
