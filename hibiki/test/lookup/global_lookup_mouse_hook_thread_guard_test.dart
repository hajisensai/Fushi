import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1048 的静态守卫：全局查词浮窗的 `WH_MOUSE_LL` 必须装在**专用线程**上。
///
/// 低级鼠标钩子是同步钩子——系统把每个鼠标事件（含高频移动）投递到安装钩子的线程的
/// 消息队列，等它返回或超时才继续分发。装在 Flutter 的 platform 线程上时，全系统鼠标
/// 输入就排在 Dart 渲染与 platform channel 之后：用户实测「galgame 里点一次查词，之后
/// 鼠标移动全程卡；不查词就没事」。
///
/// 这条路径没法在 Dart 侧行为测试里复现（纯 Win32 + 真实输入队列），最强可落地层就是
/// 锁住修复的结构：
///   ① `global_lookup_window.cpp` 不得再自己 `SetWindowsHookEx(WH_MOUSE_LL, ...)`；
///   ② 钩子只在 `low_level_mouse_hook.cpp` 里装，且那里必须有自己的线程 + 消息循环；
///   ③ 钩子回调只 `PostMessage`（异步）回窗口线程，不得 `SendMessage`（同步会把窗口
///      线程的忙闲重新拽回输入路径，等于没修）；
///   ④ 新源文件真的进了 runner 的 CMake 目标（否则链接不到，改动等于没编）。
void main() {
  const String runnerDir = 'windows/runner';
  String read(String name) => File('$runnerDir/$name').readAsStringSync();

  test('查词浮窗不再在自己的线程上装低级鼠标钩子', () {
    final String window = read('global_lookup_window.cpp');
    expect(
      window.contains('SetWindowsHookEx'),
      isFalse,
      reason: 'BUG-1048：钩子必须交给 low_level_mouse_hook 的专用线程安装',
    );
    expect(
      window.contains('hibiki::ArmLowLevelMouseHook'),
      isTrue,
      reason: '浮窗显示时应通过专用线程装钩子',
    );
    expect(
      window.contains('hibiki::DisarmLowLevelMouseHook'),
      isTrue,
      reason: '浮窗隐藏/析构时必须卸钩子，否则钩子会一直拦全系统鼠标',
    );
  });

  test('低级鼠标钩子跑在自己的线程 + 消息循环上', () {
    final String hook = read('low_level_mouse_hook.cpp');
    expect(hook.contains('SetWindowsHookEx(WH_MOUSE_LL'), isTrue);
    expect(hook.contains('std::thread'), isTrue, reason: '钩子必须有自己的承载线程');
    expect(hook.contains('GetMessage('), isTrue,
        reason: '低级钩子事件靠线程消息队列分发，线程必须有消息循环');
  });

  test('钩子回调只异步投递，不同步等窗口线程', () {
    final String hook = read('low_level_mouse_hook.cpp');
    expect(hook.contains('PostMessage('), isTrue);
    expect(
      hook.contains('SendMessage('),
      isFalse,
      reason: 'SendMessage 会阻塞到窗口线程处理完，等于把卡顿原样搬回来',
    );
  });

  test('钩子线程源文件已接入 runner CMake 目标', () {
    final String cmake = read('CMakeLists.txt');
    expect(cmake.contains('"low_level_mouse_hook.cpp"'), isTrue);
  });
}
