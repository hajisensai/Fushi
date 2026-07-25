# 漫画在线源设计：Mangatan 对齐差距分析 + 在线阅读 + 阅读期 OCR

> 起因：用户指令「https://github.com/1Selxo/Mangatan 漫画抄一下这个」。
> 本文 = ① Mangatan 全量调研结论 ② 与 Hibiki 现有漫画栈（develop `de5103250`，2026-07-24 设计 v2 已落地）的差距矩阵 ③ 唯一真差距「在线源 + 阅读期 OCR」的路线设计 ④ 待用户拍板的 P0 问题。
> ⚠️ Mangatan 是 GPL-3.0，**任何代码不得搬运**；只抄功能与交互设计，几何启发式按思路重写。

## 0. 核心判断（Linus 式）

【核心判断】
✅ 值得做，但范围要砍到只剩真差距：**在线漫画源 + 阅读期懒 OCR**。

- Mangatan 的查词/制卡/OCR 覆盖层，Hibiki **已经全有且更强**（见 §2 矩阵）——这部分「抄」是在解决不存在的问题。
- Mangatan 真正做到而 Hibiki 没有的只有一件事：**打开一部没预处理过的在线漫画，边读边 OCR，点字查词制卡**。
- 数据结构上这不是新系统：页面图 bytes → 现有 ONNX 流水线 → 现有 manga.json blocks 合同 → 现有覆盖层/查词/制卡。**新增的只有「bytes 从哪来」（在线源客户端）和「什么时候扫」（阅读期懒 OCR + 磁盘缓存）两个生产者接口。**
- 风险点：在线源的路线选择（§4）决定 90% 的工作量和长期维护成本，必须先拍板再动工。

## 1. 最重要的调研发现：Mangatan 和 Hibiki 是「同门」

Mangatan（1Selxo/Mangatan，Mangayomi fork，Dart，GPL-3.0，69★，2026-07 活跃）的词典栈不是自研：

- `third_party/hoshidicts`（git submodule）= **Manhhao/hoshidicts** —— 与 Hibiki `native/hoshidicts/` 是同一个上游 C++ 引擎，连 C ABI 符号（`hoshidicts_import_dictionary_json` / `hoshidicts_lookup_json` / `hoshidicts_get_media_file`）都同一套，只是它经 flutter_rust_bridge 包了层 Rust（`rust/src/api/hoshidicts.rs`）。
- `assets/hoshi_popup/` = vendored 的 **Hoshi-Reader** 弹窗渲染器（popup.js/popup.css/selection.js），README 明确署名。

即 **Mangatan ≈ Mangayomi（在线漫画/动画聚合阅读器）+ Hibiki 同款词典引擎 + OCR overlay + AnkiConnect**。它验证了「hoshidicts 栈 + 漫画 OCR + 制卡」这条路线的市场需求，但在词典/OCR/制卡侧对 Hibiki 没有增量知识——增量全在「在线内容」侧。

## 2. 差距矩阵（Hibiki develop vs Mangatan main@9e3b366）

| 能力 | Hibiki（已落 develop） | Mangatan | 差距结论 |
|---|---|---|---|
| 词典引擎 | hoshidicts C++ 深度 fork，直连 FFI | 同引擎，经 Rust FRB 包一层 | 无差距（同门） |
| 弹窗渲染 | hoshi 栈 WebView + 全局/嵌套查词 | Hoshi-Reader popup.js，单例屏外 prewarm | 无功能差距；prewarm 思路可备查 |
| OCR 引擎 | **内置 ONNX**（manga-ocr beam4 + RT-DETR，本机 12/12 与 mokuro 逐字一致；CPU 2.6s/页）| 借 Chrome ScreenAI DLL（依赖用户装过 Chrome）/ 云端 Lens（硬编码 key，随时可死）/ mokuro sidecar | **Hibiki 强**；对方无模型分发但可用性脆弱 |
| OCR 时机 | 导入期整卷批处理 + 阅读中框选补扫 | **阅读期整章预扫（当前页起 2 页并发 + generation 取消 + 进度 HUD）**，内存缓存 | **真差距**：Hibiki 没有阅读期自动 OCR，无法吃「未预处理内容」 |
| OCR 缓存 | manga.json 落盘（永久） | 仅内存 Map，重启重扫 | Hibiki 模式更好，懒 OCR 也应落盘 |
| 制卡 | AnkiDroid + AnkiConnect，页图封面，音频管线全 | 仅 AnkiConnect；整页图不裁框；无词/句音频 | Hibiki 强 |
| 阅读模式 | RTL 双页 spread + webtoon | 翻页/纵向有 OCR；**webtoon/双页无 OCR**（缺口） | Hibiki 强 |
| 手写兜底 | 云端 VLM 逐框手动（默认关） | 无 | Hibiki 强 |
| 互联 | /api/ocr job 代跑 + 移动端入口 | 无 | Hibiki 强 |
| **内容来源** | **仅本地**（.mokuro 导入 / 裸图文件夹） | **Mangayomi 扩展源体系**（`lib/eval/` dart_eval + flutter_qjs 双桥，海量在线源）+ 本地 | **唯一结构性差距** |
| 追踪器 | 无 | AniList/MAL/SIMKL 等（上游继承） | 刻意不做（见 §7） |
| 字幕挖矿（动画侧） | 视频页查词/制卡管线全有 | media_kit 字幕重绘 + 悬停查词 + **jimaku.cc 自动下载日语字幕** | Jimaku 自动字幕是视频侧课题，**另开任务**，不进本设计 |

