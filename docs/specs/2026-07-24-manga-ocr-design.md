# 漫画功能设计：mokuro 预处理 + 准确率优先 OCR + 查词 + 一键制卡

- 日期：2026-07-24
- 状态：**待用户确认**（设计文档，未开始实现）
- 需求原文：漫画功能，要求能查词和一键制卡；OCR 追求准确率；支持提前 OCR 好的漫画；实现时可按难度分派 opus / fable 子代理。
- 前置资产：本地分支 `worktree-manga-mokuro`（tip `46176769a`，13 提交，68 文件 +13570 行，含 2026-06-05 设计 rev3 + 30 任务计划 + ~30 个测试文件，**已 code-complete 但从未落 develop、从未真机验收**）。
- 关联：`docs/specs/2026-06-05-manga-mokuro-support-{design,plan}.md`（在旧分支上）。

---

## 0. 核心判断（Linus 式）

```text
【核心判断】
✅ 值得做：查词+制卡管线、书架路由、"第 N 种书"范式全部现成；旧分支已把阅读器
   +查词+制卡整条链写完并带测试。真正的新工作只有两块：①把旧资产按 4942 提交
   后的 develop 现实重放落地；②补一个"OCR 生产端"。

【关键洞察】
- 数据结构：全功能只有一个核心数据结构——"页图片 + 文字块(box, vertical, lines)"。
  mokuro 文件导入和自带 OCR 不是两条链路，是同一结构的两个生产者。阅读器、
  查词、制卡只认这个结构，不知道文字从哪来。
- 复杂度：准确率优先 ⇒ OCR 必须用 manga-ocr 管线（调研见 §5，平台 OCR 全不及格
  且差距是 27% vs 70% 量级）⇒ OCR 是重活 ⇒ 必须是导入期批处理，不是翻页实时
  识别。这一刀砍掉了"阅读时 OCR"的全部状态机复杂度。
- 风险点：①旧分支的独立 MangaBooks 表与 develop 已落地的 PDF "format 列"范式
  分叉（§3，本设计推荐改走 format 列，需要用户拍板）；②comic-text-detector
  GPL-3.0 的端侧分发合规（§5.4）；③manga-ocr 端侧推理速度无公开基准（先 spike）。
```

---

## 1. 背景与现状盘点（2026-07-24 核实）

### 1.1 旧分支资产（`worktree-manga-mokuro`，未 push、develop 零落地）

13 提交按层组织，全部健在：

| 层 | 内容 | 可复用度 |
|---|---|---|
| L1 | `MangaBooks` 表 + v16 迁移 + DAO | ⚠️ 需按 §3 决策重写（schema 已 v51，且范式分叉） |
| L2 | `MokuroPayload` + `parseMokuro` + 阅读形态/spread 模型 | ✅ 近乎原样搬 |
| L3 | mokuro 覆盖层 HTML 生成器 + 扫描契约测试 | ✅ 近乎原样搬 |
| L4 | `MangaStorage` + importer + 导入对话框 | ✅ 主体搬，落库端对齐 §3 |
| L5 | `MangaHibikiSource` + 书架分区 + openMedia 路由 | ⚠️ 按 PDF 范式重写（书架页 develop 已改 130 次） |
| L6 | `MangaHibikiPage`（+1023 行：拦截器/窗口化/进度/缩放） | ✅ 主体搬 |
| L7 | 查词接线 + Anki 制卡 | ✅ 主体搬，适配 §1.2 的管线演化 |
| — | 9 个 `manga_*` i18n key ×17 语言 | 🔁 用 `i18n_sync.dart` 重放，不手 merge |
| — | ~30 个测试文件（含 2 个焦点驱动 integration_test） | ✅ 搬 + 适配 |

### 1.2 develop 侧关键事实（相对旧分支 base 漂移 4942 提交）

