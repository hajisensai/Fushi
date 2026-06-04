# Hibiki 浏览器查词桥（Hibiki Reader Bridge）设计

- 日期：2026-06-04
- 状态：设计待评审
- 作者：与用户头脑风暴产出

## 1. 背景与目标

用户希望要一个「类似 Yomitan」的能力：在浏览器网页里取词查词。经过需求收敛，**不复刻 Yomitan 全部功能**（用户明确「Yomitan 功能太多，用不上」），而是做一个**与 Hibiki 打通**的极薄浏览器扩展。

最终锁定的三个诉求：

1. **浏览器查词用 Hibiki 词库**：网页里取词时，查词走 Hibiki 已导入的词典 + 去屈折引擎，浏览器侧不重复造词典引擎。
2. **查词历史并入 Hibiki**：浏览器里查过的词，记入 Hibiki 的查词历史，两边共一份。
3. **挖词进 Anki**：网页里取到的词/句，经 Hibiki 已有的 Anki 集成生成卡片。

被明确**砍掉**的诉求（不在本设计范围）：
- 网页阅读位置/进度同步（定义模糊、收益低）。
- 桌面端剪贴板监听 + 全局热键弹窗（独立项目，另开 spec）。
- 真·系统级网页内悬停（那是 Yomitan 本体的能力，本设计用「扩展 + Hibiki 后端」近似，不追求逐像素等价）。

## 2. 核心判断（为什么这个项目小）

**本质**：一个极薄的浏览器扩展当前端，Hibiki 已有的本地 HTTP 服务器当后端。查词 / 历史 / 挖 Anki 全部复用 Hibiki 现成能力；扩展自己只负责「抓悬停的词 + 注入弹窗」。

之所以薄，是因为关键基础设施已经存在（核实于 develop 当前代码）：

| 现成件 | 位置 | 复用点 |
|---|---|---|
| 本地 HTTP 服务器（shelf） | `hibiki/lib/src/sync/hibiki_sync_server.dart`（`HibikiSyncServer`） | 已有 Basic 鉴权 + LAN 配对 + bonsoir 发现；加路由 = 在 `_handleRequest` 加 `if` 分支 |
| 查词 HTTP 接口（已存在） | `GET /api/lookup/dictionary` → `_handleLookupApi`（`hibiki_sync_server.dart:247`）→ `HibikiRemoteLookupService.searchDictionary` → `HoshiDicts`（带去屈折） | 诉求①几乎白送 |
| 查词历史写入 API | `AppModel.addToSearchHistory`（`app_model.dart:2131`）+ `AppModel.addToDictionaryHistory`（`app_model.dart:2407`） | 诉求② |
| Anki 挖词统一入口 | `BaseAnkiRepository.mineEntry(rawPayloadJson, context)`（`packages/hibiki_anki/lib/src/base_anki_repository.dart:41`），平台分流由 `platformServices.createAnkiRepository()` 自动处理 | 诉求③ |
| 查词弹窗渲染来源 | `HoshiDicts.lookupPopupJson`（`hoshidicts.dart:445`）+ `DictionaryPopupWebView` 渲染模板 | 弹窗 HTML 复用 |

## 3. 关键决策（已与用户确认）

1. **扩展代码位置**：放 Hibiki 仓库子目录（建议 `tools/browser-extension/` 或 `hibiki-extension/`，落 plan 时定名）。协议两端同仓，改接口不脱节。
2. **弹窗渲染**：服务器返回 Hibiki 同款弹窗 HTML，扩展直接注入页面浮层。看起来与 App 一模一样，扩展代码最少；既然词典本来就用 Hibiki 的，弹窗也一并复用。

## 4. 架构与数据流