## 3. 目标形态（一句话）

> 在漫画 tab 里接入在线源：浏览/搜索/追更在线漫画，打开即读；页面图到手后走**现有 ONNX 流水线**阅读期懒扫（整章预扫 + 磁盘缓存），覆盖层查词/一键制卡与本地漫画**零差别**；可选一键下载整章/整卷落地为本地漫画（自动衔接现有导入期整卷 OCR）。

## 4. 在线源路线（P0-1，定生死的决策）

### 甲′：mokuro.moe 在线目录源（Mokuro Bunko，用户点名新增，推荐首做）
- https://mokuro.moe/catalog/ ——社区托管的 **mokuro 预处理漫画目录**：内容本身就是「图片 + .mokuro」，**零 OCR、零部署**。
- **合同已实测验证（2026-07-25）**：`/catalog/api/library` 无鉴权，1019 系列，`{series:[{name,path,cover,volumes:[{name,cover,ocr_pending,ocr_active}]}]}`；系列详情 `/catalog/api/series?name=<enc>`；封面 `/catalog/api/cover?path=<enc>`；卷包 `/mokuro-reader/<系列>/<卷>.cbz`（纯图片 zip，`Accept-Ranges: bytes` 支持断点续传，样本 56MB/173 页）；OCR 数据**同路径旁挂** `/mokuro-reader/<系列>/<卷>.mokuro`（实测 v0.2.0-beta.6，`pages[{img_width,img_height,img_path,blocks[{box,vertical,font_size,lines}]}]`，`img_path` 与 CBZ 内路径一致）——正是现有导入器支持的 mokuro v0.2+ 格式，下载解包后零转换直通。
- 实现形态：漫画 tab 加「在线目录」入口，浏览/搜索系列 → **卷级一键下载**（图片 + .mokuro，并发 + 断点续传）→ 直接衔接**现有 .mokuro 导入链**入书架，查词/制卡当场可用。全链只新增一个 API client + 下载器 UI，是所有路线里最短闭环。
- 二期可选：不下载直接流式读（远程取图 + 远程 .mokuro），价值待定（本地化后体验更好，磁盘换流量）。
- 边界：内容覆盖 = 社区上传过的作品；站点内容版权灰色属用户自担（与外接 Suwayomi 同性质）。

### 甲″：种子/磁力下载获取（用户拍板新增，「qb 下载」）
- 复用 Hibiki 现有 torrent 栈（`packages/hibiki_torrent` 内置 libtorrent，缺 DLL 回退外接 qBittorrent）：粘贴磁力/种子（如 nyaa 上的生肉卷）下载，完成后落地文件夹接**现有漫画导入链**（有 .mokuro 直通；裸图/压缩包走内置 ONNX 整卷 OCR）。
- 不做站内搜索聚合（nyaa 爬取等灰色功能不进 app），只做「磁力入口 + 下载完成后一键导入为漫画」。

### 甲：MangaDex 官方 API 直连（内置源）
- 公开合法 API（api.mangadex.org，免 key，5 req/s），搜索/章节/at-home 图片服务器齐全。
- 工作量最小：一个 REST client + 模型映射，无扩展生态。
- **致命短板：日语 raw 覆盖弱**——MangaDex 主体是翻译扫本，学习者要的日语原文占比低。作为唯一源撑不起「在线看生肉」的目标。

