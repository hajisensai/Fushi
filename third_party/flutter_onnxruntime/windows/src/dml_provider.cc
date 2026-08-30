// Copyright (c) MASIC AI
// All rights reserved.
//
// This source code is licensed under the license found in the
// LICENSE file in the root directory of this source tree.

#include "src/dml_provider.h"

// 本文件**刻意不包含任何 flutter 头**：见 dml_provider.h 的说明——
// `dml_provider_factory.h` 与 `flutter_windows.h` 各有一个全局 `Default` 枚举量，
// 同处一个 TU 必然 C2365。加 flutter 头进来会立刻把这个隔离破坏掉。
#include <dml_provider_factory.h>

#include <stdexcept>

namespace flutter_onnxruntime {

void AppendDirectMLProvider(Ort::SessionOptions &session_options,
                            int device_id) {
  // DirectML 要求顺序执行；内存模式（mem pattern）也必须关掉——它的分配无法在
  // DML 设备资源之间安全复用。
  session_options.SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL);
  session_options.DisableMemPattern();

  const OrtDmlApi *dml_api = nullptr;
  Ort::ThrowOnError(Ort::GetApi().GetExecutionProviderApi(
      "DML", ORT_API_VERSION, reinterpret_cast<const void **>(&dml_api)));
  if (dml_api == nullptr) {
    throw std::runtime_error("ONNX Runtime returned no DirectML provider API");
  }
  Ort::ThrowOnError(dml_api->SessionOptionsAppendExecutionProvider_DML(
      session_options, device_id));
}

}  // namespace flutter_onnxruntime
