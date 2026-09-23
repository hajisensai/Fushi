# Windows 漫画 OCR 候选与实测

> 2026-09-24 PR #1626 审查补记：本文实测对应原提交 `762be5b89fc` 及之前的实现。审查已将横排嵌套框去重移到识别后，以几何与文本覆盖共同确认，避免父段振假名过滤误丢小字号正文；最终方案会增加嵌套框的识别工作，本文整页计时不能视为该修订后的重新测量。另修正默认 Lens 下手动导入 CUDA 时隐藏安装进度/取消、删除未互斥的问题。审查和最终自动化回归见 [2026-09-24 审查记录](2026-09-24-project-review.md)。

目标：在《君が一等星に光るまで》上改善本机识别速度，并检查难字、手写与旋转文字。Hayai 是候选之一，选型不依据 Mangatan 的菜单或作者单独公布的速度。

环境：Windows、i5-12600KF、RTX 4070 Ti 12 GB；测量期间用户程序占用了大部分显存。没有停止用户程序，漫画图像只在本机识别。不同候选使用同一批原始检测框，避免混入检测器差异。16 框中 11 框有独立人工真值（126 字符）；其余 5 框含模糊装饰、斜手写或旋转英文，只作定性检查。这是小样本诊断，不能推算全书准确率。

结论：没有一个候选在速度、正文、名字、手写和英文上全面胜出。**原版 manga-ocr 的 CUDA + KV cache + batch 是本轮主要提速方案；日文精度候选是 Hayai v2.1；无需安装 Python/CUDA 的应用内快速选项是 Baberu；旋转英文等疑难框可考虑 Paddle 漫画版。** Nova 的版本更新没有在本书上换来更高的正文准确率。下面严格区分研究环境与已交付的应用功能。

## 候选调查