### 乙：外接 Suwayomi-Server（推荐）
- Suwayomi（Apache-2.0 Java server）承载 **Tachiyomi 扩展生态**（含大量日语 raw 源），Hibiki 只消费其 REST/GraphQL API：库、系列、章节、页面图。
- 合规外部化：Hibiki 不分发任何聚合源代码，源的灰色地带留在用户自装的 server；先例已有（torrent 缺 DLL 回退外接 qBittorrent）。
- **契合互联架构**：桌面 host 常驻 Suwayomi，移动端经现有互联通道读同一个 server——手机不用跑 Java。
- 工作量中等：API client + 浏览/搜索 UI + 页面图流式读取；OCR 只吃 bytes，与来源解耦。
- 短板：多一个用户部署步骤（下载 jar / 一键脚本可缓解）。

### 丙：复刻 Mangayomi 扩展桥（否决）
- dart_eval + flutter_qjs 双解释器 + 兼容其扩展仓库格式：工作量巨大、上游扩展格式随时漂移、为兼容必读 GPL 代码有洁净室风险、聚合源灰色地带进入 Hibiki 自身。
- 「理论最全」但违背实用主义，**不做**。

**推荐：甲′首做（最短闭环，零 OCR）+ 乙为主路线（覆盖任意生肉，需配套阅读期懒 OCR）。甲（MangaDex）二期可选，丙否决。甲′/乙/甲共用同一个「在线漫画源」抽象。**

## 5. 阅读期懒 OCR（P0-2：推翻旧设计一条「刻意不做」）

2026-07-24 设计 v2 §5.5 写了「刻意不做：翻页实时 OCR（复杂度爆炸，批处理已覆盖）」。该结论的前提是**所有内容都经过导入期**——在线源没有导入期，前提失效，需要用户确认推翻。这不是实时逐帧 OCR，而是：

- **单页管线**：页面图 bytes → 现有 `manga_ocr_pipeline`（RT-DETR 检测 + manga-ocr 识别 + 阅读顺序）→ blocks（manga.json 同构片段）→ 现有 `manga_overlay_html` 覆盖层。流水线零新增，只加一个「按页」入口（框选补扫已验证过单框入口，按页是其推广）。
- **预扫策略**（抄 Mangatan 交互，自己实现）：进章节从当前页起向后 2 页并发预扫；翻页/换章用 generation 计数器取消陈旧任务；角落显示 `OCR n/m` 进度。
- **磁盘缓存**（比 Mangatan 强的点）：key = 源+系列+章节+页号+图片内容 hash+模型版本，落 manga.json 同构结构；重启不重扫，模型升级自动失效。
- **平台分级**：桌面直接可用（实测 CPU 2.6s/页，预扫 2 页并发即「翻到即就绪」）；移动端首期走**互联代跑**（现有 `/api/ocr` job 语义扩一个单页 job），本地懒扫待 P4 真机基准（与旧设计口径一致，不新开口子）。
- 已有的框选补扫、云端手写兜底在在线页上原样可用（都只依赖页图 + blocks）。

## 6. 数据模型方向（计划阶段细化）

- **浏览态零入库**：在线源的搜索/浏览/试读不建任何行，纯客户端状态。
- **收藏 = 建行**：加入书架时建 `EpubBooks` 行（`format='manga'`），新增来源标记（列或复用现有远端书机制，计划阶段定），进度/继续阅读/删除传播/互联横切能力免费继承——与设计 v2「一个数据结构 N 个生产者」同一哲学。
- **懒 OCR 缓存**归书目录下 manga.json 同构文件，与本地漫画消费合同完全一致——阅读器不感知「在线/本地」差别。
- **下载离线**：整章/整卷拉图落盘 → 变成普通本地漫画（可再跑导入期整卷 OCR 补齐质量）。

## 7. 刻意不做

- 追踪器（MAL/AniList/SIMKL）：与语言学习目标无关，Hibiki 有自己的统计/目标体系。
- 复刻 Mangayomi 扩展桥（§4 丙）。
- 动画/小说在线源：本设计只管漫画 tab；Jimaku 自动字幕下载是视频侧独立任务（值得单独立项，见 §9）。
- 搬运任何 GPL 代码（含 OwOCR 式块合并的源码；若需要 furigana 过滤等启发式，按论文/思路重写并加基准）。
- 平台 OCR / 云端 Lens 降级路径（旧设计已否决，Mangatan 的实现反而证明其脆弱：硬编码 Chrome API key + 依赖用户 Chrome 安装状态）。

