# 漫画阅读器优化：用户反馈验真 + 分级方案

> 起因：用户 2026-09-15 在 Windows 桌面版上的反馈（原文 7 条）——查词弹窗不能连点换词、弹窗慢、被查词不高亮、在线源为何要整章下载再整章 OCR、本地 OCR 慢且只用 CPU、本地 OCR 只对竖排单行气泡准、阅读器本体比 Mihon 薄「不会选它而不用 Mangatan」。
> 本文 = ① 每条沿真实代码路径的验真结论 ② 已当场修掉的三条 ③ 剩四条的方案与优先级，待用户拍板。
> 前置设计：`2026-07-24-manga-ocr-design.md`（OCR 选型）、`2026-07-25-manga-online-source-design.md`（在线源 + 阅读期懒 OCR，O4 阶段）。

## 0. 核心判断

- 用户的感受**全部成立**，但要拆两层看：**学习层（OCR 三路、查词、制卡、统计）Hibiki 已强于 Mangatan**，07-25 设计的 §2 矩阵仍成立；**阅读器本体**确实只覆盖 Mihon 约 30 项阅读设置里的 6 项，且缺的正是日常高频项。用户「不会选它」的原因在本体层，不在 OCR 层。
- 三条查词弹窗问题是三条独立真 bug（BUG-2553 / 2554 / 2555），根因都在漫画页漏接小说页早已有的机制，改动小，本轮已修。
- 「整章下载 + 整章 OCR」**不是设计意图**：07-25 §5 拍板的 O4 是「当前页起向后 2 页预扫 + 磁盘缓存」，现状是 BUG-1958 把在线章接进本地 OCR 时走了捷径，O4 只落了 Google Lens 那半边。
- 本地 OCR 慢的主因不是「跑在 CPU」，是识别器架构 + 通道开销；识别错的主因是「块级框整框硬压 224×224 一次识别」。两者都在现有管线内有不换模型的解法。

## 1. 验真结论一览

| # | 用户反馈 | 判定 | 根因（file:line 为 W1ght fork develop `fc3fed3e33`，上游 `manga_fushi_page.dart` 行号有偏移，按符号名定位） | 处置 |
|---|---|---|---|---|
| 1 | 弹窗开着时点另一个词要先关弹窗 | ✅ 真 | 弹窗可见时全屏 `LookupDismissBarrier` 实心拦指针（`base_source_page.dart:668-693`），默认 tap 清整栈（`:253`）；小说页覆写了 `onDismissBarrierTap` 逆映坐标重新选词（`reader_fushi_page.dart:4220-4232`），漫画页没覆写 | **已修** BUG-2553 |
| 2 | 弹窗反应慢 | ✅ 真（在线章节）+ 叠加 #1 | `dispatchMangaSelection` 在查词前 `await selectPageForMining`（`manga_fushi_page.dart:273`），在线章节此处等 `session.localFile` + `exists()`；另外 #1 让用户第一次点只关栈 | **已修** BUG-2555；FFI 同步查词是全应用共性 |
| 3 | 选中文本不高亮 | ✅ 真 | `processMangaSelection` 丢弃 `highlightCount`（`:3795`），从未 eval `highlightInvocation`；覆盖层文档无 `::highlight` 规则（`manga_overlay_html.dart:693-713`） | **已修** BUG-2554 |
| 4 | 在线源为何要整章下载再整章 OCR | ✅ 真（非 Lens 引擎） | `mihon_online_ocr.dart:93-107` 先 `materializeOnlineMangaPages` 串行物化全章，完成后才 `yield*` 本地 folder job；job 只认目录（`manga_ocr_service_impl.dart:77-89`），pipeline 严格 0..N-1（`manga_ocr_pipeline.dart:82-112`），不传 startPage（`manga_ocr_job_stream.dart:149-150`）。Lens 走逐页路径（`mihon_online_ocr.dart:213-304`） | §2 方案 A |
| 5 | 本地 OCR 慢、只用 CPU | ✅ 真 | manga-ocr ONNX 导出**无 KV cache** + beam4，每 token 整序列重跑 decoder（`manga_ocr_recognizer.dart:8,168-185`；`beam_search.dart:165`），每步把 2.4 MB encoder 隐状态经 MethodChannel 重送 + 整块 logits 拷回（`onnx_inference_ort.dart:202-243`）；逐框逐页串行无 batch（`manga_ocr_pipeline.dart:91-143`）；`intraOpNumThreads` 未设（`manga_ocr_service_impl.dart:324-347`）；补扫每次重开 isolate 重载 460 MB 模型（`manga_ocr_auto_start.dart:244-256` → `:433 Isolate.spawn`）。Windows 加速表为空是 BUG-1149/1968/2034/2050 走完后的**有意**决策（int8 检测器 DML 建不出会话、自回归解码 DML 负优化、CUDA 未随包，`ocr_inference.dart:60-148`） | §2 方案 B |
| 6 | 只有竖排单行气泡准 | ✅ 真 | RT-DETR 给块级框；跨类（bubble/text_bubble/text_free）不去重（`text_detector.dart:265-266` 只同类 NMS）；每框整框一次识别、不切行/列（`manga_ocr_pipeline.dart:132,139`）；裁框无视长宽比 squish 224×224（`manga_ocr_recognizer.dart:60-90`）；检测输入 640×640 squish 竖版页横向拉 1.9×（`text_detector.dart:40,74-95`）；覆盖层字符命中框按整框均铺（`manga_overlay_html.dart:316-345`） | §2 方案 C |
| 7 | 阅读器本体比 Mihon 薄 | ✅ 真 | 设置面只有方向/默认缩放/灵敏度/翻页动画/边缘点击/音量键（`settings_schema_manga.dart:39-139`）；硬编码：`spreadOffset: 1`（`manga_fushi_page.dart:2068`）、背景黑（`:4406`、`manga_overlay_html.dart:693`）、`TAP_ZONE=0.25` 固定 L/R（`:1315`）；无双击缩放、无底栏 slider、无宽页处理、无裁白边、无章节下载队列 | §2 方案 D |

