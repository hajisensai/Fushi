## BUG-2050 · Windows OCR 从不探测 DirectML 可用性，每次任务白付一次注定失败的建会话
- **报告**：2026-09-02（用户：）
- **真实性**：✅ 真 bug，两层，且第二层比报告描述的更严重。
  - **第一层（白付代价）**：`fushi/lib/src/ocr/manga_ocr_service_impl.dart:193`
    只探测 CUDA（`isCudaAvailable()`），而
    `fushi/lib/src/ocr/ocr_inference.dart:141`（旧行号）的 Windows 分支直接**硬
    假设 DirectML 可用**。运行时里没有 DML 时（BUG-1968 之前打的是 CPU-only
    archive，或 DML DLL 没随包），每个任务都要先建一次注定失败的 DML 会话再退
    CPU。`getAvailableProviders()` 本来就在同一处被调用一次，native 侧
    `third_party/flutter_onnxruntime/windows/flutter_onnxruntime_plugin.cpp:618`
    也明确把 `DmlExecutionProvider` 映射成 `DIRECT_ML` 回报出来——**可用性一直
    问得到，代码只是没问**。代价不是每卷一次：`manga_region_rescan.dart:118`
    的「重新识别框选区域」走的是单图 folder job，每点一次就重开 isolate + 重建
    三个 session，等于**每次交互都付一次**。
  - **第二层（回退根本不触发）**：`ocr_inference_ort.dart:84`（旧行号）的回退
    条件是错误码白名单 `error.code == 'INVALID_PROVIDER'`。这个判据只在旧世界
    成立——那时插件的 Windows 分支没有 DML 实现，会在碰到 ORT **之前**整张
    provider 列表拒掉。BUG-1968 把真 DML EP 接进来之后前提消失：失败改从 ORT
    内部出来，错误码变成 `PROVIDER_ERROR`（`AppendDirectMLProvider` 抛，含建不
    出 D3D12 设备）/ `ORT_ERROR`（`Ort::Session` 构造抛）/
    `SESSION_CREATION_ERROR`，**三条全部不命中白名单 → `rethrow` → 整卷 OCR
    任务直接报错**，而不是报告里说的「退 CPU」。
    `fushi/test/ocr/ocr_inference_ort_test.dart:81`（旧行号）那条
    `non-provider session errors are not hidden by CPU fallback` 还把
    `SESSION_CREATION_ERROR` 明确断言成「不回退」，等于把这个洞焊死。
- **[x] ① 已修复** — 根因是「平台偏好」与「本机可用性」被揉成一个硬编码分支，
  以及「provider 问题」被用错误码代理。按这两条分别拆开：
  - `ocr_inference.dart`：拆出纯函数 `acceleratedProviderPreference`（平台/模型
    种类想要什么加速 EP，**不含 CPU**，与本机装了什么无关），
    `selectOcrExecutionProviders` 改为「偏好 ∩ 可用性」——取偏好里第一个真实
    可用的加速 EP + CPU 兜底，一个都不可用就纯 CPU。原来三层嵌套的
    `if (cudaAvailable) / if (kind == detection)` 特殊情况全部消失。
  - `ocr_inference_ort.dart`：`isCudaAvailable()` → `availableAcceleratedProviders()`，
    一次探测回报整个加速 EP 集合（CUDA/DirectML/CoreML）。文档写明这是**必要
    不充分**条件：EP 编译进来了不代表此刻能建出会话。
  - `ocr_inference_ort.dart`：回退判据由错误码白名单改为
    `preferred != cpu && providers.contains(cpu)`——**只看这次请求的首选是不是
    加速 provider，不看错误码**。模型损坏无需特判：CPU 那次同样失败、异常照抛，
    且抛的是更有诊断价值的 CPU 那条。维护「哪些码算 provider 问题」这张清单
    本身就是错的，native 每改一次错误映射它就悄悄过期一次。
  - `manga_ocr_service_impl.dart`：补 `recordUnavailable`——平台想要加速 EP 但
    运行时一个都没有时记一条降级原因。**这条不能省**：修好之后该路径不再产生
    session 失败，BUG-1163 要求的降级可观测性会跟着一起消失（用户原先至少还能
    看到 `detector: directml -> cpu (INVALID_PROVIDER)`），所以要在新的决策点
    上补记。
  提交：本提交。
