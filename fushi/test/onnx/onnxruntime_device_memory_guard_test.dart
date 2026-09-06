import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// vendored `flutter_onnxruntime` 的 delta #10（`getDeviceMemoryInfo`：DXGI 显存
/// 预算）必须两半齐全。
///
/// 丢 Dart 半会编译错（`OrtOnnxSessionFactory.deviceMemoryBudgetBytes` 调不存在的
/// 方法），很响；丢 C++ 半是**静默的**：method channel 回 `MissingPluginException`
/// / `notImplemented`，Dart 侧按「预算未知」走默认桶表——在 8 GB 卡上就是融合图
/// 溢出到主机内存、RSS 暴涨到被系统杀掉，而没有任何别的测试会红。
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

  test('Windows 插件实现了 getDeviceMemoryInfo 并真去问 DXGI', () {
    final String plugin = maskComments(
      File('$vendored/windows/flutter_onnxruntime_plugin.cpp')
          .readAsStringSync(),
    );
    expect(plugin, contains('"getDeviceMemoryInfo"'));
    expect(plugin, contains('QueryDeviceMemoryInfo('));
    final String dxgi = maskComments(
      File('$vendored/windows/src/dxgi_memory.cc').readAsStringSync(),
    );
    expect(dxgi, contains('QueryVideoMemoryInfo('));
    expect(dxgi, contains('DXGI_MEMORY_SEGMENT_GROUP_LOCAL'));
    final String cmake =
        File('$vendored/windows/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('src/dxgi_memory.cc'));
    expect(
      cmake,
      matches(RegExp(r'target_link_libraries\([^)]*\bdxgi\b')),
      reason: '不链 dxgi.lib 就是链接错，重新 vendor 时最容易漏',
    );
  });

  test('Dart 侧从平台接口到 barrel 都暴露 getDeviceMemoryInfo', () {
    expect(
      maskComments(
        File('$vendored/lib/src/flutter_onnxruntime_platform_interface.dart')
            .readAsStringSync(),
      ),
      contains('getDeviceMemoryInfo('),
    );
    expect(
      maskComments(
        File('$vendored/lib/src/flutter_onnxruntime_method_channel.dart')
            .readAsStringSync(),
      ),
      contains("'getDeviceMemoryInfo'"),
    );
    expect(
      maskComments(
          File('$vendored/lib/src/onnxruntime.dart').readAsStringSync()),
      contains('class OrtDeviceMemoryInfo'),
    );
    expect(
      File('$vendored/lib/flutter_onnxruntime.dart').readAsStringSync(),
      contains('OrtDeviceMemoryInfo'),
      reason: 'barrel 不导出 = 应用侧编译错（响），但一起钉住成本为零',
    );
  });

  test('应用侧消费者真的用它选桶', () {
    final String ort = maskComments(
      File('${root.path}/fushi/lib/src/onnx/onnx_inference_ort.dart')
          .readAsStringSync(),
    );
    expect(ort, contains('getDeviceMemoryInfo('));
    final String engine = maskComments(
      File('${root.path}/fushi/lib/src/asr/asr_engine.dart').readAsStringSync(),
    );
    expect(engine, contains('deviceMemoryBudgetBytes('));
    expect(engine, contains('asrEncoderBucketsForBudget('));
  });

  test('PATCHES.md 记了 delta #10', () {
    final String md = File('$vendored/PATCHES.md').readAsStringSync();
    expect(md, contains('getDeviceMemoryInfo'));
    expect(md, contains('dxgi_memory'));
  });
}
