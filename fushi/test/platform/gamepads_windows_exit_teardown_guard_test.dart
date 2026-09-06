import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2167：Windows 每次退出 fail-fast 崩溃 `0xc0000409`。
///
/// 根因不在更新链上，但整条应用内更新链都挂在它下面，所以守卫放在这里：
///
/// `packages/gamepads_windows/windows/gamepad.cpp` 里的 `Gamepads gamepads;` 是
/// **静态存储期**全局对象，成员含 `std::thread reaper_thread`。进程退出时 CRT 的
/// onexit 表析构它，而 `std::thread` 的析构函数对**仍 joinable** 的线程直接
/// `std::terminate()` → `abort()`。Fushi 的两条退出路径（更新交接、关窗）最终都调
/// `exit(0)`，而 `exit(0)` 故意跳过 Flutter 插件析构 —— 于是
/// `~GamepadsWindowsPlugin()` 里的 `stop()` 永远不跑，`reaper_thread` 带着
/// joinable 状态活到 onexit 表，**每一次退出都崩**。
///
/// 实测转储（`fushi.exe.17436.dmp`，`!analyze -v`）：
/// ```text
/// FAILURE_BUCKET_ID: FAIL_FAST_FATAL_APP_EXIT_c0000409_ucrtbase.dll!abort
/// ucrtbase!abort+0x4e
/// gamepads_windows_plugin+0xa2ca
/// ucrtbase!execute_onexit_table+0x3d
/// gamepads_windows_plugin+0x1006d
/// ```
///
/// 下游代价：崩溃进程被 WER 冻住数分钟不死，`FushiSingleInstanceMutex` 一直被持有，
/// 于是 `fushi_update_launcher.exe` 的「等父进程退出」（120s）和「等互斥量释放」
/// （10s）双双超时（现场 marker 实录 `parentExitObserved:false`）。
///
/// 本守卫钉住的不变式：**`Gamepads` 必须有析构函数，且它必须真的处置
/// `reaper_thread`**。删掉析构函数正是回归本身；把它改成一句 `stop()` 则是把崩溃
/// 换成卡死（`stop()` 要 `UnregisterCallback(5s)` 并 join 可能停在 GameInput 锁里的
/// 轮询线程），所以这里同样拦。真正的行为验证只能在 Windows 上跑真 app 退出后查
/// 事件日志有无 `0xc0000409`——这层守卫只保证代码结构不被悄悄改回去。
void main() {
  group('BUG-2167 gamepads 全局对象退出期 teardown', () {
    late final String header;
    late final String source;

    setUpAll(() {
      header = File('../packages/gamepads_windows/windows/gamepad.h')
          .readAsStringSync();
      source = File('../packages/gamepads_windows/windows/gamepad.cpp')
          .readAsStringSync();
    });

    test('前提仍然成立：全局对象 + std::thread 成员', () {
      // 这两条是本 bug 的**成因前提**。哪天上游把全局改掉、或线程不再是成员，
      // 守卫的理由就变了，应该有人重新想一遍而不是让它继续恒真地绿着。
      expect(source, contains('Gamepads gamepads;'),
          reason: '不再是静态存储期全局对象了？重新评估本守卫。');
      expect(header, contains('std::thread reaper_thread;'),
          reason: 'reaper_thread 不再是 std::thread 成员了？重新评估本守卫。');
    });

    test('Gamepads 声明并实现了析构函数', () {
      expect(header, contains('~Gamepads();'),
          reason: '没有析构函数 = joinable 的 reaper_thread 直接走到 '
              'std::thread 的析构函数 = std::terminate() = 每次退出必崩。');
      expect(source, contains('Gamepads::~Gamepads()'));
    });

    test('析构函数处置 reaper_thread，且不阻塞在 stop() 上', () {
      final int start = source.indexOf('Gamepads::~Gamepads()');
      expect(start, greaterThan(-1));
      final int bodyStart = source.indexOf('{', start);
      final int bodyEnd = source.indexOf('\n}', bodyStart);
      expect(bodyEnd, greaterThan(bodyStart));
      final String body = source.substring(bodyStart, bodyEnd);

      expect(body, contains('reaper_thread'),
          reason: '析构函数没碰 reaper_thread —— 那它没有解决任何问题。');
      expect(body, contains('reaper_stop'),
          reason: '不置停止位就等，reaper 永远醒不过来。');
      expect(body, contains('detach()'),
          reason: '缺少「等不到就 detach」的兜底：一旦等超时，'
              'std::thread 的析构函数仍会 terminate。');
      expect(body, contains('WaitForSingleObject'),
          reason: 'std::thread 没有带超时的 join，必须用底层句柄做有界等待。');
      expect(body, isNot(contains('stop()')),
          reason: '退出路径上调 stop() 会 UnregisterCallback(5s) 并 join 可能'
              '停在 GameInput 锁里的轮询线程 —— 那是把崩溃换成卡死。');
    });
  });
}