- **[x] ② 已加自动化测试** — 全部经**变异实测**确认为活断言（变异后转红、还原后
  两个源文件 sha256 逐字节一致）：
  - `fushi/test/ocr/ocr_inference_ort_test.dart`：三条参数化用例钉住
    `PROVIDER_ERROR` / `ORT_ERROR` / `SESSION_CREATION_ERROR` 都必须回退 CPU 并
    回报原因；一条钉住「CPU 那次也失败时抛 CPU 的错误且只重试一次」（取代原先
    那条把洞焊死的断言）；`BUG-2050 加速 EP 探测` 组用 `_FakeOnnxRuntime` 钉住
    DirectML 能被探测到、CPU-only 运行时探测出空集、CPU 与不选的 EP 不进结果集、
    探测异常不被吞。
  - `fushi/test/ocr/manga_ocr_service_impl_test.dart`：新增「运行时没有 DirectML
    时检测直接纯 CPU、绝不请求 DML」「探测到的 EP 不在平台偏好里时不会被误选」
    「偏好表与可用性是两个独立概念」；BUG-1613 的 Apple 用例改成**故意把 CoreML
    报成可用**——旧签名下 CoreML 可用性根本无法表达，那条测的只是「代码里没写
    coreml 这个词」，现在才真正测到「就算能用也不许选」。
  - 变异实测记录：① 回退判据退回 `error.code == 'INVALID_PROVIDER'` → 4 条红；
    ② `selectOcrExecutionProviders` 忽略可用性 → 3 条红（Apple 那条不红是对的，
    它偏好表为空、循环不执行）；③ 探测映射摘掉 `DIRECT_ML` → 1 条红。
- **[x] ③ 已实测定性，并据此改掉 EP 默认策略** — 2026-09-02 本机实测
  （RTX 5090 / Win11 / ORT 1.22.0 DirectML build / DirectML 1.15.4）。运行时用
  与 `CMakeLists.txt` **同一组 SHA-256 钉死的 nupkg**（`29F9872D…` / `4E7CB7DD…`
  逐位核对通过），模型用清单里的真档（`detector-v4-s_int8.onnx`，11,120,765 B
  = 清单 `expectedBytes` 精确一致）。量具已收进仓库：`tool/ocr_dml_probe/`。

  探针分三段互不推断，结果：

  | 段 | 结果 |
  |---|---|
  | ① `GetAvailableProviders()` | **列出 `DmlExecutionProvider`** ⇒ 打包没问题，BUG-1968 的修复是有效的 |
  | ② `D3D12CreateDevice(HARDWARE)` | **OK** ⇒ 排除本机 GPU 客户端饱和那条已知波动路径 |
  | ③ `Ort::Session` + DML | **失败**，`ORT_RUNTIME_EXCEPTION`，`MLOperatorAuthorImpl.cpp(2851)`，`E_INVALIDARG (0x80070057)` |

  同架构 fp32 对照组把变量精确隔离出来：

  |  | DML 建会话 | DML 稳态 | CPU 建会话 | CPU 稳态 |
  |---|---|---|---|---|
  | **int8（出包用）** | **❌ 失败，白付 1546.9ms** | — | 733.8ms | **81.5ms** |
  | fp32（对照） | ✅ 2957.1ms | 21.6ms | 1461.2ms | 419.4ms |

  fp32 在**同一台机器、同一个运行时**上建得起来且比 CPU 快 **19.4 倍** ⇒ 不是
  显卡、不是 D3D12、不是打包 ⇒ **变量就是 int8 量化**。用户的归因完全正确。

  **改动**：`acceleratedProviderPreference` 的 Windows 档去掉 DirectML，检测与
  识别都只剩 CUDA（理由不同：检测是模型建不出会话，识别是自回归解码的架构性
  负优化）。保留 DirectML 只会让每个任务白付 1547ms 换零收益，而且按 BUG-1968
  之后的错误码，那次失败会以 `ORT_ERROR` 出现——修复前它连回退都不触发。

  **「~25 倍」的真相**：那个数量的是 **fp32 档**（本次实测 19.4x，同量级）。
  检测器后来换成 int8 小档（11MB vs 168MB，且 int8 在 CPU 上反而比 fp32 快 5 倍：
  81.5ms vs 419.4ms），加速前提随之消失，注释却留了下来。已在
  `ocr_inference.dart` 里把整段实测数据和「换模型才是重新评估的前提」写清楚，
  并加守卫测试 `BUG-2050 DirectML 不出现在任何平台/模型种类的偏好表里`。
- **备注**：
  - 未做「进程内记住本机 DML 建不起来」的缓存——现在更没必要了：失败是确定性的
    算子层不兼容（不是会波动的环境状态），直接不请求即可，不需要运行期记忆。
  - **fp32 + DML 不是免费的更优解**，别看到 21.6ms 就想换档：模型 168MB（vs
    11MB），建会话 2957ms + 首次推理 8817ms 的暖机，对「重新识别框选区域」这种
    单图交互是净亏（int8+CPU 全程约 1 秒）。整卷长任务另算，但那是带下载体积
    代价的产品决策，不在本 bug 范围。
  - 探针是独立 exe，不参与构建、不被 app 引用；DML 会话选项与
    `dml_provider.cc` 严格一致，改那边要同步改探针。
  - 未在真实 app 内跑整卷 OCR 复测（模型 470MB 未下载、无 Windows 构建产物）。
    但探针用的是同一份运行时字节 + 同一个模型文件 + 同一套 DML 会话选项，
    ③ 的失败点在 ORT 会话初始化内部，与 Flutter 层无关。