| 候选 | Windows / GPU 接入 | 取舍 |
|---|---|---|
| [manga-ocr](https://github.com/kha-white/manga-ocr) | 已内置 ONNX 当前无 KV cache，Windows 走 CPU；原版 PyTorch 可用 CUDA/cache/batch | 本机 GPU 对照最快，说明慢并不全是模型问题；本轮已修正 ONNX 的 Pillow 预处理、线程争用与重复检测框 |
| [Baberu](https://huggingface.co/genshiai-daichi/baberu-ocr) | 官方 ONNX；图像编码可用已有 DirectML，解码有 KV cache | 识别权重约 242 MB，Apache-2.0；快，但部分正文会新增错字 |
| [Hayai v2.1](https://huggingface.co/JustANormalTinkerer/hayai-ocr-v2) / [Nova](https://huggingface.co/JustANormalTinkerer/hayai-ocr-v2.5-nova) | PyTorch CUDA；需要额外运行库，识别模型约 623 MB | 动态图像 patch、批量推理；需按相同原图比较，不能把不同 patch 的结果混在一起 |
| [PaddleOCR-VL-For-Manga](https://huggingface.co/jzhang533/PaddleOCR-VL-For-Manga) | PyTorch，或正确配置视觉 projector 的 llama.cpp | 约 1.9 GB 权重，精度候选；不能把作者 Manga109 随机裁框切分的成绩当跨作品泛化成绩 |
| [manga-ocr-nar-preview](https://huggingface.co/muscgab/manga-ocr-nar-preview) | 一次前向预测，支持 CUDA，约 196M 参数 | 作者全量 Manga109-s 同条件比较优于 Baberu；本机未复现，预览版，权重 CC BY-NC-SA 4.0，长文本与英文仍弱 |
| [HunyuanOCR 1.5](https://github.com/Tencent-Hunyuan/HunyuanOCR) | 较重运行时；最快 DFlash 路径依赖专门实现 | 作者的 H20 / OmniDocBench 耗时不是本机漫画成绩，定制许可证，暂不优先接入 |

Chimahon 并非一个可直接搬到 Windows 的独立模型：其 [LensEngine](https://github.com/Chimahon/chimahon/blob/1b94318e7033fd8ac22c9ba4cd0a6f925f0f1db3/chimahon-local-ocr/src/main/java/chimahon/local/ocr/LensEngine.kt) 使用 Google Android JNI/TFLite；另有 Paddle NCNN Android 动态库。应用包装层没有核实到 GPU 开关，模型 payload 仓也未找到独立许可，不能由应用 GPL 推断所有二进制可自由再分发。

[Mangatan](https://github.com/1Selxo/Mangatan/tree/c8cedbbf9dc8ff244b915f121f11e91f9948017b) 的 1–4 并行设置控制页/章节请求。Hayai 服务仍逐请求运行生成，逐页裁框也串行；增加任务数不等于模型批处理或 GPU 加速。它固定的 v2.1 权重与本轮使用的权重 SHA256 一致，但推理代码和参数并不相同。

## 已完成的测量

原有 CPU 路径：在同一真实第 5 页、原版/新版交错两轮中，流水线中位数由 58.247 秒降至 23.200 秒。12 个检测框坐标一致；不含会话初始化与文件解码。之前受编译负载影响的反向结果也保留在原始记录里，不作代表数字。完整 Windows 插件合成页测试为 7.401 秒，四句日文正确；这些是不同输入，不能跨行直接比倍数。

Baberu 官方 Python/ORT 1.22 路径，16 框，原图 RGB 裁切，固定 revision `d9cc13153e9a1cd8fdfa3b7b1cc329da2020aeae`：

| 执行方式 | 16 框稳定轮 | 单框中位数 | 会话加载 |
|---|---:|---:|---:|
| CPU，2 线程 | 6.045 秒 | 362 ms | 645 ms |
| 全部 DirectML | 2.307 秒 | 129 ms | 1456 ms |
| DirectML 图像编码 + CPU 解码 | 1.210 秒 | 68 ms | 984 ms |

此表不含整页检测和 Flutter 桥接。ORT profile 证实视觉算子实际在 DML 执行；不是仅看 provider 名称判断 GPU 生效。小解码器每 token 的 GPU 传输开销让混合模式更快。真实应用数字见下文，不能用这张表代替。

准确率必须同时看整句与字符：现有 manga-ocr 为 10/11 整句正确、旧预处理 3/126 字符编辑、新预处理 4/126；Baberu 为 9/11、2/126。Baberu 把名字误读从多个字符减为一个，却将正确的「芝居」新增误读成「彦居」。两个斜手写框和 90° 英文仍失败，因此保留经典模型，不以较低字符错误数宣称全面更准确。

### CUDA 对照：同样 16 个原图裁框

独立 Python 3.11 环境，torch 2.8.0+cu128，模型保持常驻；下表为两轮热运行的中位数，含预处理，不含进程启动、模型加载和整页检测。每种 batch 的输出已逐框对比，没有因加大 batch 改字。不同模型算法/精度不同，因此比较的是部署方案，不是单独控制架构变量的实验。

| 方案 | batch 1 | batch 4 | batch 8 | 明确真值整句正确 | 字符编辑数 |
|---|---:|---:|---:|---:|---:|
| 原版 manga-ocr，FP32、beam 4、KV cache | 4.442 s | 1.845 s | **1.062 s** | 10/11 | 4/126 |
| 原版 manga-ocr，FP16、beam 4、KV cache | 3.809 s | 1.912 s | 1.390 s | 10/11 | 4/126 |
| Hayai v2.1，256 patches | 9.118 s | 4.121 s | 2.517 s | **10/11** | **1/126** |
| Hayai v2.1，384 patches | 8.153 s | 3.590 s | 3.377 s | 10/11 | 1/126 |
| Hayai Nova，512 patches | 9.674 s | 4.865 s | 3.146 s | 9/11 | 2/126 |

v2.1 的剩余明确错误是「らいかちゃん」漏掉最后的「ん」；斜手写框「ねむれない…それは大変」比原版/Baberu 接近原文，另一斜手写仍错。Nova 又把正文「とてつもなく」读成「とってつもなく」。v2.1 384/batch 8 两轮为约 2.32 和 4.43 秒，存在系统波动；不据单次最低值宣称更快。

Hayai 使用固定 revision：v2.1 `53aed13296a9d39bd7c0c0bcba745010d8142b5b`，Nova `e34d7755ed11e626c5ba39544af5d66f20ee57cc`。远程模型代码先审阅再离线执行，并检查所有权重张量确实加载，避免新版 Transformers 静默随机初始化造成伪成绩。GPU allocator 峰值：原版 FP32 约 0.61 GB，Hayai 约 0.96–0.99 GB；这不是包含 CUDA context 与其它应用的总显存。Hayai 从进程启动到模型就绪约 23–28 秒，适合常驻服务。研究环境和三个模型下载合计约 5.3 GB。

现有 Optimum 的 BERT decoder ONNX 配置不直接提供本模型的带缓存导出，不能把 `use_cache=true` 当作现有 ONNX 已支持 KV cache。原版 CUDA 已在后续实现为应用内可选的托管引擎，见下节；Hayai 仍只完成研究环境实测。

### Paddle 漫画版：七个普通/困难框

固定 revision `1e8aa5f1dd90cc86fe9137c9c0b26ebde613cfe8`，约 1.917 GB 权重；官方动态分辨率、greedy、KV cache、batch 1、eager。七框是提前选定的两框普通正文与五框困难文字；CPU FP32 与 CUDA BF16 的原始输出逐字相同。

- 两框正文正确；旋转 90° 的英文标题和两行副标题完整正确，是这批候选中最明显的独有改善。
- 「♪おやすみ」正确，名字仍错，两处斜手写仍有错字/邻框混入，没有全面胜过 Hayai v2.1。
- CPU 四线程七框共 88.210 秒；CUDA 共 11.327 秒，第一框 3.482 秒、其余六框中位数 1.326 秒；加载另计。没有重复轮，且 GPU 测量时有 Flutter 功能测试的 CPU 负载，不能与上表计算严格倍数。
- CUDA allocator 峰值 reserved 2.363 GB；预检 `nvidia-smi` 可用约 4 GB，本轮无 OOM。该模型只输出文字，若接入仍需原检测框与阅读顺序；生成概率未经校准，不能直接拿来作自动复识别阈值。

## 应用接入与验证记录

已实现 Windows 的可选 Baberu 快速模型：应用下载、续传、导入与删除管理，含检测与 PP-OCR 横排模型约 284 MB；已有 DirectML 无需另装 CUDA，GPU 无法建立会话时显示实际 CPU 回退。模型独立目录与内容指纹保证切换时不把经典模型缓存当成新结果。保留原分辨率横排切行路径，避免目录/说明小字被压进 224×224；现有任务继续使用启动时的模型，新任务才跟随设置。互联 host 同样动态选择；非 Windows 从备份恢复 Baberu 偏好时统一回退经典模型，导入目录与清单也保持一致。

设置入口：设置 → 漫画 → 漫画 OCR，选本地 ONNX 后选择本地模型；阅读器的 OCR 设置复用同一入口。经典模型仍是默认值。并行设置控制不同书籍的后台整卷任务（自动或 1–4），同书章节仍按序处理；增大名额立即唤醒等待者，减小时让已有任务完成，低内存模式最多一个。这不是单页 batch size；导入向导和互联 host 使用各自的调度路径，也不把该设置宣称为所有 OCR 的全局并发上限。

真实 Windows Flutter 插件（Debug 集成构建，同 16 框、逐框顺序识别、预解码页图，含 Dart 预处理和插件桥接，不含会话加载）：CPU 两轮 10.467 / 9.815 秒，DML 图像编码 + CPU 解码 5.634 / 6.144 秒，中位数 **10.141 → 5.889 秒，降低约 42%**。加载分别 604 / 1164 ms。11 个明确真值框仍为 9/11、2/126 编辑；难框输出在 CPU/DML 有差异，两者均失败。真实应用路径明显慢于 Python，逐 token 的 KV 张量跨插件传输是后续优化方向，不能宣传为应用内 1.21 秒，也不能把 Debug 数字当作发布版基准。

同一原生测试另跑完整「检测→识别→保存」合成页：四句日文全部正确，5.567 秒，加速状态 `CPU/DIRECTML+CPU`。这包含更多阶段，不能和裁框表直接算倍率。证据：`fushi/.codex-test/windows-itest/win-itest-20260923-183906-5a236e99/command.log`，2 个集成用例退出码 0。

随后补了真实第 3、5 页完整流水线验证：目录页检出 3 框，五章条目与页码均保留；正文页检出 12 框（11 竖、1 横），七个明确印刷框 6/7 逐字正确，余下仍是「芝居→彦居」。目录的一处「裏方」仍误成「里方」；旋转英文与两处斜手写仍不准。两页共 14.428 秒，第一页含初始化 9.019 秒，第二页增量 5.402 秒；同期还有功能测试，**仅作诊断计时**。同轮合成页另耗时 6.322 秒，四句全部正确。证据：`fushi/.codex-test/windows-itest/baberu-real-pages-20260923/command.log`（2/2 通过）与 `.codex-test/research/baberu/page-smoke/native-report.json`。前后用户 Fushi 进程保持运行。

验证覆盖：经典模型的 Pillow bilinear 与 Baberu 的 bicubic 全张量 SHA256 对照、词表与 KV 输入/输出契约、贪心解码；模型切换/缓存隔离、导入与删除；真实 DB 偏好持久化、真实 Provider 在 1→3 时唤醒原队列，以及下载中禁止切换模型。全量 `flutter analyze --no-pub` 无问题，最后补充的集成用例/守卫也单独 analyze 通过。独立审查发现的跨平台模型回退问题已修复并复核。

按 `tests_for_changes.dart` 映射加 OCR 邻接测试，共 390 个文件，Windows 命令长度限制下分六批执行：初轮 3462 通过、3 失败、1 跳过。两处本轮问题（偏好键排序、OCR 字符词表单码点校验的非学习计数登记）已修复，各自复测通过。剩余一条为已有的 `settings_schema_coverage_test.dart`：Windows 的 `interconnect/Allow remote launch` 缺少效果探针/覆盖登记；在未含本轮改动的主 checkout `5511e4` 上实测复现同一失败（实际 1 通过、1 失败），不是零测试编译失败。此项由基底中的 `ad4c4bd04cb` 引入，本轮没有修改它。证据为 `.codex-test/ocr-final-batch-{1..6}.log`、`ocr-preference-key-fix.log`、`ocr-study-guard-fix.log` 和 `ocr-settings-baseline.log`。

本机原始证据保存在工作树 `.codex-test/ocr-real/` 与 `.codex-test/research/`：人工真值、原框坐标、模型固定版本及哈希、逐框输出、冷热轮耗时、ORT profile。版权漫画图像和私有缓存不入库。


## 原版 manga-ocr 托管 CUDA 引擎（后续实现）

用户选择继续优化原版模型。本次增加 Windows 的 `manga_ocr_cuda` 选项：官方原版权重、Pillow 灰度处理和 beam 4 解码保持不变，以常驻 PyTorch CUDA 进程、KV cache、每批最多 8 个文字框减少重复计算与跨进程往返。竖排框合批，横排继续使用已有 PP-OCRv6 路由；框序和阅读顺序保持一致。经典 ONNX 仍为默认，Baberu 是独立可选项。

同一组 16 个原始检测框，经实际 Dart JSONL 桥接连续三轮，**每轮 16/16 与原版 PyTorch 参考逐字一致**。使用原 PNG level 6 时，完整桥接耗时 2.853 / 1.717 / 1.977 秒，进程启动至 ready 11.36 秒（加载另计）。桥接结果包含 PNG 编码/传输和识别，不能与前表的纯推理 1.062 秒混算提速倍数。无 torchvision 的隔离运行库已验证；强制 CPU 时也正确识别长句并明确上报降级。

随后将本机 IPC 的无损 PNG 压缩改为 level 1。同组 16 框在单进程中预热后做 12 组 AB/BA 交错微基准，PNG 编码加 Base64 转换的中位耗时从 468.376 ms 降至 210.341 ms（减少 55.1%）；PNG 总量从 642,250 增至 655,369 字节（增加 2.0%）。两档解码后的 16 框 RGBA SHA256 全部与输入一致。此时另有功能测试/分析任务，数据仅代表编码微基准；未重跑 level 1 的 16 框桥接计时，上述完整桥接数字仍属于 level 6。最终整页测试使用 level 1，见下文。证据为 `.codex-test/ocr-real/cuda-bridge/png_level_result.json`。

安装由应用管理：Python 3.11.9 embeddable、torch 2.8.0+cu128、Transformers 5.0.0 和完整二进制依赖锁定 URL、大小与 SHA256，下载完离线安装，不调用用户的 Python，不修改系统 PATH。原版模型 revision 固定为 `aa6573bd10b0d446cbf622e29c3e084914df9741`，检测器和 PP-OCR 也固定 revision/哈希。下载总量约 4 GB；保留安装包与展开运行库合计需要约 12 GB 磁盘。显卡驱动仍由系统提供。Microsoft CRT 使用 Windows 发行包已携带的 DLL，放入独立 Python 目录。

显存不足按 8→4→2→1 缩批；单框仍不足则转 CPU，并通过现有加速状态通知界面，后续请求保持 CPU。取消启动或识别时立即结束子进程并等待回收；输入管道关闭和父进程退出都有独立退出监测。Windows 输入线程使用 Win32 ReadFile，规避 CRT stdin 锁与 NumPy/OpenBLAS DLL 初始化互锁；不是靠延长启动超时处理。安装取消、损坏文件、离线导入与下载失败不会发布已就绪状态。

本地证据（不入库）：`.codex-test/ocr-real/cuda-bridge/bridge_result.json`、`cpu_bridge_result.json`、`.codex-test/managed-manga-cuda-install.log`。漫画原图和模型文件均不进入 PR。

### 最终应用整页与安装验证（2026-09-24）

使用最终托管运行库，经 Windows Flutter 原生集成测试跑真实第 3、5 页「检测→识别→保存」，并断言实际识别设备为 CUDA：**两页共 14.384 秒，目录页含首次加载 13.318 秒，随后正文页增量 1.060 秒**。正文页仍为 12 框（11 竖、1 横），七段有人工真值的印刷文字 **7/7 逐字正确**，包含 Baberu 误读的「芝居」。目录五章及页码保留，但「裏方→里方」、旋转英文与手写文字仍存在错误。这是单轮、小样本的 Debug 诊断，不能推算整本准确率或所有页面的耗时，也不能把热页时间当作冷启动时间。

同轮合成页四句日文 4/4 正确，含独立加载共 6.525 秒；原生集成用例 **2/2 通过、退出码 0**。证据为 `fushi/.codex-test/windows-itest/manga-cuda-real-pages-20260923/command.log`、`.codex-test/ocr-real/cuda-native-page-report.json`。用户原有 Fushi 进程在测试前后保持运行，测试自己的 Python worker 已退出。

最终离线安装实测 226.6 秒，49 项素材校验收据完整，worker SHA256 与最终源码一致；单次就绪检查 98 ms。安装审查发现的三项问题已修复：安装子进程具有父进程退出监测；`PIP_CONFIG_FILE` 显式禁用外部 pip 配置；变化素材重新校验，而 worker 更新或模型修复不重复安装整个运行库。中断留下的 staging 仅在获得目录锁后清理。实际强退父进程使安装子进程以 125 退出，取消实测 504 ms 完成清理。证据为 `.codex-test/ocr-cuda-final-install.log`、`managed-manga-cuda-final-ready.json`、`runtime-wrapper-report.json`。

Windows 的 debug / beta / formal **发布通道**均通过现有发布流程携带 `msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll`。本地直接 `flutter --debug` 的开发构建没有经过此打包步骤，需要提供同一组 app-local CRT；这与发布通道名为 debug 不是同一含义。

本轮 CUDA 的变更映射覆盖 199 个测试文件，分四批实际执行 **1,858 通过、1 项既有失败、1 跳过**。唯一失败仍是上述基底已有的 `settings_schema_coverage_test.dart`（`interconnect/Allow remote launch`），没有新引入失败。安装器 24 项、worker/桥接 14 项、批处理/路由 23 项专项测试均通过。全量 `flutter analyze --no-pub` 无问题；安装器最后的小改动另作定向 analyze 通过。证据为 `.codex-test/ocr-cuda-impact-batch{1..4}.log`、`ocr-cuda-runtime-tests.log`、`cuda-worker-level1-tests.log`、`ocr-cuda-final-analyze.log` 和 `ocr-cuda-runtime-final-analyze-retry.log`。

最终代码再次覆盖 52 个目录守卫文件与 10 个受影响 OCR 测试文件，串行执行 **523 项全通过、退出码 0**，耗时 8 分 52 秒。此前一次运行停在 Flutter 编译器，未计为通过；串行重跑完成真实执行。最终日志为 `.codex-test/ocr-cuda-final-tests-serial.log`。提交前独立复核安装器的取消、父进程退出、配置隔离、文件锁和就绪发布，未发现遗留阻塞问题。
