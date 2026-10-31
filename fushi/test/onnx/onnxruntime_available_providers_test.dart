import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';

/// `OnnxRuntime.getAvailableProviders` 经真实 method channel 解析 native 回报名。
///
/// Android ORT 1.28 回报 `WEBGPU`，旧实现遇到任何未知名就抛 ArgumentError，
/// 整个探测失败（反馈 eEnV5gBn1K：「GPU 探测失败：Provider WEBGPU is not a
/// valid OrtProvider」）。见 third_party/flutter_onnxruntime/PATCHES.md #15。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('flutter_onnxruntime');

  void replyProviders(List<String> names) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'getAvailableProviders') return names;
          return null;
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('unknown provider names are dropped, not fatal', () async {
    replyProviders(<String>['CPU', 'SOME_FUTURE_EP', 'XNNPACK', 'NNAPI']);

    final List<OrtProvider> providers = await OnnxRuntime()
        .getAvailableProviders();

    expect(providers, <OrtProvider>[
      OrtProvider.CPU,
      OrtProvider.XNNPACK,
      OrtProvider.NNAPI,
    ]);
  });

  test('WEB_GPU (mapped from Android WEBGPU) is recognised', () async {
    replyProviders(<String>['CPU', 'WEB_GPU']);

    expect(await OnnxRuntime().getAvailableProviders(), <OrtProvider>[
      OrtProvider.CPU,
      OrtProvider.WEB_GPU,
    ]);
  });

  test('the Android plugin maps Java WEBGPU to the Dart enum name', () {
    // 原生映射只能静态钉：Kotlin 侧没有可在 flutter test 里跑的单元。
    final String kotlin = _readKotlinPlugin();
    expect(kotlin, contains('"WEBGPU" -> "WEB_GPU"'));
  });
}

String _readKotlinPlugin() {
  const String path =
      '../third_party/flutter_onnxruntime/android/src/main/kotlin/com/masicai/'
      'flutteronnxruntime/FlutterOnnxruntimePlugin.kt';
  return File(path).readAsStringSync();
}
