/// Apple 端本地 OCR **原生栈**冒烟：证明 `flutter_onnxruntime` 的 MethodChannel
/// 在 iOS / macOS 上真有 native 实现，且能真的建会话、真的跑推理。
///
/// 为什么需要这条：2026-08-14 之前 vendored fork 把 `ios`/`macos` 从
/// `flutter.plugin.platforms` 删掉，Apple 上任何本地 OCR 会话构造都抛
/// `MissingPluginException`，而**这在纯 Dart 单测里完全看不见**——单测全程注 fake
/// runner，永远不碰 MethodChannel。所以那次回归只能靠真机/真 app 层捕获。
///
/// 模型是本文件现搓的最小 ONNX（一个 `Add` 节点），不下载、不读 fixture：
/// 整条链路（插件注册 → 原生 ORT 建会话 → 张量进出 → 推理结果）在几毫秒内闭环，
/// 可以无条件进 CI，不会因为 HuggingFace 抖动变成 flaky。
///
/// 跑法：
///   flutter test integration_test/manga_ocr_apple_native_itest.dart -d macos
///   flutter test integration_test/manga_ocr_apple_native_itest.dart -d <iPhone>
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/ocr/ocr_inference.dart';
import 'package:fushi/src/ocr/ocr_inference_ort.dart';

// ---------------------------------------------------------------------------
// 最小 protobuf 编码器（只够拼一个 ONNX ModelProto）
// ---------------------------------------------------------------------------

/// protobuf varint。
List<int> _varint(int value) {
  final List<int> out = <int>[];
  int v = value;
  do {
    int byte = v & 0x7f;
    v >>= 7;
    if (v != 0) byte |= 0x80;
    out.add(byte);
  } while (v != 0);
  return out;
}

/// 变长字段（wire type 0）。
List<int> _pbVarintField(int field, int value) =>
    <int>[..._tag(field, 0), ..._varint(value)];

/// 长度前缀字段（wire type 2）：嵌套 message / string / bytes 共用。
List<int> _pbLenField(int field, List<int> payload) =>
    <int>[..._tag(field, 2), ..._varint(payload.length), ...payload];

List<int> _tag(int field, int wireType) => _varint((field << 3) | wireType);

List<int> _utf8(String s) => s.codeUnits;

// ---------------------------------------------------------------------------
// 最小 ONNX 模型：out = a + b，两个 float[2] 输入
// ---------------------------------------------------------------------------

/// `TypeProto` 的**载荷**（不含外层 tag）：tensor(float)[dim]。
/// 调用方负责按所在 message 的字段号包一层（ValueInfoProto.type 是字段 2）。
List<int> _floatTensorTypePayload(int dim) {
  // TensorShapeProto.Dimension { dim_value = dim }
  final List<int> dimension = _pbVarintField(1, dim);
  // TensorShapeProto { dim = [...] }
  final List<int> shape = _pbLenField(1, dimension);
  // TypeProto.Tensor { elem_type = 1 (FLOAT), shape = ... }
  final List<int> tensor = <int>[
    ..._pbVarintField(1, 1),
    ..._pbLenField(2, shape),
  ];
  // TypeProto { tensor_type = ... }  —— tensor_type 是 TypeProto 的字段 1
  return _pbLenField(1, tensor);
}

/// `ValueInfoProto { name = 1, type = 2 }`。
List<int> _valueInfo(String name, int dim) => <int>[
      ..._pbLenField(1, _utf8(name)),
      ..._pbLenField(2, _floatTensorTypePayload(dim)),
    ];