```
┌─────────────────────────────┐         HTTP (localhost:<port>, Basic auth)        ┌──────────────────────────────┐
│  浏览器扩展 (MV3, 全新但薄)   │                                                    │  Hibiki (HibikiSyncServer)    │
│                             │   GET /api/lookup/dictionary?text=…&record=1       │                              │
│  content script:           │ ─────────────────────────────────────────────────▶ │  → HibikiRemoteLookupService │
│   Shift+mousemove           │ ◀───────────── { results, popupHtml } ──────────── │    .searchDictionary         │
│   caretRangeFromPoint 取词   │                                                    │  → addToSearchHistory        │
│   + 句子上下文               │                                                    │  → addToDictionaryHistory    │
│                             │   POST /api/mine { fields, sentence, … }           │  (record=1 时)               │
│  注入 popupHtml 浮层         │ ─────────────────────────────────────────────────▶ │  → createAnkiRepository()    │
│  「挖词」按钮                │ ◀───────────── { result: success|duplicate|… } ─── │    .mineEntry                │
│                             │                                                    │                              │
│  options 页: host:port +     │                                                    │  门控: SyncBackendType        │
│  配对 token + 修饰键          │                                                    │  .hibikiServer 开关          │
└─────────────────────────────┘                                                    └──────────────────────────────┘
```

数据流（一次查词 + 挖词）：

1. 用户按住 Shift，鼠标悬停网页某词。
2. content script 用 `caretRangeFromPoint`（Chromium）/ `caretPositionFromPoint`（Firefox）定位光标下字符，向右扩展出一个取词窗口（最长 N 字），并抓取所在句子作为上下文。
3. `GET /api/lookup/dictionary?text=<window>&record=1` 到 `localhost:<port>`，带 Basic 鉴权头（配对 token）。
4. Hibiki 用 `HoshiDicts` 去屈折查词 → 得到结果与 `lookupPopupJson` → 渲染同款弹窗 HTML；`record=1` 时调 `addToSearchHistory` + `addToDictionaryHistory`。
5. 扩展把 `popupHtml` 注入页面 Shadow DOM 浮层显示。
6. 用户点弹窗「挖词」按钮 → `POST /api/mine`，body 含字段 map（expression/reading/glossary/sentence 等）+ 句子上下文。
7. Hibiki 调 `mineEntry(...)` 生成 Anki 卡片，返回 `success | duplicate | notConfigured | error`，扩展据此提示。

## 5. 组件设计

### 5.1 Hibiki 侧（Dart，改动小，全部复用）

> 函数/方法新增 helper 必须带明确类型签名（项目规则）。

**A. 扩展现有 `GET /api/lookup/dictionary`**（`_handleLookupApi`）：
- 响应体增加 `popupHtml` 字段（由 `lookupPopupJson` 经现有弹窗模板渲染；落 plan 时确认模板能否在非 WebView 上下文复用，否则把模板抽成纯字符串生成器）。
- 增加查询参数 `record`（默认 `0`/false）：为 `1` 时，在返回前调用 `addToSearchHistory` + `addToDictionaryHistory`。默认关，避免 LAN 远程查词污染本机历史（现有远程查词路径不应写历史，靠开关区分）。

**B. 新增路由 `POST /api/mine`**：
- body：`{ fields: <map JSON>, sentence: String, cueSentence?: String, documentTitle?: String, sentenceOffset?: int }`。
- 处理：构造 `AnkiMiningContext` → `platformServices.createAnkiRepository().mineEntry(rawPayloadJson: jsonEncode(fields), context: ...)`。
- 响应：`{ result: "success"|"duplicate"|"notConfigured"|"error" }`（直接映射 `MineResult` 枚举）。

**C. 鉴权**：沿用 `_authMiddleware`（HTTP Basic）+ 现有配对 token 体系。两个新路由默认受保护（与 `/api/lookup/dictionary` 同级），无需改中间件白名单。

**D. 配置 / 发现**：扩展直连 `localhost:<port>`（`SyncRepository.defaultServerPort`）。用户在扩展 options 里手填 host:port + token；token 来自 Hibiki 现有「Hibiki 互联」配对流程（复用，不新造配对 UI）。

### 5.2 浏览器扩展侧（JS / Manifest V3，全新但薄）

目录（建议）：
```
tools/browser-extension/
  manifest.json          # MV3
  content.js             # 取词扫描 + 弹窗注入 + 挖词按钮
  popup-host.css         # Shadow DOM 浮层样式（隔离页面 CSS）
  options.html / .js     # host:port + token + 修饰键设置
  background.js          # 可选：集中发请求绕过页面 CSP/CORS
```

