# 漫画功能设计 v2：查词 + 一键制卡 + 准确率优先 OCR + mokuro 支持

- 日期：2026-07-24（v2，OCR 章节按深调研重写；v1 中「复活旧分支」前提已按用户指示移除）
- 状态：**待用户确认**（设计文档，未开始实现）
- 需求原文：漫画功能，要求能查词和一键制卡；OCR 追求准确率；支持提前 OCR 好的漫画；实现时可按难度分派 opus / fable 子代理。
- 用户补充（2026-07-24）：旧数据（2026-06 的 `worktree-manga-mokuro` 分支实现）可不作参考；OCR 要深入调研。

---

## 0. 核心判断（Linus 式）

```text
【核心判断】
✅ 值得做。且比 v1 判断的更值得：本机实测证明 manga-ocr 的 ONNX 端侧化零精度
   损失（beam4 与原版逐字 100% 一致），桌面纯 CPU 整页 2.6s、CUDA 0.56s——
   "app 内置一键 OCR、无 Python 依赖、全链 Apache 许可"是现实的，不是妥协方案。

【关键洞察】
- 数据结构：全功能只有一个核心数据结构——"页图片 + 文字块(box, vertical, lines)"
  （内部 manga.json）。mokuro 文件导入和自带 OCR 是同一结构的不同生产者；
  阅读器、查词、制卡只认这个结构，不知道文字从哪来。零特判。
- 复杂度：准确率优先 ⇒ 识别引擎没有第二个选择（manga-ocr 管线，证据见 §5.1）
  ⇒ 选型复杂度归零，剩下的只是"引擎跑在哪"（app 内置 ONNX / 外部 mokuro CLI /
  互联 host / 云端兜底）——这是部署问题，不是算法问题。
- 风险点：①内置流水线的检测器环节证据强度中等（定性优于 mokuro 现用的 ctd，
  无量化基准）；②手机端整卷 OCR 耗时需真机基准门禁；③手写体是所有本地引擎
  的死穴，只有云端 VLM 能救（可选兜底，默认关）。
```

---

## 1. 背景与现状（2026-07-24 核实）

- develop 已确立「第 N 种书」范式：PDF 走 `EpubBooks.format='pdf'` 列判别（schema v51），复用书架/进度/删除/查词/制卡全管线；`_bookToMediaItem` 按 format 换 `mediaSourceIdentifier` 路由，加新源零 UI 回归。
- 查词/制卡管线现状：`findParagraph` 容器含 `p` 等 13 类标签；`selectText(x,y,maxLength,fromHover)` 四参（可白捡桌面悬停查词）；`onTextSelected` 每 WebView 单点注册；`AnkiMiningContext.coverPath` 传图片文件路径的先例在 `reader_pdf_page.dart:535-555`。
- 同步身份为前缀解析 `'hoshi://book/' + bookKey`（字符串主键，无整数正则限制）。
- 横切能力全部挂在 EpubBooks 上：删除传播/墓碑、互联 `/api/library/books`、云备份、Drive 进度同步、书签、继续阅读。
- 互联 server（`hibiki_sync_server.dart`）有 20+ `/api/*` 端点与 `/api/mine/forward` 转发先例；app 内有 ffmpeg `Process.start` 先例。
- 旧分支 `worktree-manga-mokuro`（本地，tip `46176769a`）有一轮 2026-06 的完整实现（RTL 双页/webtoon 阅读器、覆盖层查词、制卡、~30 测试）。**按用户指示不作为设计前提**；实现期可当代码素材库按需取用（其中经真模拟器验证过的渲染几何/防串框结论在 §4 以设计约束形式独立成立，不依赖旧代码）。

## 2. 总体架构：一个数据结构，N 个生产者

```
生产者（可并存）                          唯一消费合同                    消费者（复用现有管线）
┌────────────────────────────┐                                   ┌──────────────────────┐
│ A. .mokuro 文件导入   (P1) │──┐                                │ MangaHibikiPage       │
│ B. app 内置 ONNX 整卷 (P2) │──┤   manga.json（内部格式）      │  RTL双页 / webtoon    │
│ C. 互联 host 代跑 OCR (P3) │──┼─▶ pages[{url,w,h,blocks[     │  覆盖层查词(hoshi栈)  │
│ D. 单框补扫 / 云端兜底(P4) │──┘     {box,vertical,font_size,  │  onMineFromPopup 制卡 │
└────────────────────────────┘         lines[]}]}]               └──────────────────────┘
```