/// 拼一个只含 `Add` 的合法 ONNX ModelProto。
Uint8List _buildAddModel({int dim = 2}) {
  // NodeProto { input: a, input: b, output: c, name, op_type }
  final List<int> node = <int>[
    ..._pbLenField(1, _utf8('a')),
    ..._pbLenField(1, _utf8('b')),
    ..._pbLenField(2, _utf8('c')),
    ..._pbLenField(3, _utf8('add0')),
    ..._pbLenField(4, _utf8('Add')),
  ];

  // GraphProto { node, name, input x2, output }
  final List<int> graph = <int>[
    ..._pbLenField(1, node),
    ..._pbLenField(2, _utf8('fushi_apple_ort_smoke')),
    ..._pbLenField(11, _valueInfo('a', dim)),
    ..._pbLenField(11, _valueInfo('b', dim)),
    ..._pbLenField(12, _valueInfo('c', dim)),
  ];

  // OperatorSetIdProto { domain: "", version: 13 }
  final List<int> opset = _pbVarintField(2, 13);

  // ModelProto { ir_version, producer_name, graph, opset_import }
  final List<int> model = <int>[
    ..._pbVarintField(1, 8), // IR version 8
    ..._pbLenField(2, _utf8('fushi-itest')),
    ..._pbLenField(7, graph),
    ..._pbLenField(8, opset),
  ];
  return Uint8List.fromList(model);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String modelPath;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('fushi_ort_smoke_');
    modelPath = p.join(tempDir.path, 'add.onnx');
    await File(modelPath).writeAsBytes(_buildAddModel());
  });

  tearDownAll(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ORT native 在本平台真实可用', () {
    test('闸门开着（isLocalOnnxRuntimeAvailable）', () {
      expect(isLocalOnnxRuntimeAvailable, isTrue,
          reason: '${Platform.operatingSystem} 上本地 OCR 闸门应为真');
    });

    test('MethodChannel 有 native 实现（getPlatformVersion 不抛 MissingPlugin）',
        () async {
      // 这一条就是旧回归的直接探针：fork gate 掉 Apple 时，这里抛
      // MissingPluginException。
      final String? version = await OnnxRuntime().getPlatformVersion();
      expect(version, isNotNull);
      expect(version, isNotEmpty);
      if (Platform.isIOS) {
        expect(version, startsWith('iOS'));
      } else if (Platform.isMacOS) {
        expect(version, startsWith('macOS'));
      }
    });

    test('EP 枚举可用，且 Apple 上报告 CoreML', () async {
      final List<OrtProvider> providers =
          await OnnxRuntime().getAvailableProviders();
      expect(providers, contains(OrtProvider.CPU),
          reason: 'CPU EP 在任何平台都必须在场——**生产的检测与识别都走它**'
              '（Apple 分支的 CoreML 已按 BUG-1613 撤掉）');
      if (Platform.isIOS || Platform.isMacOS) {
        expect(providers, contains(OrtProvider.CORE_ML),
            reason: 'Apple 构建里 CoreML EP 应当被编进 ORT。它当前**不参与生产'
                '选路**（BUG-1613：iOS 上对 int8 检测模型静默返回空结果），但仍是'
                '重新评估时的入口——枚举里消失说明 ORT 构建变了，值得知道');
      }
    });

    test('真建会话 + 真跑推理：out = a + b', () async {
      final OrtOcrSessionFactory factory = OrtOcrSessionFactory();
      OcrProviderResolution? resolution;
      final OcrSession session = await factory.createSession(
        modelPath,
        providers: const <OcrExecutionProvider>[OcrExecutionProvider.cpu],
        onProviderResolved: (OcrProviderResolution r) => resolution = r,
      );
      addTearDown(session.close);

      final Map<String, OcrTensor> outputs = await session.run(
        <String, OcrTensor>{
          'a': OcrTensor.float32(
              Float32List.fromList(<double>[1.5, 2.5]), <int>[2]),
          'b': OcrTensor.float32(
              Float32List.fromList(<double>[10.0, 20.0]), <int>[2]),
        },
      );

      expect(outputs, hasLength(1));
      final OcrTensor out = outputs.values.single;
      expect(out.shape, <int>[2]);
      expect(out.floatData, isNotNull);
      expect(out.floatData![0], closeTo(11.5, 1e-5));
      expect(out.floatData![1], closeTo(22.5, 1e-5));

      // BUG-1163 的不变式：降级回调必定被调用一次并回报真实生效的 EP。
      expect(resolution, isNotNull);
      expect(resolution!.effective, OcrExecutionProvider.cpu);
      expect(resolution!.didFallBack, isFalse);
    });

    test('Apple 上 CoreML EP 建会话也能跑（非生产路径，但保持可用）', () async {
      if (!Platform.isIOS && !Platform.isMacOS) {
        return; // 非 Apple 由上面的 CPU 用例覆盖。
      }
      // 生产选路已不含 CoreML（BUG-1613）。这条留着是为了让「CoreML 通路本身
      // 是通的」与「CoreML 对量化检测模型算错」两件事分开——将来换非量化检测
      // 模型重新评估 CoreML 时，先看这条是不是还绿。
      final OrtOcrSessionFactory factory = OrtOcrSessionFactory();
      final OcrSession session = await factory.createSession(
        modelPath,
        providers: const <OcrExecutionProvider>[
          OcrExecutionProvider.coreml,
          OcrExecutionProvider.cpu,
        ],
      );
      addTearDown(session.close);

      final Map<String, OcrTensor> outputs = await session.run(
        <String, OcrTensor>{
          'a': OcrTensor.float32(
              Float32List.fromList(<double>[3.0, 4.0]), <int>[2]),
          'b': OcrTensor.float32(
              Float32List.fromList(<double>[0.5, 0.25]), <int>[2]),
        },
      );
      final OcrTensor out = outputs.values.single;
      expect(out.floatData![0], closeTo(3.5, 1e-5));
      expect(out.floatData![1], closeTo(4.25, 1e-5));
    });
  });
}
