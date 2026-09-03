## BUG-2034 · 本地漫画 OCR 因 DirectML 初始化失败 + native 错误串非 UTF-8 而整卷失败
- **报告**：2026-09-02（用户：截图 `OCR 失败: Bad state: manga OCR job failed: FormatException: Unexpected extension byte (at offset 228)`）
- **真实性**：✅ 真 bug，两个独立缺陷叠加，已在本机用独立 ORT 探针逐字节复现
  - 功能缺陷根因 `fushi/lib/src/ocr/ocr_inference_ort.dart:85`（旧实现只在 `PlatformException.code == 'INVALID_PROVIDER'` 时回退 CPU）
  - 编码缺陷根因 `third_party/flutter_onnxruntime/windows/flutter_onnxruntime_plugin.cpp`（78 处 `result->Error(code, e.what(), nullptr)` 把 native 字节原样送过 method channel）
- **[x] ① 已修复** — 提交 `4217d27465`
- **[x] ② 已加自动化测试** — `fushi/test/ocr/ocr_inference_ort_test.dart`、`fushi/test/ocr/onnxruntime_windows_error_encoding_guard_test.dart`
- **备注**：

### 现象

Windows 上对在线漫画跑本地 OCR，整卷任务立刻失败，toast 显示
`Bad state: manga OCR job failed: FormatException: Unexpected extension byte (at offset 228)`。
失败发生在建会话阶段，连 `manga_ocr_out/` 都没建出来，所以磁盘上不留任何残留。

### 根因

报错本身是假象，`FormatException` 只是**回复解不出来**的症状。真实链条：

1. `selectOcrExecutionProviders`（`ocr_inference.dart:148`）在 Windows 无 CUDA 时给检测器选
   `[directml, cpu]`。本机没有 `onnxruntime_providers_cuda.dll`，所以必走 DirectML。
2. ORT 1.22.0 的 DirectML EP **初始化不了** `detector-v4-s_int8.onnx`，抛
   `E_INVALIDARG (80070057)` @ `MLOperatorAuthorImpl.cpp:2851`。
3. ORT 拼这条消息时把系统错误文本按机器 ANSI 代码页追加进去，中文 Windows 上就是 GBK：
   完整消息 240 字节，第 228 字节起是 `B2 CE CA FD B4 ED CE F3 A1 A3`（"参数错误。"）。
4. 插件 `result->Error("ORT_ERROR", e.what(), nullptr)` 把这串字节原样交给 method channel。
   channel 的 String 契约是 UTF-8 且 Dart 侧解码是**严格**的，于是解码在第 228 字节炸掉 ——
   用户看到的 offset 228 与这里逐字节对应，而真正的失败原因彻底消失。
5. 抛出的是 `FormatException` 而不是 `PlatformException`，旧回退判据（只认
   `INVALID_PROVIDER`）连碰都碰不到它；即使 native 编码正确、抛的是
   `PlatformException(ORT_ERROR)`，那条判据同样不认。**EP 列表尾部的 `cpu` 后备一次都轮不到**，
   整条 OCR 直接不可用。

### 复现与证据（本机，用户安装目录 `D:\APP\Hibiki` 的同一份 `onnxruntime.dll`）

用独立 C++ 探针直连 ORT，绕开 Flutter：

| 场景 | 结果 |
|---|---|
| detector int8 + **DirectML** | `ORT_EXCEPTION`，len=240，首个非法 UTF-8 字节 **offset 228** |
| detector int8 + **CPU** | 会话建成（inputs=2 / outputs=3）——模型本身没问题 |
| encoder fp32 + **DirectML** | 会话建成——本机 DirectML 环境没问题 |

三者对拍说明：既不是模型坏，也不是 DirectML 环境坏，而是**这个 int8 量化检测器与 ORT 1.22.0 的
DML EP 不兼容**；而它本该被 CPU 后备接住。

排除项（都验过，不是原因）：`vocab.txt` 是合法 UTF-8（6144 行、特殊 token 齐全、字节数与清单一致）；
四个模型文件字节数与 `manga_ocr_model_manifest.dart` 的 expected 完全一致；`package:image` 4.3.0 的
所有 utf8 解码都带 `allowMalformed: true`，抛不出 `FormatException`。