- **manga.json**（内部私有格式，≠ 原始 .mokuro）：导入端一律归一到它再入库。约定：url 恒正斜杠、保留相对子目录结构（防跨目录同名页互相覆盖）、`lines` 为块内行文本数组（行级坐标可选，见 §5.3）。
- 阅读/查词/制卡代码里**不允许出现「这本是 OCR 来的还是 mokuro 来的」分支**。
- OCR 一律是**导入期/后台批处理**，绝不在翻页路径上跑推理。准确率优先的另一面就是：识别慢没关系，慢在导入时。

## 3. 数据模型：`EpubBooks.format='manga'`（schema v52）

漫画作为「第三种书」，与 PDF 同范式：

- **v52**：`format` 取值域 +`'manga'`；新增一列 `mangaReadingMode TEXT NULL`（null=按页长宽比自动判定 spread/webtoon，非 null=手动覆盖）。除此不加列——blocks 数据在 manga.json 文件里，不进 DB（几万个坐标进 SQLite 是自找的）。
- **进度**：照 PDF——`ReaderPositions.sectionIndex` = 0-based 页码，显式传 `charOffset`（spread 模式传 0；webtoon 用 charOffset 存页内滚动位置整数编码）。书架进度显示 1-based（PDF 教训：0-based 让停第 1 页的书进不了「继续阅读」）。每日统计 charsRead 恒 0。
- **路由**：`_bookToMediaItem` 的 `isPdf` 三元升级为 `format → sourceUniqueKey` 映射表；新源 `MangaHibikiSource`（uniqueKey `'reader_manga'`）。同步身份统一 `hoshi://book/<bookKey>`，无任何漫画特例。
- **免费继承**：删除传播/互联书库列表/云备份/继续阅读/书签。互联 skew 防线：`/api/library/books` 载荷带 format，老客户端对 `'manga'` 行隐藏打开入口。

## 4. 阅读器 / 查词 / 一键制卡

### 4.1 阅读器（`MangaHibikiPage`，WebView 渲染）

- 双形态：**RTL 双页 spread**（每页槽宽 `(100/跨页页数)vw` + aspect-ratio 推高 + `object-fit:contain`，`#manga-viewport{overflow:hidden}` + translateX 只显当前跨页；禁用 `height:100vh` 推宽——竖版页会横向裁切）与 **webtoon 长条**（整书单文档 + `<img loading=lazy>`，滚动只更进度绝不 loadData 重载；键盘方向键在 webtoon 模式 `return ignored` 交给 WebView 原生竖滚）。
- 大卷窗口化加载、图片长按放大、桌面滚轮翻页。

### 4.2 查词

- 每块生成 `<p class="ocr-box">` 透明文字层绝对定位在页图 box 上（用 `<p>` 把选词扫描的 TreeWalker 根框在本气泡内、绝不串邻框）；行间用 `<br>` 不用 `\n`（`\n` 在 `scanDelimiters` 集合里，会把跨行长词拦腰截断）；竖排块 `writing-mode: vertical-rl`。
- 复用 `hoshiSelection.selectText` 全栈：pointerup → `selectText(x,y,40,false)` → `onTextSelected` → 词典弹窗。收敛不变式：manga 页恰好 1 个 handler + 1 个 pointerup 监听，`maxLength` 参数必传（漏传则扫描循环恒假、查词全程哑火），写进契约测试。
- 桌面悬停查词走 `fromHover=true` 路径（与视频字幕 Shift-hover 同交互语言）。
- 句子 = 本块 `lines.join()`——气泡即句子，天然分句边界。

### 4.3 一键制卡

- override `onMineFromPopup` → `AnkiMiningContext`：`sentence`=当前块全文、`documentTitle`=系列+卷名、`coverPath`=**当前页图文件路径**（页图本就在盘上，比 PDF 还省一步栅格化）。可选裁剪（默认整页；裁剪输出无扩展名必须补 `.png`，后端按 `split('.').last` 推扩展名）。
- 当前页图路径在翻页/加载/滚动/模式切换全路径更新（否则封面恒 null）。

## 5. OCR 子系统（深调研版）

### 5.1 识别引擎：manga-ocr，无第二选择（证据链）

