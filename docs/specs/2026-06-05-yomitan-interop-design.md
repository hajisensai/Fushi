# Hibiki ⇄ Yomitan 生态互通 设计

- 日期：2026-06-05
- 状态：设计待评审
- 作者：与用户头脑风暴产出
- 工作分支：`worktree-yomitan-compat`

## 1. 背景与目标

用户希望 Hibiki 与 Yomitan（前身 Yomichan）日语查词生态互通。经需求收敛与调研，锁定**两条完全独立**的功能：

1. **线1 — texthooker（WS 收文本）**：Hibiki 当 WebSocket **client**，连上 Textractor / mpv / agent / LunaTranslator 等抓取工具的 WS server，接收它们抓到的游戏/番剧/视觉小说文本流，在 Hibiki 内逐词查词、挖词进 Anki。让用户现有「Textractor + Yomitan」工作流的文本也能喂进 Hibiki。
2. **线2 — yomitan-api 兼容（HTTP 服务端）**：Hibiki 当 HTTP **server**，兼容 `Kuuuube/yomitan-api` 的 HTTP POST 协议，让现有 yomitan-api 客户端/脚本可以指向 Hibiki，查 Hibiki 已导入的词典。

两条线互不依赖，各有独立设置开关（默认关，仿现有 `hibikiServer` 门控范式）。

## 2. 关键调研结论（决定方案的事实）

### 2.1 Yomitan 本身不碰 WebSocket

调研确认：Yomitan 是浏览器扩展，永远只「扫描页面 DOM 上已存在的文字」查词。生态里所有 WebSocket 都发生在 Yomitan **上游的文本注入环节**——抓取工具开 WS server 把文本推给一个 texthooker 网页，Yomitan 再在该网页 DOM 上查词。

因此「兼容别人调用 yomitan 的 WS」对 Hibiki 的真实含义只能是：**Hibiki 替代「texthooker 网页 + Yomitan」，当 WS client 接收抓取工具的文本流**（线1，方向 A）。不存在「别人通过 WS 来查 Hibiki 词典」这种事——那是线2 HTTP 的活。

### 2.2 texthooker WS 事实标准（无官方协议）

来自消费端 `Renji-XD/texthooker-ui` 源码 `socket.ts` 的 `handleMessage`：

```js
line = JSON.parse(event.data)?.sentence || event.data;  // JSON.parse 失败时 catch no-op，line 保持原始 event.data
```

- **方向**：文本源是 server，texthooker（=本设计里的 Hibiki）是 client，单向 server→client。
- **消息格式**：**裸文本字符串** 或 `{"sentence":"..."}` JSON（只读 `sentence` 字段，其余忽略）。
- **端口约定**（社区收敛，非强标准）：`6677`（Textractor/kuroahna、mpv/kuroahna）、`9001`（agent/0xDC00）、`2333`（LunaTranslator）。GameSentenceMiner 默认同时监听这三个。
- 来源：`Renji-XD/texthooker-ui`、`kuroahna/textractor_websocket`(`src/lib.rs` 证实裸文本)、`kuroahna/mpv_websocket`、`0xDC00/agent`、`HIllya51/LunaTranslator`、`bpwhelan/GameSentenceMiner`。

### 2.3 严格兼容 termEntries 不可行，根因在导入层

逐字段对照 Yomitan `termEntries` 内部结构（`yomitan-api/docs/api_paths/termEntries.md`）与 Hibiki 实际数据后确认：Hibiki 在 **native `importer.cpp` 落盘环节就丢弃了关键字段**：

| Yomitan 字段 | Hibiki 现状 | 后果 |
|---|---|---|
| `score`（顶层+definition） | 解析了但从不写盘 | 按 score 排序的客户端得到全 0 |
| `sequences` / definition `id` | `sequence` 解析后丢弃 | 依赖 sequence 合并/去重的客户端出错 |
| tag 完整元数据 `{category,order,score,content,dictionaries,redundant}` | **tag_bank 完全没导入**，只剩 tag 名字串 | 无法还原 tag 分类/说明，最大缺口 |
| `sourceTermExactMatchCount`/`matchPrimaryReading`/`frequencyOrder` | 无等价数据 | 只能填假值 |

