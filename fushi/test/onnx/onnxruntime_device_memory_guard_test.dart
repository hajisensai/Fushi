import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 解析 `fushi_asr_core` 包里的一个文件。
///
/// 走 `.dart_tool/package_config.json` 而不是拼相对路径：这个包既可能是 git 依赖
/// （落在 pub cache 里，目录名带 sha）也可能被 `dependency_overrides` 换成本地
/// path，两种装法的磁盘位置完全不同，只有 package_config 知道真值。
File _asrCoreFile(String relative) {
  Directory current = Directory.current.absolute;
  File? config;
  while (true) {
    final File candidate = File(
      '${current.path}/.dart_tool/package_config.json',
    );
    if (candidate.existsSync()) {
      config = candidate;
      break;
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  if (config == null) {
    throw StateError('找不到 .dart_tool/package_config.json —— 先跑 pub get');
  }
  final Map<String, Object?> json =
      jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
  for (final Object? entry in json['packages']! as List<Object?>) {
    final Map<String, Object?> pkg = entry! as Map<String, Object?>;
    if (pkg['name'] != 'fushi_asr_core') continue;
    final Uri root = config.parent.uri.resolve('${pkg["rootUri"]}/');
    return File.fromUri(root.resolve(relative));
  }
  throw StateError('package_config.json 里没有 fushi_asr_core');
}

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
      throw StateError('找不到 Fushi 仓库根目录');
    }
    current = parent;
  }
}

void main() {
  final Directory root = _findRepositoryRoot();
  final String vendored = '${root.path}/third_party/flutter_onnxruntime';

  test('Windows 插件实现了 getDeviceMemoryInfo 并真去问 DXGI', () {
    final String plugin = maskComments(
      File(
        '$vendored/windows/flutter_onnxruntime_plugin.cpp',
      ).readAsStringSync(),
    );
    expect(plugin, contains('"getDeviceMemoryInfo"'));
    expect(plugin, contains('QueryDeviceMemoryInfo('));
    final String dxgi = maskComments(
      File('$vendored/windows/src/dxgi_memory.cc').readAsStringSync(),
    );
    expect(dxgi, contains('QueryVideoMemoryInfo('));
    expect(dxgi, contains('DXGI_MEMORY_SEGMENT_GROUP_LOCAL'));
    final String cmake = File(
      '$vendored/windows/CMakeLists.txt',
    ).readAsStringSync();
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
        File(
          '$vendored/lib/src/flutter_onnxruntime_platform_interface.dart',
        ).readAsStringSync(),
      ),
      contains('getDeviceMemoryInfo('),
    );
    expect(
      maskComments(
        File(
          '$vendored/lib/src/flutter_onnxruntime_method_channel.dart',
        ).readAsStringSync(),
      ),
      contains("'getDeviceMemoryInfo'"),
    );
    expect(
      maskComments(
        File('$vendored/lib/src/onnxruntime.dart').readAsStringSync(),
      ),
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
      File(
        '${root.path}/fushi/lib/src/onnx/onnx_inference_ort.dart',
      ).readAsStringSync(),
    );
    expect(ort, contains('getDeviceMemoryInfo('));
    // 消费方（按显存预算选静态桶）已经随 ASR 算法层搬进了 `fushi_asr_core` 包。
    //
    // **不能因为文件不在本仓就把这条断言删掉**：显存不够时 ORT 不报错，是把桶
    // 溢出到主机内存后吞吐崩塌——「变慢了但没坏」，没有守卫就没人会发现这条链路
    // 断了。所以改成经 `package_config.json` 解析到包的真实位置再扫，git 依赖
    // 与本地 path override 两种装法都能找到。
    final File engineFile = _asrCoreFile('lib/src/asr/asr_engine.dart');
    expect(
      engineFile.existsSync(),
      isTrue,
      reason: '找不到 fushi_asr_core 的 asr_engine.dart：${engineFile.path}',
    );
    final String engine = maskComments(engineFile.readAsStringSync());
    expect(engine, contains('deviceMemoryBudgetBytes('));
    expect(engine, contains('asrEncoderBucketsForBudget('));
  });

  // Issue #3380 的后续：混合显卡笔记本上 DXGI 适配器 0 通常是核显，它的「预算」
  // 其实是一部分系统内存。CUDA 会话跑在 N 卡上，拿核显的数去算一批几行、要不要
  // 上 fp32，N 卡照样溢出——同样是「变慢 / 卡死但不报错」，所以钉住。
  test('不给 deviceId 时，CUDA 已注册就回答 N 卡那块适配器', () {
    final String plugin = maskComments(
      File(
        '$vendored/windows/flutter_onnxruntime_plugin.cpp',
      ).readAsStringSync(),
    );
    final String handler = plugin.substring(
      plugin.indexOf('::HandleGetDeviceMemoryInfo('),
      plugin.indexOf('::HandleGetAvailableProviders('),
    );
    expect(handler, contains('has_device_id'));
    expect(handler, contains('isCudaRegistered()'));
    expect(handler, contains('CudaDeviceLuid('));
    expect(handler, contains('QueryDeviceMemoryInfoByLuid('));
    expect(handler, contains('QueryDeviceMemoryInfoByVendor('));
    expect(
      handler.indexOf('CudaDeviceLuid('),
      lessThan(handler.indexOf('QueryDeviceMemoryInfoByVendor(')),
      reason: '先按 LUID 精确对上 CUDA 设备，对不上才退到「第一块 N 卡」',
    );
    expect(handler, contains('"selection"'));

    final String dxgi = maskComments(
      File('$vendored/windows/src/dxgi_memory.cc').readAsStringSync(),
    );
    expect(dxgi, contains('AdapterLuid'));
    expect(dxgi, contains('VendorId'));
    final String cuda = maskComments(
      File('$vendored/windows/src/cuda_provider.cc').readAsStringSync(),
    );
    expect(cuda, contains('"cuDeviceGetLuid"'));
    // 平台线程上问「注册了没」不能等注册那把锁：注册要装载约 1 GB 的 DLL。
    expect(
      cuda,
      contains(
        'bool CudaPluginRegistry::IsRegistered() { return registered_.load(); }',
      ),
    );
  });

  test('Dart 侧不给 deviceId 就不发这个键（原生侧靠「缺席」区分显式 0）', () {
    final String channel = maskComments(
      File(
        '$vendored/lib/src/flutter_onnxruntime_method_channel.dart',
      ).readAsStringSync(),
    );
    expect(channel, contains('getDeviceMemoryInfo({int? deviceId})'));
    expect(channel, contains("if (deviceId != null) 'deviceId': deviceId"));
    expect(
      maskComments(
        File('$vendored/lib/src/onnxruntime.dart').readAsStringSync(),
      ),
      contains('getDeviceMemoryInfo({int? deviceId})'),
    );
    // 应用侧的预算查询不能显式点名适配器 0。
    final String ort = maskComments(
      File(
        '${root.path}/fushi/lib/src/onnx/onnx_inference_ort.dart',
      ).readAsStringSync(),
    );
    expect(ort, contains('_runtime.getDeviceMemoryInfo()'));
  });

  test('PATCHES.md 记了 delta #10 与 #16', () {
    final String md = File('$vendored/PATCHES.md').readAsStringSync();
    expect(md, contains('getDeviceMemoryInfo'));
    expect(md, contains('dxgi_memory'));
    expect(md, contains('cuDeviceGetLuid'));
  });
}
