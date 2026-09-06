/// OCR 侧的 `flutter_onnxruntime` 薄封装。
///
/// 真实现——EP 枚举映射、OnnxTensor <-> OrtValue 转换、provider 回退、资源释放
/// ——如今**唯一**住在 `lib/src/onnx/onnx_inference_ort.dart`（OCR / ASR 共用）。
/// 本文件只剩 OCR 特有的两样东西：`hibiki.ocr` 日志通道，以及 manga-ocr 下载源
/// 不同导出版本的输入名对齐（[resolveOcrSessionInputs]，经共享工厂的
/// `resolveInputs` 钩子注入）。`createOcrSessionWithProviderFallback` /
/// `isLocalOnnxRuntimeAvailable` 保留为转发入口，OCR 调用方与测试零改动。
///
/// 算法层不 import 本文件（依赖 `ocr_inference.dart` 的抽象）。
library;

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'package:fushi/src/ocr/ocr_inference.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart'
    hide isLocalOnnxRuntimeAvailable;
import 'package:fushi/src/onnx/onnx_inference_ort.dart' as onnx
    show isLocalOnnxRuntimeAvailable;

/// 本子系统统一的 `dart:developer` 日志通道名。
///
/// 用 `dart:developer` 而不是 `debugPrint`：整卷 OCR 跑在 `Isolate.spawn` 出来
/// 的后台 isolate 里，那里没有 Flutter binding，`debugPrint` 的节流实现依赖
/// binding 的 Timer 调度；`developer.log` 在任何 isolate 都可直接用。
const String kOcrLogName = 'hibiki.ocr';

/// 本平台是否内置 ONNX Runtime native 库（本地 OCR 推理是否可用）。
///
/// 真相源是共享层的同名 getter（`onnx_inference_ort.dart`，五端全真的理由与
/// 「保留具名闸门」的理由都写在那里）；这里只转发，让 `MangaOcrServiceImpl` 的
/// 闸门与既有测试继续从 OCR 层拿到它。
bool get isLocalOnnxRuntimeAvailable => onnx.isLocalOnnxRuntimeAvailable;

/// 用配置的加速 EP 创建会话；首选 EP 建不起来时退 CPU 重试一次。
///
/// 转发到共享的 [createOnnxSessionWithProviderFallback]（判据、异常语义、
/// `onResolved` 必回报一次——全部见那里的注释），只把日志通道钉成 [kOcrLogName]。
Future<T> createOcrSessionWithProviderFallback<T>({
  required List<OcrExecutionProvider> providers,
  required Future<T> Function(List<OcrExecutionProvider> providers) create,
  void Function(OcrProviderResolution resolution)? onResolved,
}) {
  return createOnnxSessionWithProviderFallback<T>(
    providers: providers,
    create: create,
    onResolved: onResolved,
    logName: kOcrLogName,
  );
}

/// 把算法层的语义输入名对齐到当前 ONNX 文件声明的真实输入名。
///
/// Manga OCR 下载源的检测器/编码器都只有一个输入，但不同导出版本分别使用过
/// `pixel_values`、`images` 等名字。单输入模型不存在位置歧义，因此以 session
/// 元数据为准；多输入 decoder 仍要求名称精确匹配，避免按顺序猜测而接错张量。
///
/// 单输入分支必须放在按名匹配**之前**：放在后面时，循环里任一未命中就已经
/// `return inputs` 退出，循环走完又保证 `resolved` 非空，元数据回退永远不可达
/// ——doc 宣称的鲁棒性并不存在（BUG-1173 同批审查发现）。
Map<String, OcrTensor> resolveOcrSessionInputs({
  required Map<String, OcrTensor> inputs,
  required List<String> sessionInputNames,
}) {
  if (inputs.length == 1 && sessionInputNames.length == 1) {
    return <String, OcrTensor>{
      sessionInputNames.single: inputs.values.single,
    };
  }
  final Map<String, OcrTensor> resolved = <String, OcrTensor>{};
  for (final String sessionName in sessionInputNames) {
    final OcrTensor? exact = inputs[sessionName];
    if (exact != null) {
      resolved[sessionName] = exact;
      continue;
    }
    if (sessionName == 'images' && inputs['pixel_values'] != null) {
      resolved[sessionName] = inputs['pixel_values']!;
      continue;
    }
    return inputs;
  }
  if (resolved.isNotEmpty) {
    return resolved;
  }
  return inputs;
}

/// [resolveOcrSessionInputs] 适配到共享工厂钩子的位置参数形态。
Map<String, OcrTensor> _resolveOcrInputs(
  Map<String, OcrTensor> inputs,
  List<String> sessionInputNames,
) {
  return resolveOcrSessionInputs(
    inputs: inputs,
    sessionInputNames: sessionInputNames,
  );
}

/// OCR 用的 flutter_onnxruntime 会话工厂：共享 [OrtOnnxSessionFactory] +
/// manga-ocr 输入名对齐钩子 + `hibiki.ocr` 日志通道。
///
/// `availableAcceleratedProviders()`（BUG-2050 的探测语义边界）与带
/// `onProviderResolved` 的 `createSession` 均由父类提供，注释见那里。
class OrtOcrSessionFactory extends OrtOnnxSessionFactory {
  OrtOcrSessionFactory({OnnxRuntime? runtime})
      : super(
          runtime: runtime,
          resolveInputs: _resolveOcrInputs,
          logName: kOcrLogName,
        );
}