**能真实填的**（约 50-60% 字段，且最有价值）：term/reading、glossary 的 structured-content **原文原样保留**、frequency value/displayValue、pitch 位置、deinflected、wordClasses（拆 rules）。纯展示用途客户端完全够用。

真·严格兼容需改原生 C++ 导入器（持久化 score/sequence + 导入 tag_bank）+ 改 schema + 要求所有用户重导词典，代价与收益严重不匹配（外部 HTTP 客户端几乎只读展示字段）。

**用户决策：线2 采用「宽松兼容」**——适配器把 Hibiki 数据包成 termEntries 形状，展示字段全真，约 15 个内部字段填合理默认值。

## 3. 非目标

- 线1：不复刻 Yomitan 全部功能；不做剪贴板轮询（已被生态淘汰的 MV2 老机制）；不做 Hibiki 当 WS server 推文本（方向 B，本轮明确不做）。
- 线2：不做严格兼容（不改导入器、不重导词典）；不做 `kanjiEntries`（Hibiki 无专门 kanji 结构）；不做 `ankiFields`（复杂，外部可走 termEntries 自行组卡）。
- 不改变现有本地查词、阅读器、同步、Hibiki 互联远端查询的任何默认行为。

## 4. 核心判断

值得做，且大部分是复用已有基础设施的胶水：

| 复用件 | 位置 | 用途 |
|---|---|---|
| 查词去屈折引擎 | `HoshiDicts`（`hoshidicts.dart`） | 线1/线2 查词 |
| 查词窄接口（已存在） | `_AppModelRemoteLookupService.searchDictionary`（`app_model.dart`） | 线2 服务端查词，线1 也可复用 |
| 查词结果渲染 | `DictionaryPopupWebView`（喂 `DictionarySearchResult`） | 线1 逐词查词浮层 |
| 挖词统一入口 | `DictionaryPageMixin.onMineEntry` → `mineEntry`（`base_anki_repository.dart`） | 线1 挖词 |
| 输入路由（纯 Dart） | `ReaderCaretRouter.decideKeyboard/decideGamepad`（`reader_caret_router.dart`） | 线1 键盘/手柄逐词路由 |
| 分词 | `JapaneseLanguage.textToWords`（`japanese_language.dart`） | 线1 行分词、线2 tokenize 端点 |
| HTTP 栈 | `shelf` + `shelf_io`（`hibiki_sync_server.dart` 范式） | 线2 server |
| 端口占用处理 | `SyncServerPortInUseException` 范式 | 线2 server |
| 连接配置 UI 空壳 | `WebsocketDialogPage`（`websocket_dialog_page.dart`，目前空壳） | 线1 配置 |
| 流式列表样板 | `DebugLogService` + `DebugLogPage` 范式 | 线1 文本流 service/页面 |

唯一明显缺口：**实时文本接收（WebSocket client）目前零实现**（仓库仅有 `WebsocketDialogPage` 空壳 + i18n 字符串，注释提到「Reader WebSocket Source」但接收端代码不存在），需从头写。

## 5. 线1 — texthooker（WS 收文本）设计

### 5.1 连接层（新写）

- **`TexthookerService`**：单例 + `ChangeNotifier`（仿 `DebugLogService`），持文本行环形 buffer（上限可配，默认如 500 行）。方法签名带明确类型：
  - `void appendLine(String line)`
  - `List<String> get lines`
  - `void clear()`
- **`TexthookerWsClient`**：用 `web_socket_channel` 连一个或多个 WS server URL，**自动重连**（退避策略）。
  - 默认预置 URL 列表：`ws://localhost:6677`、`ws://localhost:9001`、`ws://localhost:2333`（用户可在设置增删）。
  - 消息解析（纯函数，单测目标）：`String parseTexthookerMessage(String raw)` —— 尝试 `jsonDecode`，成功且含 `sentence` 字段则取之，否则原样返回。等价于生态事实标准 `JSON.parse(d).sentence ?? d`。
  - 每条解析结果 `TexthookerService.appendLine`。
  - 连接状态（已连/重连中/失败）暴露给设置 UI 与页面顶栏。

### 5.2 呈现层（新页面）

