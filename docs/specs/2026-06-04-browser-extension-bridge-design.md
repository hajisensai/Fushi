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
2. **弹窗渲染**：复用 Hibiki 同款渲染资源。**核实后修正**（见 §11）：Hibiki 弹窗是「WebView 空壳 + `popup.js` 拿 JSON 动态画 DOM」（情况二），不存在现成 HTML 字符串。但扩展本身跑在真浏览器里、自带 DOM/CSS/JS 运行时，因此**把 `popup.js`/`popup.css`/`popup.html` 壳原样打进扩展**，服务器只返回 JSON（`lookupPopupJson`），扩展 `window.lookupEntries = json; window.renderPopup();` 用同一套代码渲染。看起来与 App 一模一样，且复用最彻底、无需抽纯生成器。

## 4. 架构与数据流

```
┌─────────────────────────────┐         HTTP (localhost:<port>, Basic auth)        ┌──────────────────────────────┐
│  浏览器扩展 (MV3, 全新但薄)   │                                                    │  Hibiki (HibikiSyncServer)    │
│                             │   GET /api/lookup/dictionary?text=…&record=1       │                              │
│  content script:           │ ─────────────────────────────────────────────────▶ │  → HibikiRemoteLookupService │
│   Shift+mousemove           │ ◀──────── { results, popupJson } ──────────────────│    .searchDictionary         │
│   caretRangeFromPoint 取词   │                                                    │  → addToSearchHistory        │
│   复用 popup.js 渲染 JSON     │                                                    │  → addToDictionaryHistory    │
│   + 句子上下文               │   POST /api/mine { fields, sentence, … }           │  (record=1 时)               │
│  Shadow DOM 浮层             │ ─────────────────────────────────────────────────▶ │  → createAnkiRepository()    │
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
4. Hibiki 用 `HoshiDicts` 去屈折查词 → 返回 `lookupPopupJson`（与 App 内弹窗同源的 JSON）；`record=1` 时调 `addToSearchHistory` + `addToDictionaryHistory`。
5. 扩展在 Shadow DOM 里用打包进来的 `popup.js`/`popup.css`（Hibiki 同款资源）渲染该 JSON：`window.lookupEntries = json; window.renderPopup();`，浮层显示。
6. 用户点弹窗「挖词」按钮 → `POST /api/mine`，body 含字段 map（expression/reading/glossary/sentence 等）+ 句子上下文。
7. Hibiki 调 `mineEntry(...)` 生成 Anki 卡片，返回 `success | duplicate | notConfigured | error`，扩展据此提示。

## 5. 组件设计

### 5.1 Hibiki 侧（Dart，改动小，全部复用）

> 函数/方法新增 helper 必须带明确类型签名（项目规则）。

**A. 扩展现有 `GET /api/lookup/dictionary`**（`_handleLookupApi`）：
- 确认响应体含 `lookupPopupJson`（弹窗用 JSON）。**不返回 HTML**——渲染由扩展侧用同款 `popup.js` 完成（见 §5.2 / §11）。若现接口未直接带 popup JSON，补上该字段即可。
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
  content.js             # 取词扫描 + 弹窗注入(挂 Shadow DOM) + 挖词按钮
  vendor/                # 从 hibiki/assets/popup/ 同步进来的渲染资源
    popup.js             #   Hibiki 同款 1828 行渲染逻辑（原样复用）
    popup.css            #   Hibiki 同款样式
    popup.html           #   空壳容器结构（可直接内联进 Shadow DOM）
  bridge-shim.js         # 垫掉 popup.js 里的 flutter_inappwebview.callHandler 调用
  options.html / .js     # host:port + token + 修饰键设置
  background.js          # 可选：集中发请求绕过页面 CSP/CORS
```

