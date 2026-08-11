import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1541 回归守卫（源码扫描；vendored 的 Windows 原生插件 C++ 在 headless
/// Dart 测试里跑不到 —— 既没有 GameInput.h，也没有真手柄/真蓝牙断连，故守住
/// 「重连自愈」这条链路的代码契约）。
///
/// 现象：蓝牙手柄待机一段时间（设备掉出 GameInput 的 Connected 状态）后再按
/// 按钮，app 完全没反应，必须重启 app。
///
/// 根因（`packages/gamepads_windows/windows/gamepad.cpp`）：
///   ① `on_gamepad_disconnected` 跑在 GameInput 的设备回调线程上，却直接
///      `join_and_destroy` → `std::thread::join()`；被 join 的轮询线程正卡在
///      `g_gameInput->GetCurrentReading()` 里。回调线程被按住，手柄唤醒时那次
///      「连接」回调就再也派发不出来 → 永不重建轮询线程 → 手柄彻底死掉。
///   ② `on_gamepad_disconnected` 在 `GetDeviceInfo()` 返回 null（设备已被系统
///      摘掉，正是待机场景）时直接 return，条目与其轮询线程永久留在册子里对着
///      死设备空转。
///   ③ `on_gamepad_connected` 不去重：漏掉的「断开」回调会让旧条目和新条目并存。
///   ④ 断连时上层收不到「松开」帧，`GamepadFrameState` 把按下态永久锁住。
///
/// 修复契约（谁改回去，本测试红）：
///   ① 设备回调线程只做非阻塞的 `retire()` 移交，join 交给自己的收割线程；
///   ② 断开时 `GetDeviceInfo()` 失败要退化成按设备指针匹配，绝不放过摘除；
///   ③ 连接时按 deviceId / 设备指针清掉同一物理手柄的陈旧条目；
///   ④ 轮询线程掉线与收工时补发「松开」事件（`neutralize_inputs`）。
void main() {
  const String pkg = '../packages/gamepads_windows/windows';
  final String gamepadCpp = File('$pkg/gamepad.cpp').readAsStringSync();
  final String gamepadH = File('$pkg/gamepad.h').readAsStringSync();

  /// 切出 `Gamepads::<name>` 这一个定义的函数体（到下一个顶层 `Gamepads::`
  /// 定义为止），避免整文件 contains 造成的假绿。
  String bodyOf(String name) {
    final RegExp defs =
        RegExp(r'^[\w:<>*& ]+Gamepads::(\w+)\(', multiLine: true);
    final List<RegExpMatch> all = defs.allMatches(gamepadCpp).toList();
    final int index = all.indexWhere((RegExpMatch m) => m.group(1) == name);
    expect(index, greaterThanOrEqualTo(0),
        reason: 'gamepad.cpp 里找不到 Gamepads::$name 的定义');
    final int start = all[index].start;
    final int end =
        index + 1 < all.length ? all[index + 1].start : gamepadCpp.length;
    return gamepadCpp.substring(start, end);
  }

  group('BUG-1541 蓝牙手柄待机重连自愈（vendored 原生源码契约）', () {
    test('① 断开回调不得在 GameInput 回调线程上 join', () {
      final String body = bodyOf('on_gamepad_disconnected');
      expect(body.contains('join_and_destroy'), isFalse,
          reason: '①：on_gamepad_disconnected 跑在 GameInput 回调线程上，'
              'join_and_destroy 会阻塞它并吞掉后续的「连接」回调');
      expect(body.contains('.join()'), isFalse, reason: '①：断开回调内不得有任何 join');
      expect(body, contains('retire('), reason: '①：断开只能把条目移交给收割线程（retire）');
    });

    test('① retire 只入队 + 唤醒，收割线程负责 join', () {
      final String retireBody = bodyOf('retire');
      expect(retireBody.contains('.join()'), isFalse,
          reason: '①：retire 必须非阻塞（会被 GameInput 回调线程调用）');
      expect(retireBody, contains('reaper_cv.notify_one()'),
          reason: '①：retire 须唤醒收割线程');
      final String reapBody = bodyOf('reap_loop');
      expect(reapBody, contains('join_and_destroy'),
          reason: '①：join + 释放的活儿归收割线程 reap_loop');
      expect(gamepadH, contains('std::thread reaper_thread'),
          reason: '①：收割线程句柄须被持有（可 join，不 detach）');
      expect(gamepadH, contains('std::condition_variable reaper_cv'),
          reason: '①：收割线程须由条件变量驱动，不是轮询/定时重启');
    });

    test('① init 在注册设备回调前就把收割线程拉起来', () {
      final String initBody = bodyOf('init');
      final int reaperStart = initBody.indexOf('reap_loop');
      final int registerStart = initBody.indexOf('RegisterDeviceCallback');
      expect(reaperStart, greaterThanOrEqualTo(0), reason: '①：init 须启动收割线程');
      expect(registerStart, greaterThan(reaperStart),
          reason: '①：收割线程必须早于 RegisterDeviceCallback 就绪，'
              '否则第一次断开回调就没人接手');
    });

    test('① stop 仍然 join 收割线程（teardown 不留悬空线程，BUG-116 不变式）', () {
      final String stopBody = bodyOf('stop');
      expect(stopBody, contains('reaper_thread.join()'),
          reason: '①：stop 须 join 收割线程');
      expect(stopBody, contains('drain_retired()'),
          reason: '①：收割线程未启动时 stop 须在本线程兜底排空');
    });

    test('② 断开时 GetDeviceInfo 失败要退化成按设备指针匹配，不得 return', () {
      final String body = bodyOf('on_gamepad_disconnected');
      expect(body, contains(r'(*it)->device == device'),
          reason: '②：GetDeviceInfo 返回 null 时须按 AddRef 过的设备指针匹配');
      expect(body.contains('failed to read info" << std::endl;\n    return;'),
          isFalse,
          reason: '②：info 为 null 时直接 return 会让条目和轮询线程永久泄漏');
    });

    test('③ 连接时清掉同一物理手柄的陈旧条目', () {
      final String body = bodyOf('on_gamepad_connected');
      expect(body, contains(r'(*it)->id == gp->id'),
          reason: '③：同 deviceId 的旧条目须被摘除（漏掉的断开回调的自愈路径）');
      expect(body, contains(r'(*it)->device == device'),
          reason: '③：同设备指针的旧条目也须被摘除');
      expect(body, contains('retire('), reason: '③：摘下来的旧条目须交给收割线程');
    });

    test('④ 轮询线程掉线/收工时补发「松开」，上层状态不被锁死', () {
      final String body = bodyOf('read_gamepad');
      expect(body, contains('GetDeviceStatus()'),
          reason: '④：轮询循环须感知设备是否还 Connected，'
              '而不是对着死设备一直 GetCurrentReading');
      expect(body, contains('GameInputDeviceConnected'),
          reason: '④：须按 Connected 位判断');
      expect(
          body.split('neutralize_inputs').length - 1, greaterThanOrEqualTo(2),
          reason: '④：掉线分支与线程收工前都要补发松开事件');
      final String neutralizeBody = bodyOf('neutralize_inputs');
      expect(neutralizeBody, contains('diff_states'),
          reason: '④：松开事件须由当前状态与中立状态求差得到');
      expect(neutralizeBody, contains('event_emitter'),
          reason: '④：补发的松开事件须真的发给上层');
    });

    test('不得用「定时全量重启轮询」这类掩盖式补丁', () {
      expect(gamepadCpp.contains('SetTimer'), isFalse,
          reason: '重连自愈须由设备状态/设备回调驱动，不是定时器兜底');
      expect(gamepadCpp.contains('read_thread.detach()'), isFalse,
          reason: 'BUG-116 不变式：轮询线程永不 detach');
    });
  });
}
