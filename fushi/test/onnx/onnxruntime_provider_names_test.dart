// 反馈 eEnV5gBn1K：Android（ORT 1.28.0 aar）的 `OrtEnvironment.getAvailableProviders()`
// 回报 Java 枚举名 `WEBGPU`，vendored flutter_onnxruntime 的 Dart 侧原先按自己的枚举
// 精确匹配、匹配不上就抛 `ArgumentError('Provider WEBGPU is not a valid OrtProvider.')`，
// 整次 EP 探测失败，转录面板把这句异常原文展示给用户。
//
// 这里走真实的 method channel 路径（mock 的是 native 回包，不是 OnnxRuntime），钉住：
// 各平台 native 侧实际会回报的名字都能解析；本 API 无法表示的 EP 不再拖垮整份列表。
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';
import 'package:fushi_asr_core/asr_core.dart' show OnnxExecutionProvider;

const MethodChannel _channel = MethodChannel('flutter_onnxruntime');

void _replyProviders(List<String> names) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (MethodCall call) async {
        if (call.method == 'getAvailableProviders') return names;
        throw MissingPluginException(call.method);
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('Android ORT 1.28.0 回报 WEBGPU：不抛错，映射成 WEB_GPU', () async {
    // 1.28.0 aar 里 Java `OrtProvider` 的真实枚举名（javap 核对过）。
    _replyProviders(const <String>['CPU', 'NNAPI', 'XNNPACK', 'WEBGPU']);

    expect(await OnnxRuntime().getAvailableProviders(), const <OrtProvider>[
      OrtProvider.CPU,
      OrtProvider.NNAPI,
      OrtProvider.XNNPACK,
      OrtProvider.WEB_GPU,
    ]);
  });

  test('Java 枚举里上游 Dart 枚举没有的名字都能解析', () async {
    _replyProviders(const <String>['VITIS_AI', 'RK_NPU', 'MI_GRAPH_X']);

    expect(await OnnxRuntime().getAvailableProviders(), const <OrtProvider>[
      OrtProvider.VITIS_AI,
      OrtProvider.RK_NPU,
      OrtProvider.MI_GRAPH_X,
    ]);
  });

  test('Windows / Linux 映射表的 MIGRAPHX 与透传的 ORT C 名都能解析', () async {
    _replyProviders(const <String>[
      'DIRECT_ML',
      'MIGRAPHX',
      'WebGpuExecutionProvider',
      'CPUExecutionProvider',
    ]);

    expect(await OnnxRuntime().getAvailableProviders(), const <OrtProvider>[
      OrtProvider.DIRECT_ML,
      OrtProvider.MI_GRAPH_X,
      OrtProvider.WEB_GPU,
      OrtProvider.CPU,
    ]);
  });

  test('本 API 无法表示的 EP 被排除，其余照常回报', () async {
    _replyProviders(const <String>[
      'SomeFutureExecutionProvider',
      'CUDA',
      'CPU',
    ]);

    expect(await OnnxRuntime().getAvailableProviders(), const <OrtProvider>[
      OrtProvider.CUDA,
      OrtProvider.CPU,
    ]);
  });

  test('Android 加速探测：WEBGPU 不再让探测抛错，本仓不选的 EP 落空集', () async {
    _replyProviders(const <String>['CPU', 'NNAPI', 'XNNPACK', 'WEBGPU']);

    final OrtOnnxSessionFactory factory = OrtOnnxSessionFactory();

    expect(await factory.availableAcceleratedProviders(), isEmpty);
  });

  test('Windows 加速探测：混杂未知名时 DirectML 仍被探测到', () async {
    _replyProviders(const <String>[
      'DIRECT_ML',
      'SomeFutureExecutionProvider',
      'CPU',
    ]);

    final OrtOnnxSessionFactory factory = OrtOnnxSessionFactory();

    expect(
      await factory.availableAcceleratedProviders(),
      const <OnnxExecutionProvider>{OnnxExecutionProvider.directml},
    );
  });
}