顺带发现（未改）：`system_ocr_channel.dart:4-6` / `manga_ocr_engine.dart:6-8` 注释宣称 Windows.Media.Ocr / Apple Vision 已接，**原生侧只有 Android ML Kit**；默认 OCR 引擎是 Google Lens（`manga_ocr_engine.dart:32`，会上传页图）。

## 2. 剩余四块的方案

### A. 在线章节懒 OCR（P0，用户第 4 条；07-25 O4 的补完）

阅读器侧**不是**障碍：页图契约本来就是懒的按页内存字节（`MangaReaderSession.page(i)`，`manga_page_provider.dart:39-54`），按页热替换已存在（`_handleWholeVolumeOcrEvent` + JS `__mangaReplaceOcr`，`manga_fushi_page.dart:3311-3340`），磁盘也已是页粒度（`manga_ocr_out/_pages/<sig>/<url>.json`，`manga_ocr_folder_job.dart:161-243`，开书时 `recoverCachedMangaOcr` 合回）。缺口只在服务层没有页级入口，且整卷收尾整份覆写 `manga.json`（`:3370-3387`）。

最小改动（按依赖序）：
1. `manga_ocr_pipeline.dart` 把 `processBook` 的单页处理抽成公开 `processPage(File, {relativeUrl, cacheDir, token})`；`MangaOcrService` 暴露 `ocrPage`（复用同一 ORT 会话，不能每页重建）；`manga_ocr_job_stream.dart` 加接受「页索引流」的 `mangaOcrLocalPageEvents`，事件仍是 `MangaOcrBackgroundEvent.progress(pageIndex, page)`——阅读器零改动。
2. `mihon_online_ocr.dart:93-153` 删「先物化全章再 yield*」，改成与 Lens `_run` 同形的逐页循环：取页 → `_materializePage`（复用 `:335-386`）→ `ocrPage` → 写 `_pages/<sig>/` → emit；失败页留空继续（对齐 `:289-294`），不再一页失败整任务抛。`materializeOnlineMangaPages` 留给「下载离线」。
3. 阅读器 `_primeOnlinePages` 后挂懒调度器：`[cur, cur+1, cur+2]` 中无 blocks 且未扫的页入单工作队列，generation 计数器让翻页/换章作废未开始项；tap-to-OCR 在线分支改为「把该页提到队头」而不是起整卷任务。
4. 落盘：懒结果只写 `_pages/<sig>/`，`manga.json` 在离章/换章/整卷收尾时锁内合并；`_finishWholeVolumeOcr` 从整份覆写改为以逐页缓存为准合并。页级「已扫」标记替换 `:3111-3118` 的卷级判据（否则空白页每点必重跑）。
5. 风险：ORT 单会话不可并发，「2 页并发」只能是下载并发、识别串行且当前页插队；外部 mokuro / 配对主机引擎没有页级接口，按引擎能力分流仍走整章；缓存签名含模型版本；`_pages` 与 `manga.json` 两处真相的合并顺序要有测试；防回归 BUG-1336 的 Lens 对齐测试。