- **取词扫描（唯一硬骨头）**：监听 `mousemove`，按住修饰键（默认 Shift）时用 `caretRangeFromPoint` / `caretPositionFromPoint` 定位光标下字符，构造 `Range` 向右扩展取词窗口，并向两侧扩到句边界作为 sentence 上下文。这是 Yomitan 同类技术里最有含量的部分，也是本扩展主要实现风险；做法成熟、范围可控。
- **请求**：content script（或 background）`fetch` 到 `localhost:<port>`，带 Basic 鉴权头。需在 manifest `host_permissions` 声明 `http://localhost/*`。注意页面 CSP 对 content script 内联 fetch 的限制 → 必要时经 background service worker 代发。
- **弹窗渲染（复用 Hibiki 资源）**：在页面上挂一个 Shadow DOM 容器（隔离宿主页面样式），把 `vendor/popup.html` 壳结构 + `popup.css` 注入其中，加载 `popup.js`，然后 `window.lookupEntries = <服务器 JSON>; window.renderPopup();`，用与 App 完全相同的代码画出弹窗；跟随鼠标/选区定位；点外部或松开修饰键收起。
- **桥接 shim（`bridge-shim.js`）**：`popup.js` 里约十几处 `window.flutter_inappwebview.callHandler(name, ...)`（回报 `scrollHeight`、音频播放、查重等）在扩展里没有 Flutter 宿主，需提供一个垫片对象拦截这些调用：高度类→直接量浮层 DOM，音频/挖词类→转成扩展自身逻辑或接 `/api/mine`，其余→no-op。这是有界改动（几十行），不改 `popup.js` 主体。
- **挖词按钮**：弹窗内按钮（`popup.js` 现有挖词 UI）经 shim → 收集当前词条字段 + sentence → `POST /api/mine`。
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
4. **弹窗渲染复用已验证（见 §11）**：Hibiki 弹窗是 WebView 内 `popup.js` 动态画 DOM（无现成 HTML 串），但扩展自带浏览器 DOM 运行时，可**原样复用 `popup.js`/`popup.css`**，无需抽纯生成器。唯一附带成本是给 `popup.js` 的 `flutter_inappwebview.callHandler` 调用垫 shim（有界）。此前的"可能要抽数百行生成器"风险已消除。

## 9. 范围外（未来另开 spec）

- 桌面端剪贴板监听 + 全局热键弹窗（之前的「选项 2」）。
- 网页阅读位置/进度同步。
- 跨设备（非 localhost）使用扩展：现有服务器支持 LAN，但扩展默认只配 localhost；远程使用是后续增强。
- 频率/音调/音频等 Yomitan 富功能：按需再说，默认不做。

## 10. 落地顺序（供 plan 参考）

1. Hibiki 侧 `POST /api/mine` + 单测（最独立，先打通挖词链）。
2. Hibiki 侧确认/补 `/api/lookup/dictionary` 返回 `lookupPopupJson` + 加 `record` 开关 + 单测。
3. 扩展骨架：manifest + options + 连通性（能查词、拿到 JSON）。
4. 扩展弹窗渲染：vendor 进 `popup.js`/`popup.css` + `bridge-shim.js` 垫桥接 → 在 Shadow DOM 里渲染同款弹窗。
5. 扩展取词扫描（硬骨头）+ sentence 上下文。
6. 扩展挖词按钮经 shim 接 `/api/mine`。
7. 端到端真浏览器复测 + 证据。

## 11. 附录：弹窗渲染路径核实结论（2026-06-04）

落地前验证「Hibiki 弹窗 HTML 怎么生成」，结论为**情况二（WebView 内 JS 动态画 DOM）**：

- `DictionaryPopupWebView` 加载的是**空壳**：移动端 `loadUrl` 加载 `assets/popup/popup.html`（body 仅一个空 `<div id="entries-container">`），Windows 端 `loadData` 内联 css/js 但 body 同样是空壳（`dictionary_popup_webview.dart:448-450` / `:421-440`）。
- JSON 经 `evaluateJavascript` 注入：`window.lookupEntries = <json>; window.renderPopup();`（`dictionary_popup_webview.dart:342-358`）。
- 真正把 JSON 渲染成 DOM 的是 `assets/popup/popup.js`（1828 行）：`renderPopup`(`:1679`)/`buildEntryElement`(`:1605`)/`createGlossarySection`(`:1456`)/`renderStructuredContent`(`:940`)，样式 `popup.css`（593 行）。Dart 端 `buildLookupEntriesJson`(`:679-771`) 只产 JSON 不产 HTML。
- 依赖运行时：约 161 处 DOM 调用 + 十余处 `flutter_inappwebview.callHandler`（回报 `scrollHeight`、音频、查重）。

**对本设计的影响（关键）**：情况二在「桌面导出 HTML」场景才麻烦；但本设计的渲染发生在**浏览器扩展**里——它自带与 WebView 等价的 DOM/CSS/JS 运行时，故**直接复用 `popup.js`/`popup.css` 即可**，服务器返回 JSON 而非 HTML。代价从"重写数百行生成器"降为"垫一个 `callHandler` shim"。因此采用「服务器返回 JSON + 扩展复用 popup.js 渲染」方案，而非原先设想的"服务器返回 HTML"。
