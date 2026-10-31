// Copyright (c) MASIC AI
// All rights reserved.
//
// This source code is licensed under the license found in the
// LICENSE file in the root directory of this source tree.

// ignore_for_file: constant_identifier_names

/// The execution provider to use for the ONNX Runtime session
///
/// Following the name of the execution provider in the ONNX Runtime Java API at:
/// https://onnxruntime.ai/docs/api/java/ai/onnxruntime/OrtProvider.html
enum OrtProvider {
  ACL,
  ARM_NN,
  AZURE,
  CORE_ML,
  CPU,
  CUDA,
  DIRECT_ML,
  DNNL,
  // Fushi fork: Java `OrtProvider` names upstream 1.8.3 did not model.
  MI_GRAPH_X,
  NNAPI,
  OPEN_VINO,
  QNN,
  // Fushi fork.
  RK_NPU,
  ROCM,
  TENSOR_RT,
  // Fushi fork.
  VITIS_AI,
  XNNPACK,
  WEB_ASSEMBLY,
  WEB_GL,
  WEB_GPU,
  WEB_NN,
}

/// Fushi fork: every spelling a native side is known to report for an EP that
/// is not already the exact [OrtProvider] name.
///
/// The native plugins do not share one vocabulary:
/// - Android passes the Java `OrtProvider` enum name through, and the Java enum
///   is not the Dart one: the ORT 1.28.0 aar reports `WEBGPU` (checked with
///   `javap` on `ai/onnxruntime/OrtProvider.class`), which upstream's strict
///   parser rejected, failing the whole probe (feedback eEnV5gBn1K);
/// - Windows / Linux map ORT C names through their own tables, spell MIGraphX
///   `MIGRAPHX`, and pass anything unmapped through as the raw
///   `XxxExecutionProvider` C name.
const Map<String, OrtProvider> _nativeProviderAliases = <String, OrtProvider>{
  // Java enum names (ORT 1.28.0) that differ from the Dart names.
  'WEBGPU': OrtProvider.WEB_GPU,
  // Windows / Linux native tables.
  'MIGRAPHX': OrtProvider.MI_GRAPH_X,
  // ORT C provider names (what `Ort::GetAvailableProviders()` returns).
  'ACLExecutionProvider': OrtProvider.ACL,
  'ArmNNExecutionProvider': OrtProvider.ARM_NN,
  'AzureExecutionProvider': OrtProvider.AZURE,
  'CoreMLExecutionProvider': OrtProvider.CORE_ML,
  'CPUExecutionProvider': OrtProvider.CPU,
  'CUDAExecutionProvider': OrtProvider.CUDA,
  'DmlExecutionProvider': OrtProvider.DIRECT_ML,
  'DnnlExecutionProvider': OrtProvider.DNNL,
  'MIGraphXExecutionProvider': OrtProvider.MI_GRAPH_X,
  'NnapiExecutionProvider': OrtProvider.NNAPI,
  'OpenVINOExecutionProvider': OrtProvider.OPEN_VINO,
  'QNNExecutionProvider': OrtProvider.QNN,
  'QnnExecutionProvider': OrtProvider.QNN,
  'RknpuExecutionProvider': OrtProvider.RK_NPU,
  'ROCMExecutionProvider': OrtProvider.ROCM,
  'TensorrtExecutionProvider': OrtProvider.TENSOR_RT,
  'VitisAIExecutionProvider': OrtProvider.VITIS_AI,
  'WebGpuExecutionProvider': OrtProvider.WEB_GPU,
  'WebNNExecutionProvider': OrtProvider.WEB_NN,
  'XnnpackExecutionProvider': OrtProvider.XNNPACK,
};

/// Fushi fork: the [OrtProvider] a native `getAvailableProviders` entry names,
/// or null when this Dart API has no value for it.
///
/// Null is not a failure to raise: an EP the Dart enum cannot name cannot be
/// requested through `OrtSessionOptions.providers` either, so it is correctly
/// absent from "providers you can ask for". Raising instead turned one EP that
/// a newer ORT release added into "no EP information at all" for every caller
/// (feedback eEnV5gBn1K: Android OCR / ASR lost their probe and showed the raw
/// `ArgumentError` to the user).
OrtProvider? ortProviderFromNativeName(String name) {
  for (final OrtProvider provider in OrtProvider.values) {
    if (provider.name == name) return provider;
  }
  return _nativeProviderAliases[name];
}
