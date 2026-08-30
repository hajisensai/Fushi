// Copyright (c) MASIC AI
// All rights reserved.
//
// This source code is licensed under the license found in the
// LICENSE file in the root directory of this source tree.

#ifndef FLUTTER_PLUGIN_FLUTTER_ONNXRUNTIME_DML_PROVIDER_H_
#define FLUTTER_PLUGIN_FLUTTER_ONNXRUNTIME_DML_PROVIDER_H_

#include <onnxruntime_cxx_api.h>

namespace flutter_onnxruntime {

// 把 DirectML 执行提供器接到 [session_options] 上。
//
// 单独一个翻译单元存在的理由不是分层，而是**符号冲突**：ORT 的
// `dml_provider_factory.h` 与 Flutter 的嵌入器 C 头 `flutter_windows.h` 各自在
// **全局作用域**声明了一个叫 `Default` 的枚举量（前者是
// `OrtDmlPerformancePreference`，后者是一个匿名 `typedef enum` 的线程策略）。
// 两者同处一个 TU 必然 C2365，且与 include 先后无关——换顺序只是换谁被判成
// 重定义。所以让 DML 头只在这个不含任何 flutter 头的 TU 里出现。
//
// 失败时抛 `Ort::Exception`（与插件里其它 provider 接线一致，由调用点统一转成
// PROVIDER_ERROR）。
void AppendDirectMLProvider(Ort::SessionOptions &session_options, int device_id);

}  // namespace flutter_onnxruntime

#endif  // FLUTTER_PLUGIN_FLUTTER_ONNXRUNTIME_DML_PROVIDER_H_