- **`TexthookerPage`**（继承 `BaseTabPage`，`with DictionaryPageMixin`）：
  - 在 `home_page.dart` 加第 4 个 tab，**插在 dict(1) 和 settings 之间**。需同步修改：
    - `_navItems()` 加项；`buildBody()` 加 `case`；
    - 设置 tab 当前硬编码 index `2` 的两处（`_selectTab` 的 `logicalIndex == 2`、`_buildDesktopLayout` 的 `if (_currentTab == 2)`）改为新设置 index；
    - `_executeShortcutAction` 里 `homeTabSettings` 的目标 index、`homeTabNext/Prev` 的 `% 3` → `% 4`；
    - `lib/pages.dart` 加 `export`。
  - `ListView` 实时渲染文本行（订阅 `TexthookerService` notifier，新行自动滚到底；可回看历史行）。顶栏：连接状态、清空、连接配置入口。
  - **逐词查词**：每行文本经 `JapaneseLanguage.textToWords` 分词 → 渲染成可点 span；
    - 鼠标/触摸：点 span → `pushNestedPopup(query, rect, ...)` 弹 `DictionaryPopupWebView` 结果浮层；
    - 键盘/手柄：复用 `ReaderCaretRouter.decideKeyboard/decideGamepad` → 在 Flutter 层自绘逐词高亮光标（**不复用绑死 WebView DOM 的 `hoshiCaret`**，texthooker 横排为主，无需 writing-mode 处理）。
  - **挖词**：当前行原文作为 `sentence` 注入 fields，经 `DictionaryPageMixin.onMineEntry` → `mineEntry`。需确保 `fields['sentence']` = 当前行。

### 5.3 连接配置 UI

复用现成空壳 `WebsocketDialogPage`（补真实 connect 逻辑 + 多 URL 管理），或在设置页内嵌一个轻量列表编辑。落 plan 时定。

## 6. 线2 — yomitan-api 兼容 HTTP server 设计

### 6.1 服务挂载（独立 server 实例）

- **`YomitanApiServer`**：独立 shelf 实例，复用 `HibikiSyncServer` 的起停 + 端口占用处理范式，但**独立监听**。
  - 默认端口 **19633**（yomitan-api 默认，现有客户端零配置指向 Hibiki）。
  - **不塞进 `HibikiSyncServer`**：理由是端口不同、鉴权语义不同（SyncServer 强制 Basic auth；yomitan-api 默认无鉴权、可选 `X-API-Key`），硬塞会制造特例（Linus：消除特殊情况），独立实例语义干净。
- **鉴权**：默认无;用户可在设置里设 API key，设了就校验请求头 `X-API-Key`，缺失/错误返回 401（对齐 yomitan-api 行为）。锁定/限流（连续失败锁 60s）为可选增强，第一版可不做。
- **HTTP 约定**（对齐 yomitan-api）：只接受 POST，其余方法 405；响应 `application/json`，`ensure_ascii=false`（UTF-8 直出）。

### 6.2 适配器（宽松兼容）

- **`YomitanTermEntriesAdapter`**（带明确类型签名）：输入 `DictionarySearchResult`/Hibiki 查词数据，输出 yomitan-api `termEntries` 形状的 `Map`/JSON。
  - **展示字段全真**：`headwords[].term`/`reading`、`definitions[].entries`（glossary structured-content **原样透传**，首字符 `[`/`{` 判别 JSON）、`frequencies[].frequency`/`displayValue`、`pronunciations`（由 pitch 位置包装）、`headwords[].wordClasses`（拆 `rules`）、`deinflectedText`（由 `deinflected`）。
  - **内部字段填合理默认**：`score:0`、`frequencyOrder:0`、`sequences:[]`、`id:0`、`isPrimary:true`、`matchType:"exact"`、`tags:[]`、`hasReading:false`、`frequencyMode:"rank-based"`、`displayValueParsed:false`、`dictionaryAlias`=dictName、`dictionaryIndex`(按加载顺序临时编号)、`maxOriginalTextLength`(matched 长度)。
  - 顶层包 `{ index, dictionaryEntries[], originalTextLength }`，支持 `term` 为字符串或数组（数组逐项处理，`index` 对应输入下标）。

### 6.3 端点

