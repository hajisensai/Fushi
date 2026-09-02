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
- **备注**：
  - **本 PR 不改 EP 默认策略**。用户报告里「int8 检测器在 ORT 1.22.0 的 DML EP
    上根本建不起来」这个归因尚未定性，而且与观测到的「退 CPU」互相矛盾——按上面
    第二层，真 DML 建不起来时当前代码只会整卷报错，不会退 CPU。要定性只需一条
    原始错误串（`dart:developer` 通道 `hibiki.ocr`），三向分流：
    `INVALID_PROVIDER: Provider is not supported: DIRECT_ML` ⇒ DML 分支没进跑的
    二进制，查构建；`PROVIDER_ERROR` + `0x8007000E` ⇒ 本机 D3D12 建不出设备的
    已知波动状态（GPU 客户端饱和时任何新进程都中招），环境问题非代码；
    `ORT_ERROR` + 算子/类型信息 ⇒ 这才是「int8 模型在 DML 上不成立」，那时才
    该改默认值。
  - `ocr_inference.dart` 里「DirectML 实测比 CPU 快 ~25 倍」是更早 ORT/模型组合
    上量的数，当前 int8 RT-DETR-v2 + ORT 1.22.0 这一组**未经真机复测**。本次
    保留 DirectML 作为 Windows 检测的首选加速档 = 延续既有行为、不做无数据的
    策略变更，但已在注释里标注该数字过期待复测，避免重演 BUG-1613（照着一句
    从未被执行过的类比结论把 CoreML 带到真机）。
  - 未做「进程内记住本机 DML 建不起来」的缓存。在拿到失败耗时实测之前那是解决
    可能不存在的问题，且 D3D 那个状态会自行波动，缓存会把临时状态焊成永久降级。
  - 真机 Windows GPU 复测未做（无构建产物/设备），本条不据此宣称真机已验证。
