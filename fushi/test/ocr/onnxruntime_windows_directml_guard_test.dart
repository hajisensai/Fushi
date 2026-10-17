import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
  final String pluginRoot =
      '${root.path}/third_party/flutter_onnxruntime/windows';
  final String cmake = File('$pluginRoot/CMakeLists.txt').readAsStringSync();
  final String native = File(
    '$pluginRoot/flutter_onnxruntime_plugin.cpp',
  ).readAsStringSync();
  // DML 接线独占一个翻译单元：ORT 的 dml_provider_factory.h 与 Flutter 的
  // flutter_windows.h 各在**全局作用域**声明了一个叫 Default 的枚举量，同处一个
  // TU 必然 C2365（换 include 顺序只是换谁被判成重定义）。
  final String dmlUnit = File(
    '$pluginRoot/src/dml_provider.cc',
  ).readAsStringSync();
  final String loader = File(
    '$pluginRoot/src/ort_runtime_loader.cc',
  ).readAsStringSync();

  group('Windows ONNX Runtime DirectML 接线', () {
    test('随包只有最新 CPU core；DirectML core 不随包、只取构建期头文件', () {
      expect(
        cmake,
        contains(
          'https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/',
        ),
        reason: '随包的是与 CUDA 插件 EP 同一 revision 的 CPU core',
      );
      expect(cmake, contains('EXPECTED_HASH "SHA256='));
      expect(cmake, contains('onnxruntime_providers_shared.dll'));
      expect(
        cmake,
        contains('microsoft.ml.onnxruntime.directml'),
        reason:
            'dml_provider_factory.h 只在 DirectML 版 NuGet 里；nuget '
            'v3-flatcontainer 的路径段只接受全小写 package id',
      );
      expect(cmake, contains('dml_provider_factory.h'));
      final RegExpMatch? bundled = RegExp(
        r'set\(flutter_onnxruntime_bundled_libraries ([^)]*)\)',
      ).firstMatch(cmake);
      expect(bundled, isNotNull);
      expect(
        bundled!.group(1),
        isNot(contains('DIRECTML')),
        reason:
            'DirectML 环境（DML 版 core + DirectML.dll）由 app 按需下载，'
            '随包会和 CUDA 插件要求的 core 撞成两份 onnxruntime.dll',
      );
      expect(
        cmake,
        isNot(contains(r'onnxruntime-win-${ONNXRUNTIME_ARCH}')),
        reason: '不用 GitHub archive：版本与哈希统一钉在 NuGet',
      );
    });

    test('core 延迟加载，下载的 DirectML core 能在首次绑定前被选中', () {
      expect(
        cmake,
        contains('/DELAYLOAD:onnxruntime.dll'),
        reason:
            '静态导入会在插件 DLL 加载时就把随包 core 绑死，selectRuntime '
            '再也换不了',
      );
      expect(cmake, contains('delayimp'));
      expect(
        cmake,
        contains('-DORT_API_MANUAL_INIT'),
        reason: '否则 C++ API 的静态初始化器在 DLL 加载时就调 OrtGetApiBase',
      );
      expect(cmake, contains('src/ort_runtime_loader.cc'));
      expect(loader, contains('LoadLibraryExW('));
      expect(loader, contains('LOAD_WITH_ALTERED_SEARCH_PATH'));
      expect(loader, contains('__try'), reason: '延迟加载失败是结构化异常，不接住就是整个进程崩');
      expect(loader, contains('Ort::InitApi('));
      // 不绑定 ORT 的方法必须排在 EnsureRuntime 之前，否则探测显卡 / 选 core
      // 本身就把随包 core 绑死了。
      final int ensure = native.indexOf('impl_->EnsureRuntime()');
      expect(ensure, greaterThan(0));
      for (final String method in <String>[
        '"probeCuda"',
        '"getDeviceMemoryInfo"',
        '"selectRuntime"',
        '"getRuntimeInfo"',
      ]) {
        final int at = native.indexOf('method_name == $method');
        expect(at, greaterThan(0), reason: method);
        expect(at, lessThan(ensure), reason: '$method 不得绑定 ORT');
      }
    });

    test('DIRECT_ML provider 真正 append 到 session', () {
      expect(native, contains('provider == "DIRECT_ML"'));
      expect(native, contains('AppendDirectMLProvider(session_options'));
      expect(dmlUnit, contains('#include <dml_provider_factory.h>'));
      expect(dmlUnit, contains('GetExecutionProviderApi('));
      expect(dmlUnit, contains('SessionOptionsAppendExecutionProvider_DML('));
      expect(
        dmlUnit,
        contains('SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL)'),
      );
      expect(dmlUnit, contains('DisableMemPattern()'));
    });

    test('DML 翻译单元与 flutter 头互不相见（否则 C2365，Windows 直接编译不过）', () {
      expect(
        dmlUnit.contains('#include <flutter/'),
        isFalse,
        reason:
            'dml_provider.cc 里加一行 flutter 头就会把 flutter_windows.h 的'
            '全局 Default 拉进来，与 OrtDmlPerformancePreference::Default 撞成 C2365',
      );
      expect(
        native.contains('#include <dml_provider_factory.h>'),
        isFalse,
        reason: '反向同理：plugin.cpp 已经含 flutter 头，不得再把 DML 头拉回来',
      );
      expect(
        File(
          '$pluginRoot/CMakeLists.txt',
        ).readAsStringSync().contains('src/dml_provider.cc'),
        isTrue,
        reason: '新翻译单元必须进源码表，否则 AppendDirectMLProvider 链接不到',
      );
    });
  });
}
