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
      expect(native, contains('#include <dml_provider_factory.h>'));
      expect(native, contains('provider == "DIRECT_ML"'));
      expect(native, contains('GetExecutionProviderApi('));
      expect(native, contains('SessionOptionsAppendExecutionProvider_DML('));
      expect(
        native,
        contains('SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL)'),
      );
      expect(native, contains('DisableMemPattern()'));
    });
  });
}
