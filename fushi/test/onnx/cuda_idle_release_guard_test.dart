import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// vendored `flutter_onnxruntime` 的 CUDA 空闲释放（PATCHES.md delta #18，
/// BUG-5078）。
///
/// CUDA 主上下文由 cudart retain、进程不退就不还：用过一次 GPU 转录之后，本进程
/// 常驻约 180 MiB 显存 + 约 620 MiB 私有提交。插件在最后一个 CUDA 会话关闭、空闲
/// 一段时间后卸插件库并重置主上下文，下一个 CUDA 会话再装回来。
///
/// 这些全在 C++ 里，CI 上没有 GPU 跑不到；真机行为由
/// `integration_test/asr_cuda_vram_release_itest.dart` 量。丢掉任何一半都是
/// **静默的**——功能照常，只是内存又回不来——所以这里钉住结构：
///
/// - 关掉最后一个 CUDA 会话会排空闲释放，释放前复核「期间没建过 CUDA 会话」；
/// - 释放走 GPU 队列，且会重置主上下文（只卸库什么也回不来，实测）；
/// - CUDA EP 只在 GPU 队列的建会话任务里追加：在平台线程追加时，同队列的释放可能
///   插到中间把刚追加的设备释放掉；
/// - 库卸掉之后，下一次追加会先重新装载；
/// - 析构按显式顺序收尾（HBK-AUDIT-015）：先停延时任务（不再接活、join），再让
///   各工作队列停止接活并排空，最后才轮到成员析构。靠成员声明顺序做不到——
///   GPU 队列里在途的 CUDA 关会话任务会去碰定时器和 mutex，定时器又往 GPU 队列
///   投递，两者互相依赖。原生行为测试：
///   `third_party/flutter_onnxruntime/windows/test/async_dispatch_teardown_test.cc`。
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
      throw StateError('找不到 Fushi 仓库根目录');
    }
    current = parent;
  }
}

void main() {
  final Directory root = _findRepositoryRoot();
  final String vendored = '${root.path}/third_party/flutter_onnxruntime';
  final String pluginSrc = File(
    '$vendored/windows/flutter_onnxruntime_plugin.cpp',
  ).readAsStringSync();
  final String providerSrc = File(
    '$vendored/windows/src/cuda_provider.cc',
  ).readAsStringSync();

  test('关掉最后一个 CUDA 会话会排空闲释放', () {
    final String close = maskComments(
      methodBody(
        pluginSrc,
        'void FlutterOnnxruntimePlugin::HandleCloseSession(',
      ),
    );
    expect(close, contains('isCudaSession(session_id)'));
    expect(close, contains('openCudaSessions() == 0'));
    expect(close, contains('ArmCudaIdleRelease('));
  });

  test('空闲释放在 GPU 队列上复核代际后卸库并重置主上下文', () {
    final String fire = maskComments(
      methodBody(pluginSrc, 'void FireCudaIdleRelease()'),
    );
    expect(fire, contains('gpuQueue_.Post('));
    expect(fire, contains('cudaGeneration() != generation'));
    expect(
      fire,
      contains('releaseCudaPlugin(true,'),
      reason: '只卸插件库回收不了任何东西，必须连主上下文一起重置',
    );
    final String release = maskComments(
      methodBody(providerSrc, 'CudaReleaseResult CudaPluginRegistry::Release('),
    );
    expect(release, contains('UnregisterExecutionProviderLibrary('));
    expect(release, contains('ResetCudaPrimaryContexts()'));
    final String reset = maskComments(
      methodBody(providerSrc, 'std::string ResetCudaPrimaryContexts()'),
    );
    expect(reset, contains('"cuDevicePrimaryCtxReset_v2"'));
  });

  test('CUDA EP 只在 GPU 队列的建会话任务里追加', () {
    final String create = maskComments(
      methodBody(
        pluginSrc,
        'void FlutterOnnxruntimePlugin::HandleCreateSession(',
      ),
    );
    final int post = create.indexOf('queueFor(is_gpu).Post(');
    final int append = create.indexOf('appendCudaProvider(');
    expect(post, greaterThanOrEqualTo(0));
    expect(append, greaterThan(post), reason: 'CUDA EP 必须在投递的任务里追加');
    expect(
      'appendCudaProvider('.allMatches(create).length,
      1,
      reason: '平台线程上不能再有第二处追加',
    );
  });

  test('库被卸掉后，下一次追加先重新装载', () {
    final String append = maskComments(
      methodBody(
        providerSrc,
        'void CudaPluginRegistry::AppendToSessionOptions(',
      ),
    );
    final int reload = append.indexOf('LoadLocked(env)');
    expect(append, contains('if (!loaded_)'));
    expect(reload, greaterThanOrEqualTo(0));
    expect(
      reload,
      lessThan(append.indexOf('SessionOptionsAppendExecutionProvider_V2(')),
    );
  });

  test('析构先停延时任务，再让工作队列停止接活并排空', () {
    final String dtor = maskComments(
      methodBody(pluginSrc, '~FlutterOnnxruntimePluginImpl() {'),
    );
    final int timer = dtor.indexOf('cudaIdleRelease_.Shutdown();');
    expect(timer, greaterThanOrEqualTo(0), reason: '析构必须显式停掉空闲释放定时器');
    for (final String queue in <String>[
      '->Shutdown();',
      'cpuQueue_.Shutdown();',
      'gpuQueue_.Shutdown();',
    ]) {
      final int at = dtor.indexOf(queue);
      expect(at, greaterThan(timer), reason: '$queue 必须在定时器停下之后');
    }
    final String header = maskComments(
      File('$vendored/windows/src/async_dispatch.h').readAsStringSync(),
    );
    expect(
      header,
      contains('bool Schedule(std::chrono::milliseconds delay);'),
      reason: '停下之后的 Schedule 必须能被拒绝',
    );
    final String dispatch = maskComments(
      File('$vendored/windows/src/async_dispatch.cc').readAsStringSync(),
    );
    final String schedule = methodBody(dispatch, 'bool DelayedTask::Schedule(');
    expect(schedule, contains('if (stopping_) {'));
    expect(schedule, contains('return false;'));
  });

  test('Dart 侧从平台接口到 OnnxRuntime 都暴露 releaseCudaRuntime', () {
    expect(
      maskComments(
        File(
          '$vendored/lib/src/flutter_onnxruntime_platform_interface.dart',
        ).readAsStringSync(),
      ),
      contains('releaseCudaRuntime('),
    );
    expect(
      maskComments(
        File(
          '$vendored/lib/src/flutter_onnxruntime_method_channel.dart',
        ).readAsStringSync(),
      ),
      contains("'releaseCudaRuntime'"),
    );
    expect(
      maskComments(
        File('$vendored/lib/src/onnxruntime.dart').readAsStringSync(),
      ),
      contains('releaseCudaRuntime('),
    );
    expect(maskComments(pluginSrc), contains('"releaseCudaRuntime"'));
  });
}