- **PDF PR#352 已合入**：`EpubBooks.format` 列（默认 `'epub'`）、`reader_pdf_page.dart`、`_bookToMediaItem` 按 format 换 `mediaSourceIdentifier` 路由（`reader_hibiki_source.dart:505,543`）。"第 N 种书"范式是既成事实，路由只认 `mediaSourceIdentifier`，加新源零 UI 回归。
- schema 现为 **v51**（旧分支硬写 v16 非法，需重编号 v52）。
- 查词管线演化（全部利好）：`findParagraph` 容器扩到 13 类标签（`<p class="ocr-box">` 约束依然成立且更稳）；`selectText` 变四参 `(x,y,maxLength,fromHover)`——漫画页可白捡桌面悬停查词；`onTextSelected` 仍是每 WebView 单点注册。
- `_bookIdPattern` 正则已死，现为前缀解析 `'hoshi://book/' + bookKey`（字符串主键）。旧分支为躲它而设的 `manga://` 特例，其"存在理由"已经变了（见 §3）。
- 制卡：`AnkiMiningContext.coverPath` 健在；PDF 页 `onMineFromPopup` 传当前页 PNG 路径（`reader_pdf_page.dart:535-555`）是可直接照抄的先例。
- 互联 server（`hibiki_sync_server.dart`）已有 20+ `/api/*` 端点与 `/api/mine/forward` 异地转发先例；app 内有 ffmpeg `Process.start` 子进程先例（`ffmpeg_backend.dart:305`），但 server 端点尚无子进程调用。
- 新增的横切能力都挂在 EpubBooks 上：删除传播/墓碑（PR#346）、互联 `/api/library/books`、云备份、Drive 进度同步、书签、继续阅读。**这是 §3 决策的最大砝码。**

---

## 2. 总体架构：一个数据结构，N 个生产者

```
生产者（互斥可并存）                    唯一消费合同                     消费者（全复用）
┌─────────────────────────┐                                    ┌──────────────────────┐
│ A. .mokuro 文件导入(P1) │──┐                                 │ MangaHibikiPage       │
│ B. 桌面 mokuro 子进程(P2)│──┤    manga.json（内部格式）      │  RTL双页 / webtoon    │
│ C. 互联 host 代跑 OCR(P3)│──┼──▶ pages[{url,w,h,blocks[     │  覆盖层查词(hoshi栈)  │
│ D. 端侧单框补扫 ONNX(P4) │──┘      {box,vertical,font_size,  │  onMineFromPopup 制卡 │
└─────────────────────────┘          z_index,lines[]}]}]       └──────────────────────┘
```

- **manga.json 是旧分支已定义并已实现解析/生成的私有格式**（≠ 原始 .mokuro；`parseMangaJson` 读，importer 写；url 恒正斜杠、保留相对子目录结构防跨目录同名覆盖——旧分支载入坑照单全收）。
- 生产者 A~D 的输出全部归一到 manga.json 后入库。**阅读/查词/制卡代码里不允许出现任何 "这本是 OCR 来的还是 mokuro 来的" 分支**——好代码没有特殊情况。
- OCR 一律是**导入期/后台批处理**产出落盘文本，绝不在翻页路径上跑推理。准确率优先的另一面就是：识别慢没关系，慢在导入时。

## 3. 数据模型决策：`EpubBooks.format='manga'`（推荐，需用户拍板）

旧分支选了独立 `MangaBooks` 表；这 49 天里 develop 用 PDF 确立了相反范式。两者只能活一个：

| | A. 独立 MangaBooks（旧分支现状） | B. `format='manga'`（本设计推荐） |
|---|---|---|
| 旧资产改动 | L1/L5 白捡 | L1/L5 重写（约 2~3 天当量） |
| 删除传播/墓碑 | 平行再实现一整套 | **免费继承** |
| 互联书库列表/云备份/Drive 进度 | 平行再实现 | **免费继承** |
| 继续阅读/书架/书签/统计 | 平行接线 | **免费继承**（PDF 已趟平页码型进度） |
| 未来每个新横切功能 | 永久性"别忘了 manga 表"特例 | 无特例 |
| 同步身份 | `manga://book/<id>` 特例前缀 | 统一 `hoshi://book/<bookKey>`，特例消失 |

**推荐 B。** 旧分支设 `manga://` 前缀只为躲当年 `_bookIdPattern=(\d+)` 的误匹配；那个正则已经死了，书键现在就是字符串。用 B，"漫画同步身份"这个特殊情况整个蒸发——这正是"重写让特殊情况消失"的教科书案例。代价是旧 L1/L5 重写，但 L1 本来就因 v16→v52 必须动，L5 本来就因书架页漂移 130 次必须动：**要重写的层和必须重写的层完全重合，实际多付的成本≈0。**

