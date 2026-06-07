# Hibiki 网页插件 + 桌面剪贴板查词 设计

- 日期：2026-06-05
- 状态：设计待评审
- 作者：与用户头脑风暴产出
- 工作分支：`worktree-yomitan-compat`（与 yomitan-interop 两条线同 worktree，均未合 develop）

## 1. 背景与目标

继 yomitan-interop（texthooker WS + yomitan-api server）之后，补齐「网页/外部取词查 Hibiki 词库」的两条线：

1. **线3 — 浏览器网页插件**（参考 yomitan）：一个极薄 MV3 浏览器扩展，网页里取词 → 查 Hibiki 已导入词典 → 弹窗显示 → 挖词进 Anki。复用 Hibiki 本地 HTTP server 当后端，不在浏览器塞词典引擎。
2. **线4 — 桌面端剪贴板查词弹窗**（用 Hibiki 自己 app）：桌面（Win/mac/Linux）监听系统剪贴板变化 + 全局热键 → 把主窗口唤到前台（可选置顶）→ 在窗口内弹「分词可点」查词 overlay。

两条线独立，各自设置开关（默认关）。

## 2. 现状与关键事实（调研确认）

### 2.1 线3 浏览器扩展现状
- **扩展前端：零代码**（无 `tools/browser-extension/`，整套 MV3 扩展要从头写）。
- **后端差 2 项**（底层能力都现成）：
  - `POST /api/lookup/dictionary`（`hibiki_sync_server.dart:267`）已存在，body `{term, wildcards, maximumTerms}`，返回 `{type:'dictionaryResult', result, popupJson}`。**缺 record 写历史**（`addToSearchHistory`/`addToDictionaryHistory` 在 app_model 已就绪，端点没接）。
  - **无 `POST /api/mine`**（`mineEntry` 在 hibiki_anki 已就绪，路由没建）。
- popup 渲染资源 `hibiki/assets/popup/{popup.js,popup.css,popup.html}` 存在；Android `PopupDictActivity.kt:357` 已有「拼 HTML + 注 `window.lookupEntries` + `window.renderPopup()` + 垫 callHandler shim」的可参照范例。
- 注：旧 spec `feature/browser-extension-bridge` 分支的 `2026-06-04-browser-extension-bridge-design.md` 对 API 描述过时（写 GET + query `text` + `lookupPopupJson`），**以真实代码为准**（POST + body `term` + 字段 `popupJson`）。

### 2.2 线4 桌面剪贴板现状
- Android 侧已有剪贴板/选中弹窗查词（`FloatingDictService.java` 剪贴板监听 + `PopupDictActivity.kt` 选中弹窗 + `DictAccessibilityService.java` 无障碍取词）——**作语义参照，本线只做桌面**。
- 桌面端：**完全没有**剪贴板监听 / 全局热键 / 独立查词窗。现有 `lib/src/shortcuts/` 是 app 内焦点快捷键，非 OS 全局热键。
- `popupMain`（`popup_main.dart`）是 Android 专属第二引擎入口，桌面拉不起；但 `DictionaryPageMixin` + `DictionaryPopupLayer`（app 内 overlay 查词）桌面可用——**texthooker 已在桌面主 app 内用同一套**（`texthooker_page.dart`），是本线复用范式。
- **Flutter 桌面无稳定多窗口**（官方实验性，3.44 不可生产）。独立浮窗需 `desktop_multi_window` 多引擎，词典 FFI 句柄跨 isolate 不能共享 → 词典重载或全 IPC。**用户拍板：不开第二窗口，走主窗唤前台 + overlay**（单引擎、词典不重载）。

## 3. 非目标

- 线3：不复刻 yomitan 全部功能；不做网页阅读进度同步；不做跨设备远程；不做剪贴板轮询喂文本（yomitan-interop 已用 texthooker WS 替代）。
- 线4：不开独立第二窗口（框架限制 + 跨引擎词典难题，用户拍板走 overlay）；不做 Android（已有）；MVP 不做系统托盘。
- 不改动 yomitan-interop 已交付的两条线、不改现有阅读器/同步默认行为。

## 4. 线3 — 浏览器网页插件设计

### 4.1 Hibiki 后端（Dart，改 `hibiki/lib/src/sync/hibiki_sync_server.dart`）

