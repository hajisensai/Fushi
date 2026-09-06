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

  test('delta #11：每个 CPU 会话各一条工作线程（Run / Close 按会话取队列，关会话后回收）', () {
    // 丢掉它同样是静默回退：所有 CPU 会话又挤回一条 FIFO，两个贪心 Loop 图会话
    // 只能串行，ASR 搜索并行度归一，结果照旧正确、没有别的测试会红。
    final String src = maskComments(
      File('$vendored/windows/flutter_onnxruntime_plugin.cpp')
          .readAsStringSync(),
    );
    expect(
      src,
      contains(
          'std::map<std::string, std::unique_ptr<WorkQueue>> cpuSessionQueues_'),
    );
    expect(
        src, contains('queueFor(bool is_gpu, const std::string &session_id)'));
    for (final String handler in <String>[
      'HandleRunInference',
      'HandleCloseSession',
    ]) {
      final int at = src.indexOf('void FlutterOnnxruntimePlugin::$handler(');
      expect(at, greaterThan(0), reason: '$handler 不在了，守卫需更新');
      final int end = src.indexOf('\nvoid FlutterOnnxruntimePlugin::', at + 10);
      final String body = src.substring(at, end < 0 ? src.length : end);
      expect(
        body,
        contains('queueFor(is_gpu, session_id)'),
        reason: '$handler 必须按会话取队列，否则 CPU 会话又全挤在 cpuQueue_ 上串行',
      );
    }
    final int closeAt =
        src.indexOf('void FlutterOnnxruntimePlugin::HandleCloseSession(');
    final String closeBody = src.substring(closeAt);
    expect(
      closeBody,
      contains('impl->dropSessionQueue(session_id)'),
      reason: '关会话后必须回收它的工作线程，否则每开关一个 CPU 会话漏一条线程',
    );
    expect(
      closeBody.indexOf('impl->dispatcher_.Post('),
      greaterThan(closeBody.indexOf('impl->reply(shared_result, outcome)')),
      reason: '回收必须在回复之后、经 dispatcher 回到平台线程做（队列表只在平台线程碰）',
    );
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

  test('WorkQueue 的 thread_ 必须是最后一个成员（否则线程跑在成员构造之前）', () {
    // 成员按声明顺序初始化，而构造函数在初始化 thread_ 的同时就启动了线程，
    // 新线程进 Run() 立刻 lock(mutex_) / cv_.wait / 读 stopping_。thread_ 声明在
    // 前面时，这三者可能都还没构造完 —— UB，且失败形态是静默的：stopping_ 读到
    // 非零垃圾就让 Run() 立刻返回，之后每次 Post 都判队列已停机、任务被丢，
    // 每个 ORT 调用的 Dart Future 永不完成，转录直接挂死且无异常无日志。
    final String header = maskComments(
      File('$vendored/windows/src/async_dispatch.h').readAsStringSync(),
    );
    final int classAt = header.indexOf('class WorkQueue {');
    expect(classAt, greaterThan(0), reason: 'WorkQueue 改名了，守卫需更新');
    final int end = header.indexOf('\n};', classAt);
    expect(end, greaterThan(classAt));
    final String body = header.substring(classAt, end);
    final int threadAt = body.indexOf('std::thread thread_;');
    expect(threadAt, greaterThan(0), reason: '找不到 thread_ 成员');
    for (final String member in <String>[
      'std::mutex mutex_;',
      'std::condition_variable cv_;',
      'std::deque<std::function<void()>> tasks_;',
      'bool stopping_',
    ]) {
      final int at = body.indexOf(member);
      expect(at, greaterThan(0), reason: '找不到成员 `$member`，守卫需更新');
      expect(
        at,
        lessThan(threadAt),
        reason: '`$member` 必须声明在 thread_ **之前**：构造函数一初始化 thread_ '
            '线程就跑起来了，它会立刻用到这个成员',
      );
    }
  });

  test('tensor id 分配必须线程安全（两条 worker 并发调它）', () {
    // generateTensorId 是 TensorManager 里唯一不持锁的方法——**故意**的，因为 13 个
    // 内部调用点调它时已经持着 mutex_（非递归锁不能再上）。插件线程化之前全进程
    // 只有平台线程会碰它；现在 GPU / CPU 两条 worker 按设计并发调用。
    // 用无同步的函数局部 static RNG，两线程读到同一游标就发出**相同**的 id：
    // storeTensor 互相覆盖，或 releaseTensor 释放掉对方的 backing buffer。
    final String impl = maskComments(
      File('$vendored/windows/src/tensor_manager.cc').readAsStringSync(),
    );
    final int at = impl.indexOf('TensorManager::generateTensorId()');
    expect(at, greaterThan(0), reason: 'generateTensorId 改名了，守卫需更新');
    final int end = impl.indexOf('\n}', at);
    expect(end, greaterThan(at));
    final String body = impl.substring(at, end);
    expect(
      body.contains('static std::mt19937'),
      isFalse,
      reason: '函数局部 static RNG 在两条 worker 并发下会发出重复 id',
    );
    expect(
      body.contains('fetch_add'),
      isTrue,
      reason: 'id 分配必须是原子的（与 SessionManager::generateSessionId 同形）',
    );
    expect(
      maskComments(
        File('$vendored/windows/src/tensor_manager.h').readAsStringSync(),
      ),
      contains('std::atomic<uint64_t> next_tensor_id_'),
      reason: '计数器本身必须是 atomic；普通 uint64_t 的自增在两线程下同样会撞',
    );
  });

  test('PATCHES.md 记了 delta #9', () {
    final String md = File('$vendored/PATCHES.md').readAsStringSync();
    expect(md, contains('async_dispatch'));
    expect(md, contains('PlatformThreadDispatcher'));
    expect(md, contains('FLUTTER_ONNXRUNTIME_SYNC'));
  });
}