落地细节：
- **schema v52**：不新建表。`EpubBooks.format` 取值域 +`'manga'`；新增一列 `mangaReadingMode TEXT NULL`（null=自动判定，`'spread'`/`'webtoon'` 为手动覆盖）。页数复用现有章节数语义列，页图目录路径复用现有书文件路径列（导入时指向 `MangaStorage` 卷目录）。除此之外**不加列**——blocks 数据在 manga.json 文件里，不进 DB（几万个坐标进 SQLite 是自找的）。
- **进度**：照抄 PDF——`ReaderPositions.sectionIndex` = 0-based 页码，**显式传 `charOffset`**（PDF 传 0；webtoon 用 charOffset 存卷内滚动位置的整数编码，如页内千分比，恢复精度旧分支已验 <4px）。书架进度显示用 1-based（PDF 教训：0-based 让停第 1 页的书进不了"继续阅读"）。每日统计 charsRead 恒 0（页数绝不塞字数口径）。
- **路由**：`_bookToMediaItem` 的 `isPdf` 三元改为按 format 查表映射 `format → sourceUniqueKey`（epub/pdf/manga 三态后，if-else 该升级成映射了）。`MangaHibikiSource` 新 uniqueKey `'reader_manga'`。
- **互联 skew 防线**：`/api/library/books` 载荷带上 format 字段；老版本客户端对 `format=='manga'` 行不显示打开入口（防旧客户端拿 manga 行当 EPUB 打开）。

## 4. 查词与一键制卡（复用旧分支，按管线现状适配）

### 4.1 查词

- 每页覆盖层：块生成 `<p class="ocr-box">`（**不是 div**——虽然 develop 的 `BLOCK_SELECTOR` 已扩容包含 div，`<p>` 语义仍是把扫描 TreeWalker 根框在本气泡内、绝不串邻框的最稳选择），行间 `<br>`（**不是 `\n`**——`\n` 在 `scanDelimiters` 集合里，会把跨行长词拦腰截断）。文字透明、绝对定位在页图对应 box 上；竖排块 `writing-mode: vertical-rl`。
- 复用 `hoshiSelection.selectText` 全栈：pointerup → `selectText(x,y,40,false)` 三/四参 → `onTextSelected`（漫画页自己的 WebView 单点注册，与 reader 页互不干扰）→ 词典弹窗。**收敛不变式**：manga 页恰好 1 个 `onTextSelected` handler + 1 个 pointerup 监听，漏 `maxLength` 参数会让扫描循环恒假、查词全程哑火（旧分支血泪，写进契约测试）。
- 新增机会（P2 顺手做）：`fromHover=true` 路径接桌面悬停查词，与视频字幕 Shift-hover 同交互语言。
- 句子来源 = 本块 `lines.join()`（气泡即句子，天然的分句边界，比 EPUB 的启发式分句还干净）。

### 4.2 一键制卡

- 照抄 PDF 先例：override `onMineFromPopup` → `AnkiMiningContext`，其中 `sentence` = 当前块全文，`documentTitle` = 系列名+卷名，`coverPath` = **当前页图文件路径**（页图本来就在盘上，连 PDF 的栅格化步骤都省了；非 PNG/JPG 的页格式导入时已归一）。裁剪可选：默认整页，弹裁剪器输出无扩展名文件必须补 `.png`（后端按 `split('.').last` 推扩展名）。
- `_updateCurrentPageImagePath` 在翻页/加载/滚动/模式切换全路径调用（旧分支修过"封面恒 null"的坑，测试跟着搬）。
- 单词音频/发音走既有制卡管线不动；`{card-image}` 三别名校验（BUG-1021）已在 develop，无需特判。

## 5. OCR 子系统（准确率优先的落点）

### 5.1 选型结论（2026-07-24 真调研，出处存 §8）

| 引擎 | 漫画准确率 | 结论 |
|---|---|---|
| **manga-ocr**（ViT+字符级BERT，MIT，444MB fp32；mokuro 管线 = comic-text-detector 检测 + manga-ocr 识别） | 事实标准：竖排/furigana/艺术字/叠图特化；弱点：手写体、空白幻觉 | **唯一选择** |
| Windows OneOCR / Apple Live Text | 通用引擎里最好，无漫画特化；OneOCR 还需逆向抽 DLL 不可分发 | 否 |
| ML Kit 日语 | 漫画裸跑 ~40%，竖排要自己旋转预处理 | 否 |
| Tesseract jpn_vert | <30%，社区一致差评 | 否 |

定量佐证：通用 PaddleOCR-VL 在 Manga109-s 整句 27%，漫画微调后 70%——**"准确率优先"直接排除全部平台 OCR，没有降级路径**（降级=毁掉查词体验）。

### 5.2 生产者 A：`.mokuro` 文件导入（P1，旧分支已实现）