| 引擎 | 定量证据 | 结论 |
|---|---|---|
| **kha-white/manga-ocr**（ViT+字符级BERT，**Apache-2.0**，~400MB fp32/111M 参数） | 无官方数字（且 Manga109-s 有训练污染无法同口径比）；全生态默认（mokuro/BallonsTranslator/comic-translate 日语默认全是它）；同口径最强公开数字者也只是「相当」 | **基线正解** |
| PaddleOCR-VL-For-Manga（1B VLM SFT，Apache-2.0） | Manga109-s 10% crop：整句 27%→70%，CER~10% | 数字硬但 1B 太重、无定位、手写照样差；不采用，留作观察 |
| bluolightning/manga-ocr-mobile（10M TFLite，Apache-2.0） | 同口径 CER 7.4%/整句 73% | **移动端候补**，Preview 状态，P4 评估 |
| manga-ocr-base-2025（30M） | 无任何数字 | 🔴 **无 license 不可分发**，出局（可催作者补） |
| 平台 OCR（Apple Vision/OneOCR/ML Kit/Tesseract） | 竖排+艺术字全不及格（Apple 老 API 竖排不出字；ML Kit 裸跑~40%；通用 vs 漫画特化=27% vs 70% 量级） | 出局，**无降级路径** |
| 云端 VLM 整页直喂（GPT-4o/Gemini 2.5F/Claude） | MangaOCR 学术基准（arXiv:2505.20298）端到端 Hmean **全部 0.0**（输出无意义重复） | **禁止整页喂 VLM** |
| 云端 VLM 裁框（Gemini 3.x 级） | 日语手写横评 NLS 0.92（传统 OCR 全崩）；合成竖排 GPT-4.1 CER 18.2 | 印刷体不如 manga-ocr 稳，**手写显著碾压**→ 仅作逐框手动兜底（§5.5） |

### 5.2 本机实测基准（2026-07-24，Ryzen 9800X3D / RTX 5090，manga-ocr 官方测试集）

**关键结论：ONNX + beam4 解码与原版输出逐字 100% 一致（12/12）**——端侧化零精度损失；贪心解码 97.8% 字符级一致（-36% 耗时）。三种执行后端输出零漂移。

| 路径 | 每框识别（中位） | 每页检测 | 整页流水线（8.8 框/页实测均值） |
|---|---|---|---|
| ONNX 纯 CPU，beam4（原版画质） | 246ms | 441ms | **≈2.6s/页**（200 页卷 ≈ 9 分钟） |
| ONNX 纯 CPU，贪心 | 157ms | 441ms | ≈1.8s/页 |
| ONNX CUDA，beam4 | 58ms | 47ms | **≈0.56s/页**（200 页卷 ≈ 2 分钟） |
| 检测 DirectML + 识别 CPU（无 N 卡桌面推荐） | 157ms | 35ms | ≈1.4s/页 |
| 原版 torch CPU（mokuro 路径对照） | 216ms | 2862ms | ≈5.2s/页 |

坑（实现时照抄）：DirectML 对自回归解码是**负优化**（比 CPU 慢 50%），但检测器大卷积快 25 倍——无 CUDA 桌面正确取舍是「检测 DML、识别 CPU」；decoder 无 KV cache 时长句线性变慢；手机 CPU 按 3–5 倍折扣估算：单框 0.5–0.8s、整页 5–10s、整卷 17–33 分钟（后台任务量级，**真机基准是 P4 门禁**）。

### 5.3 生产者矩阵

**A：`.mokuro` 文件导入（P1，主路径）**
吃 mokuro v0.2+ 单文件格式（schema 已从源码核实：`pages[{img_path,img_width,img_height,blocks[{box,vertical,font_size,lines_coords,lines}]}]`）→ 归一 manga.json → 入库 `format='manga'`。旧版单 HTML legacy 不支持（生态存量都是新格式，mokuro.moe 约 830GB/数千卷）。这一条独立满足「支持提前 OCR 好的漫画」。

**B：app 内置 ONNX 整卷 OCR（P2，桌面先行）——本设计核心增量**
用户丢进裸图片文件夹/压缩包（无 .mokuro）→ app 内一键 OCR，无 Python、无外部依赖：

- 识别：manga-ocr ONNX（mayocream 导出，encoder 328MB + decoder 113MB，Apache-2.0），**beam4 解码**保证与 mokuro 产出同质量（实测 100% 对齐）；模型按需下载（设置里显式触发，不随包，走用户代理配置）。
- 检测：**ogkalu/comic-text-and-bubble-detector**（RT-DETR-v2，**Apache-2.0**，int8 ONNX 仅 11MB；koharu 默认、月下载 42k+；定性证据复杂场景优于 mokuro 现用的 GPL comic-text-detector）。它只给块级框不给行级坐标——**可接受**：manga-ocr 本就整块多行一次识别，查词命中目标是块级 `<p>`；块内行拆分用识别文本 + 竖排列宽启发式仅供覆盖层排版，不需要几何行框。
- 阅读顺序：几何启发式（面板聚类 + 面板内右上→左下 RTL 排序），够多数版式。
- 执行后端：Windows 有 N 卡走 CUDA EP，否则「检测 DML + 识别 CPU」；macOS 走 CoreML/CPU EP。绑定用 `flutter_onnxruntime`（五平台，活跃维护）。
- **整条链 Apache-2.0，无 GPL、无 Python**。产出归一 manga.json，与 A 无差别。
- 逐页断点缓存（对齐 mokuro `_ocr/` 语义）：中断重跑只补未完成页。