**A. `POST /api/lookup/dictionary` 加 record 写历史**
- body 增可选 `record`（bool，默认 false）。为 true 且查到结果时，调 `appModel.addToSearchHistory` + `addToDictionaryHistory`（经 `HibikiRemoteLookupService` 或新增窄方法注入，避免 server 直接知道 AppModel 细节）。默认关，避免 LAN 远程查词污染历史。
- 现有响应形状不变（`{type, result, popupJson}`）。

**B. 新增 `POST /api/mine`**
- body：`{fields: Map<String,String>, sentence?: String, cueSentence?: String, documentTitle?: String, sentenceOffset?: int}`。
- 处理：构造 `AnkiMiningContext(sentence: ...)` → `mineEntry(rawPayloadJson: jsonEncode(fields), context)`（经注入的窄接口，仿 remoteLookupService 范式，不让 server 直接依赖 AnkiRepository）。
- 响应：`{result: "success"|"duplicate"|"notConfigured"|"error"}`（映射 `MineResult`）。

**C. 鉴权**：两个端点沿用现有 `_authMiddleware`（HTTP Basic + 配对 token），与 `/api/lookup/dictionary` 同级受保护。

### 4.2 浏览器扩展（JS / MV3，新建 `tools/browser-extension/`）

```
tools/browser-extension/
  manifest.json          # MV3, host_permissions: http://localhost/*
  content.js             # 取词扫描 + Shadow DOM 弹窗注入 + 挖词按钮
  background.js          # service worker，集中发请求绕页面 CSP/CORS
  vendor/                # 从 hibiki/assets/popup/ 同步
    popup.js  popup.css  popup.html
  bridge-shim.js         # 垫 popup.js 里的 flutter_inappwebview.callHandler
  options.html / options.js  # host:port + 配对 token + 修饰键
```

- **取词扫描（唯一硬骨头）**：`mousemove` + 修饰键（默认 Shift）→ `caretRangeFromPoint`（Chromium）/ `caretPositionFromPoint`（Firefox）定位光标下字符 → 向右扩取词窗口（最长 N 字）+ 向两侧扩到句边界作 sentence。这是纯函数可单测部分（给 DOM+坐标 → 取词窗口+sentence）。
- **请求**：`POST /api/lookup/dictionary {term, record:1}` 带 Basic 鉴权头 → 拿 `popupJson`。挖词 `POST /api/mine {fields, sentence}`。经 background service worker 代发绕 CSP。
- **弹窗渲染（复用 Hibiki 资源）**：Shadow DOM 容器内注入 vendor `popup.html` 壳 + `popup.css`，加载 `popup.js`，`window.lookupEntries = json; window.renderPopup();`。
- **bridge-shim**：拦截 `popup.js` 里 ~十余处 `flutter_inappwebview.callHandler`（scrollHeight 量浮层 DOM / 音频 / 挖词 → `/api/mine` / 查重 / 其余 no-op）。有界改动，不改 popup.js 主体。参照 Android `PopupDictActivity.kt` 的同款 shim。
- **options**：host、port、token（来自 Hibiki 现有配对流程）、修饰键。极简表单。

### 4.3 线3 落地顺序
1. 后端 record + `/api/mine` + 单测（最独立，纯 Dart）。
2. 扩展骨架：manifest + options + 连通性（能查词拿 JSON）。
3. 扩展弹窗渲染：vendor popup.js + bridge-shim。
4. 扩展取词扫描（硬骨头）+ sentence。
5. 挖词按钮 → `/api/mine`。
6. 真浏览器端到端复测（留用户）。

## 5. 线4 — 桌面剪贴板查词设计

### 5.1 新依赖（pubspec，桌面三端，leanflutter 生态）
- `clipboard_watcher`（剪贴板变化事件：Win 原生 / mac·Linux 轮询封装）。
- `hotkey_manager`（OS 级全局热键，app 后台也触发）。
- `window_manager`（主窗口 show/focus/可选 alwaysOnTop）。