- 吃 mokuro **v0.2+ 单文件格式**（`{version,title,volume,title_uuid,volume_uuid,pages[]}`，页含 `img_path/img_width/img_height/blocks[{box,vertical,font_size,lines_coords,lines}]`；schema 已从 mokuro 源码逐字段核实）。旧版单 HTML legacy 维持不支持（YAGNI，与 2026-06-05 决策一致；mokuro.moe 生态存量都是新格式）。
- 导入 = 图片目录 + `.mokuro` → `parseMokuro` → manga.json + 拷图入 `MangaStorage` → 落库 `format='manga'`。
- 这一条独立满足"支持提前 OCR 好的漫画"，且直接超过 jidoujisho（它只吃旧 HTML，新格式 issue 挂了两年没人理）。

### 5.3 生产者 B：桌面"一键 OCR"= 外部 mokuro 子进程（P2）

- 用户丢进来**裸图片文件夹/压缩包**（无 .mokuro）时，桌面端提供一键 OCR：app 以子进程跑 `mokuro --disable_confirmation <dir>`，解析 stdout 进度条驱动 UI 进度，产物 `.mokuro` 回流生产者 A 同一条导入链。
- 引擎发现顺序：设置里指定路径 → `HIBIKI_MOKURO` 环境变量 → PATH 探测（与 `HIBIKI_FFMPEG` 同一模式）。未装则弹安装引导（一行 `uv tool install mokuro` / `pipx install mokuro` + "检测"按钮；Windows 提示别用 Store Python——fugashi DLL 已知坑）。
- **GPL-3.0 零传染**：独立进程 + 官方 CLI 界面，不链接不打包。CPU 可跑（`--force_cpu`），有 CUDA 自动提速；mokuro 自带 `_ocr/` 每页缓存，中断重跑天然续传。
- 明确不做：把 Python 环境打包进 app（体积/维护深渊，解决的是不存在的问题——目标用户装个 uv 不是门槛）。

### 5.4 生产者 C：互联 host 代跑 OCR（P3）

手机端没有 mokuro 也想 OCR 裸漫画 → 转发给已配对桌面 host（与"制卡到服务端"同哲学）：

- 新端点（沿用现有风格）：`POST /api/ocr/job`（上传卷图片或引用 host 侧已有路径）→ `GET /api/ocr/job/<id>`（进度轮询，host 端仍是 §5.3 的子进程跑）→ 完成后拉回 `.mokuro` 走生产者 A。
- server 端首次引入子进程调用（app 内 ffmpeg 先例在，server 面是新的）：job 队列串行、单并发、可取消、断电续传靠 `_ocr/` 缓存。
- 能力协商走 `/api/capabilities`，老 host 无此端点即隐藏入口（版本 skew 零破坏）。

### 5.5 生产者 D：端侧单框补扫（P4，可选，先 spike）

- 场景：预处理漏识别的气泡、手写体重试、或对页面任意区域临时查词。**不做端侧整卷 OCR**（440MB 模型 × 200 页 × 未知速度 = 解决不存在的问题；整卷有 B/C）。
- 路径：`flutter_onnxruntime`（五平台，4 天前还在发版）+ manga-ocr ONNX（mayocream 导出，encoder 328MB + decoder 113MB，**MIT**）。**用户手动框选气泡**→识别→立即弹词典/制卡，并可回写进本页 manga.json（补一个 block，下次直接查）。
- 手动框选同时解决两件事：①绕开 comic-text-detector（**GPL-3.0**，端侧内置有合规疑问）；②消灭 manga-ocr 的空白幻觉面（用户框哪识哪）。
- 模型按需下载（设置里显式触发，不随包），int8 量化收益需自测（老 CPU 可能反而慢）。**先做 spike 出推理耗时基准，速度不可接受就砍掉 P4，不硬上。**（无任何移动端 manga-ocr 先例，这是全新地形。）

## 6. 阅读器（旧分支整体继承，不变式清单）

以下是旧分支三轮审查 + 真模拟器验证淬出的不变式，重放时逐条保真（各有契约测试）：

1. **spread 几何**：每页槽宽 `(100/跨页页数)vw` + aspect-ratio 推高 + `object-fit:contain`；`#manga-viewport{overflow:hidden;height:100vh}` + translateX 只显当前跨页。**禁用 `height:100vh` 推宽**（竖版页横向裁切的 CRITICAL 回归）。
2. **webtoon**：整书单文档 + `<img loading=lazy>`；滚动只更进度**绝不 loadData 重载**；键盘方向键在 webtoon 模式 `return ignored` 让 WebView 原生竖滚。
3. RTL 双页翻页方向、桌面滚轮翻页、原生拖拽残影抑制（BUG-051 修复提交）、图片长按放大、窗口化 `_loadedSpreads`。
4. 形态判定：按页长宽比自动 spread/webtoon + `mangaReadingMode` 手动覆盖。