**B'（后备）：外部 mokuro CLI 子进程**
追求与 mokuro 逐比特同产物（含 ctd 行级坐标）的专业用户走外部工具模式：探测顺序 设置指定 → `HIBIKI_MOKURO` 环境变量 → PATH（与 `HIBIKI_FFMPEG` 同模式），子进程跑 `mokuro --disable_confirmation`，GPL 零传染。**不打包 Python 环境**。B 落地后 B' 只是设置页里一个可选项，优先级低。

**C：互联 host 代跑 OCR（P3）**
手机端对裸漫画发起 OCR → 转发已配对桌面 host。**因为 B 是 app 内置的，host 端零额外依赖**（就是桌面 Hibiki 自己跑 B），这比 v1 设计（host 装 mokuro）简化了一整层。端点沿现有风格：`POST /api/ocr/job`（上传卷图或引用 host 已有路径）→ `GET /api/ocr/job/<id>` 进度 → 完成拉 manga.json。job 串行单并发、可取消、断点续传复用 B 的逐页缓存；能力协商走 `/api/capabilities`，老 host 隐藏入口。

**D：单框补扫 + 云端手写兜底（P4）**
- 端侧单框：阅读中对漏识别/识别错的气泡**手动框选** → B 的识别链（单框免检测器）→ 立即查词/制卡，并回写本页 manga.json（下次直接查）。手机端单框 0.5–0.8s 估算完全可用；这也是移动端内置 OCR 的第一落点（整卷视 P4 真机基准再定）。
- **云端 VLM 手写兜底（可选，默认关）**：手写体是所有本地引擎的死穴（manga-ocr 作者自认、1B 微调模型照样差评），而云端 VLM 手写显著更强（NLS 0.92）。做成**逐框、手动触发**的「云端重试」按钮（用户框选 → 裁图上 Gemini 级 API → 返回文本），明示隐私（该框图片上云）与 API key 自备。**不做自动置信度路由**——manga-ocr 是生成式解码无天然置信度，自动路由是社区空白 + 会把隐私决定权从用户手里拿走。成本可忽略（逐框几百 token）。
- 移动端整卷候补引擎：manga-ocr-mobile（10M，CER 7.4%）到 P4 时重新评估其成熟度。

### 5.4 许可证矩阵（分发视角）

| 组件 | 许可证 | 进 app？ |
|---|---|---|
| manga-ocr 模型/ONNX 导出 | Apache-2.0 | ✅ 按需下载 |
| ogkalu RT-DETR 检测器 | Apache-2.0 | ✅ 按需下载（11MB） |
| flutter_onnxruntime / ONNX Runtime | MIT | ✅ 随包 |
| mokuro / comic-text-detector / manga-image-translator 系 | GPL-3.0 | ❌ 只以外部子进程存在（B'） |
| manga-ocr-base-2025 | 无 license | ❌ 出局 |
| magi/magiv2 | 非商用 | ❌ |
| Google Lens 逆向端点 | 违反 ToS/无 SLA | ❌ 不依赖 |

### 5.5 刻意不做

- 翻页实时 OCR（复杂度爆炸，批处理已覆盖）。
- 整页喂 VLM（基准 Hmean 0.0，实锤灾难）。
- 平台 OCR 降级路径（准确率不及格，做了反而毁口碑）。
- 自动置信度云端路由（无置信度信号，隐私不可默认让渡）。
- 自己微调模型（管线全公开、消费级卡可跑，是**未来可选项**而非本期范围）。

## 6. 分阶段计划与子代理分工

每阶段独立 worktree + 独立 PR + 真机门禁（Android 模拟器 + Windows 离屏，焦点驱动）。难度分派：**fable = 架构/ONNX 流水线/协议/几何，opus = 机械实现/UI/测试/i18n**。