## 8. 分阶段草案（拍板后细化为 plan）

| 阶段 | 内容 | 出口 |
|---|---|---|
| O1 | **mokuro.moe 目录源（甲′）**：在线目录浏览/搜索 + 卷级下载器 + 现有 .mokuro 导入链衔接 | 真机：目录搜书→下载→书架打开→查词制卡（零 OCR 最短闭环） |
| O2 | Suwayomi API client + 漫画 tab 在线浏览/搜索/阅读（桌面先行，直读不入库） | 真机：浏览→开章→翻页流畅 |
| O3 | 阅读期懒 OCR：单页入口 + 预扫 + 磁盘缓存 + 进度 HUD；覆盖层/查词/制卡接通 | 真机：在线生肉点字查词→制卡带页图 |
| O4 | 收藏入书架（建行 + 进度恢复 + 继续阅读卡）+ 移动端经互联读 host 的 Suwayomi + 单页互联代跑 | 手机真机闭环 |
| O5 | Suwayomi 下载离线 → 本地漫画衔接；（可选）MangaDex 内置源 | 离线卷可整卷 OCR |

## 9. P0 拍板结果（用户，2026-07-25）

1. **路线组合**：✅ 甲′（mokuro.moe 目录源）+ ✅ 乙（外接 Suwayomi）+ ✅ **甲″ 种子/qb 下载**；甲（MangaDex）未选，不做。
2. **阅读期懒 OCR**：✅ 确认（仅乙路线在线内容；甲′/甲″/本地路径不受影响）。
3. **收藏形态**：✅ 按推荐——在线系列收藏才建行进书架。
4. **Suwayomi 下载离线**：✅ 做。
5. **Jimaku**：❌ 不立项（与漫画无关，用户裁定）。

### 拍板后分期（覆盖 §8 草案）

| 阶段 | 内容 | 出口 |
|---|---|---|
| O1 | mokuro.moe 目录源：浏览/搜索 + CBZ/.mokuro 下载器（断点续传）+ 现有导入链衔接 | 真机：目录搜书→下载→书架打开→查词制卡 |
| O2 | 种子获取（甲″）：磁力入口 + 完成后一键导入为漫画 | 真机：磁力→下载→导入→（裸图卷）整卷 OCR→查词 |
| O3 | Suwayomi API client + 在线浏览/直读（桌面先行） | 真机：浏览→开章→翻页流畅 |
| O4 | 阅读期懒 OCR（预扫+磁盘缓存+进度 HUD）+ 查词/制卡接通 | 真机：在线生肉点字查词→制卡带页图 |
| O5 | 收藏建行入书架 + 移动端经互联 + 单页互联代跑 | 手机真机闭环 |
| O6 | Suwayomi 下载离线衔接本地链 | 离线卷可整卷 OCR |

## 10. 调研出处

- Mangatan 浅 clone @ `9e3b366`（2026-07-06）：OCR 三引擎 `lib/services/mining/{screen_ai_ocr,chrome_lens_ocr,mokuro_parser}.dart`、块合并 `ocr_block_merger.dart`（自注释 OwOCR stages）、覆盖层 `lib/modules/mining/widgets/reader_ocr_overlay.dart`（Canvas afterPaintImage 绘制，0..1 归一化坐标）、弹窗 `dictionary_lookup_popup.dart`（单例屏外 prewarm）、Anki `anki_markers.dart`（约 40 个 Yomitan 式 marker + Lapis 映射）、扩展桥 `lib/eval/`（dart_eval + flutter_qjs，上游继承）、`windows/runner/screen_ai_bridge.cpp`（动态加载 Chrome ScreenAI DLL + 手写 protobuf 解码）。
- Hibiki 现状：`docs/specs/2026-07-24-manga-ocr-design.md`（设计 v2）+ develop `de5103250`（P1-P4 全量实现）。
- 本机 OCR 基准（9800X3D/5090，2026-07-24）：ONNX beam4 与原版 12/12 逐字一致，整页 CPU 2.6s / CUDA 0.56s。