| 端点 | 实现 |
|---|---|
| `POST /serverVersion` | 常量 `{ "version": 1 }`（Hibiki 自报兼容版本号） |
| `POST /yomitanVersion` | 常量字符串（声明所兼容的 yomitan-api 语义版本） |
| `POST /termEntries` | body `{term: string\|string[]}` → `_AppModelRemoteLookupService.searchDictionary` → `YomitanTermEntriesAdapter` |
| `POST /tokenize` | body `{text: string\|string[], scanLength?}` → `JapaneseLanguage.textToWords` + 每段读音标注；命中词条带精简 headwords |

不实现：`kanjiEntries`、`ankiFields`（见非目标）。

## 7. 设置与门控

- 线1 开关：`texthooker_enabled`（默认 false）+ WS URL 列表偏好。
- 线2 开关：`yomitan_api_server_enabled`（默认 false）+ 端口偏好 + 可选 API key。
- i18n：所有新 key 经 `tool/i18n_sync.dart`（17 语言），改完 `dart run slang` + `dart format` 生成文件。

## 8. 错误处理

| 场景 | 行为 |
|---|---|
| 线1 WS 连不上 | 页面/设置显示「未连接」+ 自动重连，不报红堆栈 |
| 线1 收到空行/非法 JSON | `parseTexthookerMessage` 原样当文本，不崩 |
| 线1 查无结果 | 复用查词空态 |
| 线2 非 POST | 405 |
| 线2 鉴权失败 | 401（设了 key 时） |
| 线2 查无结果 | 返回空 `dictionaryEntries` |
| 线2 引擎未初始化/词典未加载 | 返回空结果，不崩 |

## 9. 测试策略

- **纯函数单测**：`parseTexthookerMessage`（裸文本 / `{sentence}` / 非法 JSON / 无 sentence 字段）；`YomitanTermEntriesAdapter`（对照真实 yomitan-api 样例断言形状 + 默认值 + structured-content 透传 + 数组输入）。
- **端点单测**：`YomitanApiServer` 各端点请求/响应；非 POST→405；有 key 时鉴权 401；空结果。
- **集成测试**：loopback 起 `YomitanApiServer` 真实查一次 termEntries；起一个本地 WS server stub 推文本，验 `TexthookerWsClient` 收到并 append。
- **真机/真工具验证（留给用户）**：Textractor/mpv 推文本 → Hibiki texthooker 页面收到 → 逐词查词 → 挖卡；外部 yomitan-api 客户端指向 Hibiki:19633 查词成功。

## 10. 落地顺序（供 plan 参考）

1. 线2 适配器 `YomitanTermEntriesAdapter` + 单测（最独立、纯函数）。
2. 线2 `YomitanApiServer`（4 端点 + 鉴权 + 端口处理）+ 单测 + loopback 集成。
3. 线2 设置开关 + i18n。
4. 线1 `parseTexthookerMessage` 纯函数 + 单测。
5. 线1 `TexthookerService` + `TexthookerWsClient`（多源连接 + 重连）+ 单测。
6. 线1 `TexthookerPage` + 接入 `home_page.dart` 第 4 tab（含魔数/取模修正）。
7. 线1 逐词查词（分词 span + `ReaderCaretRouter` 路由 + `pushNestedPopup`）+ 挖词。
8. 线1 连接配置 UI（`WebsocketDialogPage`）+ 设置开关 + i18n。
9. 端到端真机/真工具复测 + 证据。

## 11. 决策记录

| 决策 | 选择 |
|---|---|
| 总范围 | 线1（WS 收文本）+ 线2（HTTP yomitan-api 服务端），两条独立 |
| 线1 角色 | Hibiki 当 WS client（收文本），方向 A |
| 线1 呈现 | 独立 texthooker tab 页面 |
| 线1 消息格式 | 兼容裸文本 + `{sentence}` JSON（生态事实标准） |
| 线1 默认端口 | 预置 6677/9001/2333，用户可改 |
| 线2 兼容度 | 宽松兼容（展示字段全真，~15 内部字段填默认） |
| 线2 端点 | serverVersion + yomitanVersion + termEntries + tokenize |
| 线2 挂载 | 独立 shelf server 实例，默认端口 19633 |
| 线2 鉴权 | 默认无，可选 X-API-Key |
| 两功能默认 | 均默认关闭，独立开关 |