| 阶段 | 内容 | 分派 | 出口条件 |
|---|---|---|---|
| P0 | 用户拍板 §8 未决问题 | — | 拍板 |
| P1 | 基座：v52 迁移 + `format='manga'` + MangaHibikiSource/Page（阅读器双形态）+ .mokuro 导入 + 覆盖层查词 + 制卡 + i18n + 测试 | fable（DB/路由/渲染几何/查词接线）+ opus（导入对话框/i18n/测试）；旧分支代码可按需取材 | analyze 0 + 测试绿 + 真机：导入 .mokuro→书架→双形态阅读→查词不串框→制卡带页图 |
| P2 | 内置 ONNX 整卷 OCR（桌面）：模型下载管理 + 检测/识别/排序流水线 + beam4 解码 + 逐页缓存 + 导入向导进度 UI | fable（流水线/解码/EP 选择）+ opus（下载管理/UI） | 真 Windows 裸文件夹一键 OCR→与 mokuro 产物人工对照抽查→可查词制卡 |
| P3 | 互联 `/api/ocr` job + B'（外部 mokuro 可选项） | fable（协议/队列）+ opus（B' 探测与设置项） | 手机发起→host 跑→回流可读可查 |
| P4 | 单框补扫（含移动端）+ 云端手写兜底（默认关）+ 手机整卷真机基准评估 | fable（单框链/基准）+ opus（框选 UI/云端开关） | 真机框选→识别→查词/制卡闭环；基准报告定移动整卷去留 |

## 7. 风险台账

- **R1 检测器证据强度**：ogkalu 优于 ctd 只有定性证据（截图对比 + koharu 默认），无量化。缓解：P2 出口条件含与 mokuro 产物的人工抽查对照；若召回明显差，退回 B' 外部 mokuro 为主。
- **R2 手机整卷耗时**：桌面数字×3–5 折扣是估算，真机基准（P4）前不对移动整卷做承诺。
- **R3 手写体**：本地引擎极限，UI 如实标注；云端兜底可选。
- **R4 模型下载体积**（~450MB）：按需显式下载 + 走用户代理设置；提供「仅桌面下载，手机走互联」的默认姿势。
- **R5 阅读顺序启发式**：复杂版式会错序（只影响整页导出/上下文，不影响单块查词）；magi 级模型因许可证与体积不引入。
- **R6 大卷内存/渲染**：窗口化 + lazy-load 设计已覆盖，真机复测横屏平板与千页卷。

## 8. 未决问题（P0 需用户拍板）

1. **P2 主路径确认**：app 内置 ONNX 整卷 OCR 为主、外部 mokuro CLI 降为可选后备——OK？（v1 是反过来的，实测数字支持翻转）
2. **移动端整卷 OCR**：接受「P4 真机基准后再定去留」，还是现在就砍掉只留互联（P3）+ 单框（P4）？
3. **云端 VLM 手写兜底**（逐框、手动、默认关、自备 key）：要不要进 P4 范围？
4. `format='manga'`（v52）+ 旧 HTML legacy 不支持：确认。

## 9. 调研出处（关键项）

识别：kha-white/manga-ocr（GitHub/HF，Apache-2.0）；jzhang533/PaddleOCR-VL-For-Manga（HF 卡 + pfcc.blog，27%→70%）；bluolightning/manga-ocr-mobile（HF，CER 7.4%）；manga-ocr-base-2025 无 license（HF discussion #1）。检测：dmMaze/comic-text-detector（GPL，可靠性差评 manga-image-translator #710）；ogkalu/comic-text-and-bubble-detector（HF，Apache-2.0，BallonsTranslator #867 定性对比，koharu 默认）。VLM：MangaVQA/MangaLMM（arXiv:2505.20298，整页 Hmean 0.0）；竖排 MLLM 评测（arXiv:2511.15059）；日语手写 23 模型横评（nyosegawa.com，Gemini NLS 0.92）。生态：owocr/YomiNinja/BallonsTranslator/comic-translate 引擎矩阵；LazyGuideJP 工作流；mokuro.moe ~830GB；Google Lens 逆向端点（chrome-lens-ocr）ToS 风险；云端成本（Cloud Vision ~$0.30/卷、Gemini Flash-Lite ~$0.03/卷、GPT-4o-mini 图像 33× 乘数陷阱）；ente mobile_ocr（PaddleOCR v5 on ORT Mobile 端侧先例）。本机实测：2026-07-24 于 Ryzen 9800X3D/RTX 5090，manga-ocr 官方 12 测试样张 + 6 整页，脚本与复现命令存 job tmp（`bench_ocr*.py`/`bench_detector*.py`）；ONNX beam4 12/12 逐字对齐原版。格式：mokuro v0.2.5 源码（mokuro_generator.py / manga_page_ocr.py）。未找到确凿来源的项（不作承诺依据）：manga-ocr 官方 CER、ogkalu 量化基准、漫画手写字专项基准、mokuro 官方每页耗时。