预期：点第 30 页查词从「等全章下载 + 前 29 页识别」变成「等本页一次识别」。

### B. 本地 OCR 提速（P0/P1，用户第 5 条；不换模型）

先量再改：打开 `kOnnxTraceEnabled`（`onnx_inference_ort.dart:193-251` 已有 in/run/out/dispose 分段）在用户机跑一页，连同每框 token 数、每页框数一起记——仓库里**没有任何** Windows app 内的真实计时，只有设计文档用 Python 直连 ORT 的数字（9800X3D beam4 ≈ 2.6 s/页；app 内 macOS M 系 4 框页 2.7 s，说明通道开销把每框拉到 ~640 ms）。

按性价比：
1. **KV cache decoder**：换 optimum `decoder_with_past` 导出，每步只喂 1 个新 token，O(N²) → O(N)。改 `manga_ocr_recognizer.dart` 解码循环 + 模型清单（`manga_ocr_model_manifest.dart:55-75`）+ 缓存签名。这是最大单项。
2. **隐状态常驻 native**：`encoder_hidden_states` 一次 `createOrtValue`、整轮解码复用同一 valueId、最后 dispose（`_OrtOnnxSession.run` 需支持传已建 OrtValue）；decoder 只回传最后位置 logits（导出时切片或 native 切）。去掉每 token 2.4 MB 进 + 整块 logits 出。
3. **快速模式**：贪心解码（`numBeams=1` 现成，设计文档实测 −36%、97.8% 逐字一致）作为「阅读期懒 OCR」默认，整卷预跑保留 beam4。
4. **会话缓存**：补扫/懒 OCR 走服务级常驻 isolate + 会话，别每次点一下重载 460 MB（BUG-2050 也点名了 `manga_region_rescan.dart:118`）。
5. 显式 `intraOpNumThreads` = 物理核数；检测下一页与识别当前页流水线重叠。
6. GPU：Windows 上 fp32 同架构检测器在 DML 快 19.4×（BUG-2050 实测）但 int8 建不出会话——若要吃 GPU，需换 fp32 检测器 + 只对检测器开 DML（识别器留 CPU）。CUDA 要换 ORT 出包变体并随包 CUDA/cuDNN，不建议。

关于 ScreenAI / PP-OCR：ScreenAI 是 Chrome 私有 DLL、不可再分发、依赖用户装 Chrome（07-25 §2 已否决）；PP-OCRv4/v5 日文（DBNet + CTC 非自回归）确实快一个量级，但 rec 吃横排单行，竖排日文靠旋 90° 处理、漫画字体/注音准确率明显低于 manga-ocr（07-24 §5.1「通用 vs 漫画特化 27% vs 70%」量级）。接进 `OcrDetector/OcrRecognizer` 抽象（`ocr_types.dart:185-192`）可行但要动三处契约（`PageDetections.insideBubble` 改可选、清单按引擎、isolate 入口按引擎装配）。**建议先做 1–4，用 trace 证明仍不够快再立项 PP-OCR 作第二本地引擎（快速预览档）**。Windows.Media.Ocr 接入成本低（只需 `fushi/windows/runner/` 加一个 channel handler，下游全现成）但竖排质量预期差，只配当兜底。

