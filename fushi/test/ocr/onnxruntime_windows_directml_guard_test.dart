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
      throw StateError('找不到 Hibiki 仓库根目录');
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
  final String dmlUnit = File('$pluginRoot/src/dml_provider.cc').readAsStringSync();

  group('Windows ONNX Runtime DirectML 接线', () {
    test('构建使用官方 DirectML Runtime 并随包带齐依赖 DLL', () {
      expect(
        cmake,
        contains('microsoft.ml.onnxruntime.directml'),
        reason: 'CPU-only 的普通 Windows ORT 包不包含 DmlExecutionProvider',
      );
      expect(cmake, contains('EXPECTED_HASH "SHA256='));
      expect(cmake, contains('onnxruntime_providers_shared.dll'));
      expect(
        cmake,
        contains('microsoft.ai.directml'),
        reason: 'DirectML 重分发包与 ORT 包分开下载；这里必须是 nuget v3-flatcontainer '
            '的**全小写** package id——该端点的路径段只接受小写，写成展示用的 '
            'Microsoft.AI.DirectML 会让构建期下载 404',
      );
      expect(cmake, contains('DirectML.dll'));
      expect(
        cmake,
        isNot(contains(r'onnxruntime-win-${ONNXRUNTIME_ARCH}')),
        reason: '不得退回不含 DirectML EP 的普通 GitHub Windows archive',
      );
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
        reason: 'dml_provider.cc 里加一行 flutter 头就会把 flutter_windows.h 的'
            '全局 Default 拉进来，与 OrtDmlPerformancePreference::Default 撞成 C2365',
      );
      expect(
        native.contains('#include <dml_provider_factory.h>'),
        isFalse,
        reason: '反向同理：plugin.cpp 已经含 flutter 头，不得再把 DML 头拉回来',
      );
      expect(
        File('$pluginRoot/CMakeLists.txt')
            .readAsStringSync()
            .contains('src/dml_provider.cc'),
        isTrue,
        reason: '新翻译单元必须进源码表，否则 AppendDirectMLProvider 链接不到',
      );
    });
  });
}