### 修复

两处都是根因，缺一不可：

1. **native 边界归一** —— 新增 `WindowsUtils::toUtf8Message()`：合法 UTF-8 原样放行（模型路径里的
   中文是 ORT 用 `ToUTF8String` 写的真 UTF-8，无条件按 ANSI 重解会毁掉它），否则按 `CP_ACP` 读回
   再编成 UTF-8，最坏保留 ASCII 骨架。插件里 78 处 `result->Error` 全部收口到唯一出口 `FailWith`，
   而不是只挑"看起来是动态消息"的那 28 处——字面量今天是字面量，明天就是拼接。
   本地校验的严格度**刻意对齐 Dart 的 `utf8.decode`**（拒 overlong / 代理项 / 超 U+10FFFF），
   否则"这里判合法、过了 channel 仍然炸"就是同一个 bug 换个位置再来一次。
2. **回退判据改对** —— `createOcrSessionWithProviderFallback` 从"只认某个错误码"改成
   "首选 EP 没建成会话就退 CPU"。代价是模型损坏时多试一次 CPU（那种输入下 CPU 同样建不成，
   照样抛错，只是多花一次失败的时间）；收益是真·EP 故障时功能不再整个躺平。
   CPU 重试也失败时抛出的仍是 **CPU 那次**的异常（类型与 code 都不变），首选 EP 的失败落日志——
   两次失败都留痕，回退不许把第一个错误吃掉。

### 测试

- `fushi/test/ocr/ocr_inference_ort_test.dart`
  - 既有的 `non-provider session errors are not hidden by CPU fallback` 守的意图是对的（回退不许
    掩盖真实失败），但把意图编码成了"只许试一次"——那正是本 bug 的一半。改为
    `session errors still surface when the CPU retry fails too`：仍断言异常类型与 code 原样抛出，
    同时断言 CPU 真的被试过（`attempts == 2`）。
  - 新增 `EP initialisation failure inside ORT falls back to CPU`（`ORT_ERROR` + `80070057`）。
  - 新增 `a non-PlatformException from the channel still falls back`（`FormatException`）。
- `fushi/test/ocr/onnxruntime_windows_error_encoding_guard_test.dart`（新增源码守卫）：插件内
  `result->Error` 只允许剩一处且必须过 `toUtf8Message`；归一函数存在、对合法 UTF-8 短路、
  校验严格度覆盖 `0xC2` / `0xED` / `0xF4` 三个边界。判据前先剥 C++ 注释——本文件自己的说明里就
  照抄了被禁的写法，不剥就会被自己命中。
- **变异实测**（全部单点注入 + sha256 校验还原，未用 `git checkout`）：
  - 回退判据改回旧的错误码白名单 → 恰好 3 条新/改用例变红，其余绿。
  - 绕过统一出口（一处改回裸 `result->Error`）→ 守卫红在"只有一个出口"。
  - 出口不再调 `toUtf8Message` → 守卫红在归一断言。
  - 去掉合法 UTF-8 短路 → 守卫红在"必须原样返回"。
- **native 端到端实测**：用真实 DML 失败串过 `toUtf8Message`——原始 240 字节 offset 228 非法，
  归一后 245 字节全合法（5 个汉字 GBK 10 字节 → UTF-8 15 字节），错误码 `80070057` 与
  `MLOperatorAuthorImpl.cpp` 源位置都保留。

### 遗留

- Windows 检测器默认选 DirectML 的收益（`ocr_inference.dart` 注释称"比 CPU 快 ~25 倍"）是在更早的
  ORT / 模型组合上测的。本机实测该 int8 检测器在 ORT 1.22.0 的 DML EP 上根本建不起来，等于一直在
  白付一次失败的代价再退 CPU。默认 EP 策略是否要调整，应在本修复落地后拿真机数据重新评估，
  不与本次修复混在一起。
- 本次改的是 Windows 侧；Linux/macOS/Android 的 native 错误串本就是 UTF-8，不受影响。
