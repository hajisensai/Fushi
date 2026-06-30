// TODO-935 BUG（桌面数据迁移自动重启失效）守卫。
//
// 症状：桌面「更换数据存储位置」选新目录 → 弹一下迁移进度 → app 自动重启 → 但位置没变。
//
// 根因：数据迁移成功后 DesktopLifecycleService.restartApp 以 detached 模式拉起带
// restartMarkerArg 的新进程，随后旧进程才走 prepareForProcessExit + exit(0)。在「拉起
// 新进程」与「旧进程真正退出」之间，旧进程仍持有 windows/runner/main.cpp 的命名单实例
// 互斥量 `HibikiSingleInstanceMutex`。新进程裸调 CreateMutexW 拿到 ERROR_ALREADY_EXISTS，
// 被误判为「用户二次启动」→ 前置旧窗口 + return EXIT_SUCCESS，从不启动 Flutter 引擎。
// 于是重启落空：数据已迁到新根、data_root pref 已写，但 app 从未以新 data_root 重新
// AppPaths.resolve()。这与 TODO-960 记录的「locale 切换重启撞单实例互斥量把 app 关掉」
// 同源。
//
// 根因修复（native runner）：带 restartMarkerArg 的新进程检测到已有实例时，不再直接退出，
// 而是 WaitForSingleObject 等旧进程释放互斥量（旧进程 exit(0) 后句柄关闭），取得所有权后
// 按首实例正常启动。普通二次点击图标无此标志，单实例行为不变。
//
// 无法在 flutter test 里跑真 Windows runner，这里用源码守卫钉住 native 保护与 Dart/native
// 重启标志常量一致——任何把保护改回「带标志也直接退出」或改动标志字面量的回归都会变红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/platform/desktop/desktop_lifecycle_service.dart';

void main() {
  String readSource(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: 'missing source file: $rel');
    return f.readAsStringSync();
  }

  group('TODO-935 数据迁移重启撞单实例互斥量守卫', () {
    test('Dart 重启标志常量稳定（与 native runner 逐字符匹配）', () {
      // native runner 的 kRestartMarkerArg 必须与本常量逐字符一致，否则等待逻辑
      // 永远不触发，重启又会被单实例守卫吞掉。
      expect(DesktopLifecycleService.restartMarkerArg, '--hibiki-restarted');
    });

    test('native runner：带重启标志检测到已有实例时等待互斥量、不直接退出', () {
      final String src = readSource('windows/runner/main.cpp');

      // native 侧重启标志常量字面量必须与 Dart 侧一致。
      expect(
        src.contains('constexpr wchar_t kRestartMarkerArg[] = '
            'L"--hibiki-restarted";'),
        isTrue,
        reason: 'native runner must define the restart marker matching '
            'DesktopLifecycleService.restartMarkerArg',
      );

      // 必须有「检测到已有实例 + 带重启标志 → 等待互斥量」的保护，并在取得所有权后
      // 把 another_instance 置回 false 继续启动（而不是直接前置旧窗口退出）。
      expect(src.contains('HasRestartMarker()'), isTrue,
          reason: 'runner must detect the restart marker in argv');
      expect(src.contains('WaitForSingleInstanceMutex('), isTrue,
          reason: 'runner must wait for the old instance to release the mutex '
              'instead of bailing out on a restart');
      expect(
        src.contains('if (another_instance && HasRestartMarker())'),
        isTrue,
        reason: 'the restart-marker wait must guard the single-instance bail '
            'so an automatic restart can take over instead of exiting',
      );

      // 等待逻辑接受 WAIT_OBJECT_0 / WAIT_ABANDONED（旧进程释放或未释放就退出都算
      // 「旧实例已走、本进程接管」），并加超时上界避免永久卡死。
      expect(src.contains('WAIT_ABANDONED'), isTrue,
          reason: 'an abandoned mutex (old process exited without release) '
              'must also count as taking over single-instance ownership');
      expect(src.contains('WaitForSingleInstanceMutex(single_instance_mutex'),
          isTrue,
          reason: 'the wait must be bounded so a stuck old process cannot hang '
              'the restart forever');
    });

    test('restartApp 仍透传重启标志给新进程（等待逻辑的触发前提）', () {
      final String src =
          readSource('lib/src/platform/desktop/desktop_lifecycle_service.dart');
      final int start = src.indexOf('Future<void> restartApp(');
      expect(start, isNonNegative, reason: 'restartApp must exist');
      final int end = src.indexOf('\n  }', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);
      // 新进程 argv 第一个就是 restartMarkerArg，runner 才能识别这是自动重启。
      expect(body.contains('restartMarkerArg'), isTrue,
          reason: 'the spawned process must carry the restart marker so the '
              'native runner waits instead of treating it as a 2nd instance');
      expect(body.contains('ProcessStartMode.detached'), isTrue);
    });
  });
}