### C. 本地 OCR 准确率（P1，用户第 6 条）

1. 跨类重叠框去重（`text_detector.dart:256-277` NMS 扩到跨类，或 `buildPageDetections` 合并 IoU 高的 text_bubble/text_free）。
2. 识别前按投影切行/切块：宽横排框（w/h > 阈值）按水平投影切行逐行识别；超大框先按气泡切块。`reading_order.dart` 只排序不切，需新增。
3. 裁框改 letterbox 保长宽比（与训练分布有偏，需 A/B，可用 `_pages/<sig>/*.json` 与 mokuro 产物对照）。
4. 检测输入改 letterbox（`text_detector.dart:74-95` `preserveAspect=false` → true）。
5. 把 beam 分数暴露成块级「可疑」标记进 manga.json，覆盖层给可疑块不同底色，引导用户框选补扫。
6. 覆盖层多行块的字符命中框按识别文本长度 + 竖排列宽拆行，而不是整框均铺（`manga_overlay_html.dart:316-345`）。

诊断入口：直接看 `<卷目录>/manga_ocr_out/_pages/<签名>/*.json`，一眼分清「框合并/重叠」还是「框对、识别错」。

### D. 阅读器本体补齐（P1，用户第 7 条；对照 Mihon）

正文是 WebView + 注入 JS 手势机（`manga_overlay_html.dart`），Mihon 那些选项要加就得改 JS。按成本排的前 8 项：

| # | 项 | 成本 | 落点 |
|---|---|---|---|
| 1 | 底栏 + 页码 slider + 隐藏界面时常驻页码角标 | 低–中 | 纯 Flutter 层，`_jumpToPage` 与 `_pageNotifier` 已有 |
| 2 | 背景色（黑/白/灰/跟随主题） | 低 | `manga_overlay_html.dart:693` 与 `manga_fushi_page.dart:4406` 两处硬编码改偏好注入 |
| 3 | 双击缩放（fit ↔ 200%） | 低–中 | JS `_end` 加 tap 时序判定，复用 `_zoomAbout` |
| 4 | 跨页偏移 shift + 宽页自动独占 | 中 | `buildMangaSpreads(spreadOffset)` 已参数化（`manga_spread_model.dart:81`）；mokuro 已给每页尺寸，宽页判定不必解码图片；UI 加「偏移 ±1」 |
| 5 | 点击区域布局（L 型/Kindle/上下区）+ webtoon 点击滚动 | 低–中 | `_tapZoneTurn`（`:1315`）改按预设算区域 |
| 6 | 缩放适配模式（fit width/height/original） | 中 | `mangaPageDivHtml` 尺寸公式（`:483-510`）+ 重锚逻辑（BUG-1758/1759 一带敏感，需守卫） |
| 7 | 长按/右键：保存页图、分享、设为封面 | 低–中 | 右键菜单已有入口（`:4269`）；移动端 JS 加长按 |
| 8 | 按章下载队列 + 离线阅读 | 高 | 需新表/队列/作品页 UI；可复用 `MokuroMoeDownloadQueue` 与 reader-cache 身份 |

次级：webtoon 页间距、纵向翻页模式、颜色滤镜/亮度、章节过渡页、OCR 文字显示/手改、裁白边。MAL/AniList 追踪 07-25 §7 已裁定不做。

## 3. 建议的执行顺序（待拍板）

1. **A 懒 OCR**（一个 PR，改 OCR 服务层 + 在线 OCR + 阅读器调度，需 Windows 真机验「点第 N 页只等本页」）。
2. **B-1/2/3/4 提速**（先 trace 出基线，KV cache 导出是独立子任务，可与 A 并行）。
3. **D-1/2/3/5**（四个低成本项一个 PR，纯 UI/JS）。
4. **C-1/2/4 准确率**（需与 mokuro 产物对照的 A/B 基准，单独 PR）。
5. D-4/6/7、B-6 GPU、C-3/5/6、D-8 视前面效果再排。

每项按仓库规则：独立 worktree、bug 文件、根因修复 + 最强可落地层测试、真机复测证据。