- **取词扫描（唯一硬骨头）**：监听 `mousemove`，按住修饰键（默认 Shift）时用 `caretRangeFromPoint` / `caretPositionFromPoint` 定位光标下字符，构造 `Range` 向右扩展取词窗口，并向两侧扩到句边界作为 sentence 上下文。这是 Yomitan 同类技术里最有含量的部分，也是本扩展主要实现风险；做法成熟、范围可控。
- **请求**：content script（或 background）`fetch` 到 `localhost:<port>`，带 Basic 鉴权头。需在 manifest `host_permissions` 声明 `http://localhost/*`。注意页面 CSP 对 content script 内联 fetch 的限制 → 必要时经 background service worker 代发。
- **弹窗注入**：把返回的 `popupHtml` 塞进一个挂在页面上的 Shadow DOM 容器，隔离宿主页面样式；跟随鼠标/选区定位；点外部或松开修饰键收起。
- **挖词按钮**：弹窗内按钮 → 收集当前词条字段 + sentence → `POST /api/mine`。
- **options**：极简表单（host、port、token、修饰键）。不做 Yomitan 那种海量设置页。

## 6. 错误处理

| 场景 | 行为 |
|---|---|
| Hibiki 未运行 / 连不上 | 扩展弹窗显示「Hibiki 未运行或未开启互联服务器」，不报红堆栈 |
| 鉴权失败（token 错） | 提示去 options 重新配对/填 token |
| 查无结果 | 弹窗显示空态（复用 Hibiki 空态）或不弹 |
| Anki 未配置（`notConfigured`） | 提示「Anki 未配置」，引导去 Hibiki 设置 |
| 挖词重复（`duplicate`） | 提示「已存在」，不报错 |
| 取词扫描失败（无 Range） | 静默不弹，不打断浏览 |

## 7. 测试策略

- **Hibiki 侧（Dart）**：
  - 单元/集成测试 `POST /api/mine`：mock `AnkiRepository`，断言 `mineEntry` 收到正确 payload，`MineResult` 各分支正确映射到响应。
  - `GET /api/lookup/dictionary?record=1`：断言查词返回含 `popupHtml`，且 `record=1` 时写了历史、`record=0` 时不写（守卫「远程查词不污染历史」这条不变式）。
  - 鉴权：无 token / 错 token 返回 401。
- **扩展侧（JS）**：
  - 取词扫描纯函数（给定 DOM + 坐标 → 取词窗口 + sentence）做单测（jsdom 或 Playwright）。
  - 端到端冒烟：起一个本地 Hibiki server stub，扩展查词→注入→挖词全链路（Playwright 加载未打包扩展）。
- 真机/真浏览器复测：声明「修好了」前需在真实 Chrome + 运行中的 Hibiki 上跑通取词→弹窗→挖 Anki，并留证据。

## 8. 硬约束（必须对用户讲清）

1. **扩展依赖 Hibiki 正在运行**：它是后端，Hibiki 不开就查不了。自用桌面场景可接受。
2. **取词扫描是唯一硬骨头**，其余全是 HTTP 胶水。
3. **不 fork Yomitan、不在浏览器塞词典引擎**——正是「嫌 Yomitan 臃肿」的解药。
4. **弹窗模板复用前提**：需确认 Hibiki 弹窗 HTML 能在「纯返回字符串」场景生成（非依赖运行中的 WebView 实例）；若强耦合 WebView，则在 plan 阶段抽出纯生成器。这是落地前要先验证的一个技术假设。

## 9. 范围外（未来另开 spec）

- 桌面端剪贴板监听 + 全局热键弹窗（之前的「选项 2」）。
- 网页阅读位置/进度同步。
- 跨设备（非 localhost）使用扩展：现有服务器支持 LAN，但扩展默认只配 localhost；远程使用是后续增强。
- 频率/音调/音频等 Yomitan 富功能：按需再说，默认不做。

## 10. 落地顺序（供 plan 参考）

1. Hibiki 侧 `POST /api/mine` + 单测（最独立，先打通挖词链）。
2. Hibiki 侧 `/api/lookup/dictionary` 增 `popupHtml` + `record` + 单测（先确认弹窗模板可纯生成，否则先抽生成器）。
3. 扩展骨架：manifest + options + 连通性（能查词、能注入弹窗 HTML）。
4. 扩展取词扫描（硬骨头）+ sentence 上下文。
5. 扩展挖词按钮接 `/api/mine`。
6. 端到端真浏览器复测 + 证据。