### 5.2 `DesktopLookupService`（新，单例 ChangeNotifier，仿 `TexthookerService`）
- 平台门控：仅 `Platform.isWindows/isMacOS/isLinux` 启用。
- `clipboard_watcher` 回调 `onClipboardChanged` → 取剪贴板文本 → **trim + lastText 去重**（避免挖词/复制写剪贴板自触发，仿 `FloatingDictService.onClipboardChanged` 教训）→ 设「待查文本」+ notifyListeners。
- `hotkey_manager` 注册全局热键（默认如 Ctrl+Shift+D，可配）→ handler 取当前剪贴板文本 → 同上。
- 触发后：`window_manager.show()` + `focus()`（偏好开了置顶则 `setAlwaysOnTop(true)`）唤主窗到前台。
- `start()`/`stop()`（按设置开关），`dispose` 清理监听。纯函数 `String? dedupeClipboard(String raw, String? last)` 可单测。

### 5.3 宿主 overlay（复用 texthooker 范式）
- 在主 app 一个常驻宿主（如 home_page 外层 / 一个 overlay host）`with DictionaryPageMixin`，订阅 `DesktopLookupService`。
- 收到「待查文本」→ 弹一个**分词可点**的查词浮层：文本经 `JapaneseLanguage.instance.textToWords` 分词成可点 span（复用 `texthooker_page.dart` 的 `_TexthookerLine`/`_WordSpan` 模式），点词 `pushNestedPopup(autoRead:true)` 出 `DictionaryPopupLayer` 结果。挖词复用 mixin `onMineEntry`。
- overlay 形态：紧凑卡片（文本行 + 查词浮层），可关闭。

### 5.4 设置（settings_schema）
- `desktop_clipboard_lookup_enabled`（bool，默认 false，仅桌面可见）。
- `desktop_clipboard_hotkey`（热键自定义，可后续）。
- `desktop_clipboard_always_on_top`（bool，可选置顶）。
- 开关 onChanged → `DesktopLookupService.start/stop`；开机自启在 AppModel initialise 尾部（仿 yomitan/texthooker）。
- **登记 settings_schema_coverage_test 守卫**（switch 要进 kCoveredElsewhere，texthooker/yomitan 已踩过这坑）。

### 5.5 平台配置 / 风险
- macOS：全局热键 + 剪贴板可能需 entitlements / 辅助功能权限，首次引导授权。
- 自触发循环：lastText 去重必做。
- 前台行为：window_manager 唤前台会抢焦点（用户已知情接受）。
- 取词：日语有 `wordFromIndex`，剪贴板整段走 `textToWords` 分词可点（MVP 行为）。

### 5.6 线4 落地顺序
1. 加 3 依赖 + `dedupeClipboard` 纯函数 + 单测。
2. `DesktopLookupService`（剪贴板+热键监听 + 平台门控 + 去重）+ 单测（监听难单测，纯函数 + 源码守卫为主）。
3. 宿主 overlay（订阅 + 分词可点 + 查词，复用 texthooker）+ widget 测试。
4. 设置开关 + 覆盖守卫登记 + i18n + 生命周期接线 + 开机自启。
5. 真桌面复测（留用户）。

## 6. 测试策略
- 线3 后端：`/api/mine` 各 MineResult 分支、`record` 写/不写历史、鉴权 401 单测。
- 线3 扩展：取词扫描纯函数（jsdom/Node，若项目支持）；端到端真浏览器留用户。
- 线4：`dedupeClipboard` 纯函数单测；`DesktopLookupService` 平台门控源码守卫；overlay widget 测试（响应式 + 分词可点，不依赖 FFI）；真桌面复测留用户。
- i18n completeness（17 语言）。

## 7. 决策记录
| 决策 | 选择 |
|---|---|
| 总范围 | 线3 浏览器扩展全套 + 线4 桌面剪贴板查词，两条独立 |
| 线3 后端 | 加 record 写历史 + POST /api/mine，沿用 Basic auth |
| 线3 前端 | 从零 MV3 扩展，复用 assets/popup + bridge-shim（仿 Android PopupDictActivity） |
| 线4 查词窗形态 | 主窗唤前台 + 可选置顶 + app 内 overlay（不开第二窗口） |
| 线4 取词 | 剪贴板文本分词可点（复用 texthooker） |
| 线4 依赖 | clipboard_watcher + hotkey_manager + window_manager |
| 剪贴板弹窗归属 | 用 Hibiki 自己 app（桌面新做；Android 已有不动） |
| 两功能默认 | 均默认关闭，独立开关 |
