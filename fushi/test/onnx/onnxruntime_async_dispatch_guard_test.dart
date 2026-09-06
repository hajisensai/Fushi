import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// vendored `flutter_onnxruntime` 的 delta #9（推理 / 建会话 / 关会话下放工作线程，
/// 回复经消息窗口回到平台线程）必须完整。
///
/// 丢掉它是**静默的性能与体验回退**：上游的同步实现照样能跑、结果逐字正确，
/// 只是每次 encoder `Run` 都卡住 UI 线程几百毫秒、静态桶建会话时卡几秒，且 GPU
/// 会话与 CPU 会话永远串行——有声书 ASR 的三级流水线（GPU 编码 ‖ CPU 搜索）
/// 收益归零。没有别的测试会因此变红。
Directory _findRepositoryRoot() {
  Directory current = Directory.current.absolute;
  while (true) {
    if (File(
      '${current.path}/third_party/flutter_onnxruntime/PATCHES.md',
    ).existsSync()) {
      return current;
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('找不到 Hibiki 仓库根目录');
    }
    current = parent;
  }
}

void main() {
  final Directory root = _findRepositoryRoot();
  final String vendored = '${root.path}/third_party/flutter_onnxruntime';

  test('工作线程与平台线程分发器的源文件在，且进了 CMake', () {
    expect(File('$vendored/windows/src/async_dispatch.h').existsSync(), isTrue);
    expect(
        File('$vendored/windows/src/async_dispatch.cc').existsSync(), isTrue);
    final String cmake =
        File('$vendored/windows/CMakeLists.txt').readAsStringSync();
    expect(
      cmake,
      contains('src/async_dispatch.cc'),
      reason: '不进 PLUGIN_SOURCES 就是链接错，但重新 vendor 时最容易漏的正是这行',
    );
  });

  test('三个重活都经 queueFor 下放工作线程，回复经 dispatcher 回平台线程', () {
    final String src = maskComments(
      File('$vendored/windows/flutter_onnxruntime_plugin.cpp')
          .readAsStringSync(),
    );
    for (final String handler in <String>[
      'HandleRunInference',
      'HandleCreateSession',
      'HandleCloseSession',
    ]) {
      final int at = src.indexOf('void FlutterOnnxruntimePlugin::$handler(');
      expect(at, greaterThan(0), reason: '$handler 不在了，守卫需更新');
      final int end = src.indexOf('\nvoid FlutterOnnxruntimePlugin::', at + 10);
      final String body = src.substring(at, end < 0 ? src.length : end);
      expect(
        body,
        contains('queueFor('),
        reason: '$handler 又回到平台线程同步执行：UI 会被推理卡住、GPU/CPU 会话'
            '无法重叠，且没有别的测试会红',
      );
      expect(
        body,
        contains('impl->reply('),
        reason: '$handler 的结果必须经 dispatcher 回平台线程完成',
      );
    }
    expect(src, contains('PlatformThreadDispatcher dispatcher_'));
    expect(src, contains('WorkQueue gpuQueue_'));
    expect(src, contains('WorkQueue cpuQueue_'));
  });

  test('SessionManager 的会话是 shared_ptr，Run 期间不持 map 锁', () {
    final String header = maskComments(
      File('$vendored/windows/src/session_manager.h').readAsStringSync(),
    );
    expect(
      header,
      contains('std::shared_ptr<Ort::Session> session;'),
      reason: '在飞的 run 要靠 shared_ptr 在 closeSession 之后活到跑完',
    );
    final String impl = maskComments(
      File('$vendored/windows/src/session_manager.cc').readAsStringSync(),
    );
    final int at = impl.indexOf('SessionManager::runInference(');
    expect(at, greaterThan(0));
    final int runAt = impl.indexOf('session->Run(', at);
    expect(runAt, greaterThan(at));
    final String beforeRun = impl.substring(at, runAt);
    expect(
      beforeRun,
      contains('session_ref = it->second.session;'),
      reason: 'runInference 必须只在查表时持锁，拿到 shared_ptr 后放锁再 Run',
    );
    // 锁的作用域必须在 Run 之前结束：lock_guard 所在的块要在 Run 之前闭合。
    final int lockAt =
        beforeRun.indexOf('std::lock_guard<std::mutex> lock(mutex_);');
    expect(lockAt, greaterThan(0));
    expect(
      beforeRun.substring(lockAt),
      contains('\n  }\n'),
      reason: 'lock_guard 必须在独立块内、Run 之前释放，否则 GPU/CPU 队列会互相串行',
    );
  });

  test('PATCHES.md 记了 delta #9', () {
    final String md = File('$vendored/PATCHES.md').readAsStringSync();
    expect(md, contains('async_dispatch'));
    expect(md, contains('PlatformThreadDispatcher'));
    expect(md, contains('FLUTTER_ONNXRUNTIME_SYNC'));
  });
}