## 7. 分阶段计划与子代理分工

每阶段独立 worktree + 独立 PR + 真机门禁（Android 模拟器 + Windows 离屏，焦点驱动）。按用户要求，难度分派：**fable = 架构/集成/协议/几何等硬活，opus = 机械重放/文案/测试搬运**。

| 阶段 | 内容 | 分派 | 出口条件 |
|---|---|---|---|
| P0 | 用户拍板 §3 数据模型 + §7 未决问题 | — | 拍板 |
| P1 | 旧分支重放落 develop：L2/L3/L4/L6/L7 文件搬运+适配（opus）；L1 按 v52+format 重写、L5 书架/路由/app_model 集成、同步身份统一（fable）；i18n 用 `i18n_sync` 重放 + slang；~30 测试重放 | fable 主导 + opus 并行 | analyze 0 + 全测试绿 + **真机**：导入 .mokuro→书架→RTL 双页/webtoon→查词不串框→制卡进 Anki 带页图 |
| P2 | 桌面 mokuro 外部工具：探测/安装引导/子进程/进度/回流导入链 | opus（stdout 协议解析部分 fable 把关） | 真 Windows 裸文件夹一键 OCR→可查词 |
| P3 | 互联 `/api/ocr` job：端点/队列/传输/续传/capabilities 协商 | fable | 手机发起→host 跑→回流→手机可读可查 |
| P4 | 端侧单框补扫：**先 fable spike 出 ONNX 推理基准**（不达标即砍），达标后 opus 做框选 UI + 回写 | fable spike → opus | 真机框选→识别→查词/制卡闭环 |

## 8. 风险台账与未决问题

风险：
- **R1 重放漂移**（4942 提交）：策略=纯新文件搬运 + 集成层重写，绝不对 `database.g.dart`/`strings.g.dart` 手 merge（重跑 build_runner / i18n_sync+slang）；`docs/BUGS.md` 已迁"一 bug 一文件"，旧分支那 7 行手加正文丢弃。
- **R2 GPL**：mokuro/检测器 GPL-3.0——B/C 子进程隔离干净；D 只带 MIT 识别模型 + 手动框选，绕开检测器。
- **R3 端侧速度未知**：P4 spike 前置，无公开基准不承诺。
- **R4 手写体**：manga-ocr 引擎极限，如实标注"手写文本识别率低"，不伪装能解。
- **R5 大卷内存**：旧分支窗口化已处理，真机复测横屏平板 + 大卷。

未决问题（P0 需用户拍板）：
1. **§3 数据模型**：接受 `format='manga'` 统一（推荐，代价=旧 L1/L5 重写）还是保独立 MangaBooks（代价=横切功能永久平行接线）？
2. **阶段优先级**：P2（桌面一键 OCR）与 P3（互联代跑）顺序可对调，按你的主用设备定。
3. **P4 端侧补扫**：要不要（可整个砍掉，P1-P3 已闭环）？
4. 旧 mokuro 单 HTML legacy 格式维持不支持，确认？

## 9. 调研出处（关键项）

mokuro v0.2.5（2026-07-20 发版，GPL-3.0）：github.com/kha-white/mokuro（schema 读自 `mokuro_generator.py` / `manga_page_ocr.py` 源码）；manga-ocr（MIT，444MB fp32）：github.com/kha-white/manga-ocr + HF `kha-white/manga-ocr-base`；ONNX 导出：HF `mayocream/manga-ocr-onnx`（encoder 328MB + decoder 113MB，消费先例 manga-ocr-rs）、`mayocream/comic-text-detector-onnx`（94.7MB，上游 GPL-3.0）；Dart 绑定：pub.dev `flutter_onnxruntime`（masic.ai，v1.8.3）；平台 OCR 竖排失效：Apple 论坛 thread/772972、749234；ML Kit 竖排实践：dev.to（~40%→85% 需自旋转）；定量差距：HF `jzhang533/PaddleOCR-VL-For-Manga`（27%→70%）；jidoujisho 新格式缺口：issue #416；生态：reader.mokuro.app、mokuro.moe。未找到确凿来源的项（不作承诺依据）：manga-ocr 官方 CER、端侧 CPU 每框耗时、mokuro CPU 每页耗时基准。
