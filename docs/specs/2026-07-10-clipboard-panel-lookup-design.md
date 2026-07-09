# 剪贴板查词独立弹窗设计 · 常驻半透明面板 + 瞬态副档

> 状态：设计已与用户确认（2026-07-10），待写实现计划。
> 范围：Windows（面板/瞬态两种新去向）；macOS/Linux 剪贴板查词维持主窗 tab 现状。
> 基线代码：origin/develop `cdcef9b86`（本文所有 file:line 以此为准）。
> 前情：本设计**取代** `2026-06-05-webext-and-desktop-clipboard-design.md` 线 4 的「不开第二窗口」决策——当年的前提（Flutter 桌面无稳定多窗口、词典 FFI 不能跨 isolate）已被 TODO-617 的裸 WebView2 覆盖窗（不起第二 engine、主 Dart 引擎当词典大脑）绕开。

## 1. 目标与非目标

### 目标（主场景：游戏/VN + Textractor 自动复制台词流）
- 剪贴板查词的结果可以显示在一个**独立于主窗的常驻弹窗**里：置顶（可选）、半透明、不抢焦点、可拖动、记忆位置。
- 每次复制**原地更新**：句子条 + 查词结果替换刷新，不闪、不重弹、不跳位置。
- 句子逐字可点（后缀查词语义，同 in-app `ClipboardLookupTextPanel`），点词弹嵌套级联卡；发音 / 收藏 / 制卡全部可用（复用 TODO-1188 已通的桥）。
- 副档（瞬态模式）：复制 → 当作一次全局查词在光标处弹卡，点窗外即收——给「偶尔复制看一眼」的用户。
- 对比 yomitan 剪贴板监视要规避的三痛点：占整个浏览器窗、不置顶/抢焦点、笨重不透明。

### 非目标（本期明确不做）
- ❌ texthooker WS 行流接入面板（`TexthookerWsClient` 已在，留扩展点，另期接线）。
- ❌ macOS / Linux 的独立面板（覆盖窗 `isSupported` 是 Windows-only；两平台剪贴板查词维持主窗 tab）。
- ❌ 整窗 alpha 半透明（`WS_EX_LAYERED` 与 WebView2 组合表面不共存，`global_lookup_window.cpp:253-254` 注释明说；走 CSS 卡片背景 rgba，不碰 Win32 层）。
- ❌ 第二 Flutter engine / Flutter 多窗口框架（TODO-617 已论证过的三坑，不重蹈）。
- ❌ 面板内多句历史列表（面板只显示当前句；历史仍在主窗查词 tab 的搜索历史里）。

## 2. 核心判断（为什么这样设计）

**常驻面板不是新渲染面。** 它就是「一次带句子上下文的全局查词，渲染进第二个窗口实例」：

- `GlobalLookupController.lookupText(text)` 管线现成（查词 → `buildStackRenderScript` → renderStack，`global_lookup_render.dart:203-270`）。
- 句子条就是 root 卡已有的句子横幅（TODO-1030 UIA context banner）——剪贴板文本天然就是句子上下文，比 UIA 抓的还准，直接作制卡 sentence 字段。
- 嵌套级联（iframe 栈）、发音（♪ 桥）、收藏（☆/★）、制卡（mineEntry/duplicateCheck/✓↩ 覆写）九根 DEFERRED 桥全部白捡（`global_lookup_window.cpp:748-757`）。

真正的增量只有三块：**① native 窗从单例泛化为两实例**（瞬态 vs 常驻是两种关闭语义，分属两个窗口就零 `if(mode)` 分支）；**② 面板布局模式**（窗定内容适应，替代瞬态的内容定窗）；**③ 剪贴板事件按去向路由**。

**为什么不共用一个窗加 persistent mode**：点外关钩子、前台切换钩子、离屏自测-reveal 流程全要按模式分支；玩游戏时开着面板再按 Ctrl+Alt+D 会把面板内容顶掉，收起后还要恢复面板=状态机纠缠。两个实例各自语义纯粹。

## 3. 组件与边界

| 组件 | 语言 | 职责 | 新/复用 |
|---|---|---|---|
| `DesktopLookupService` | Dart | 剪贴板监听 + Ctrl+Shift+D 热键 + 排队（`desktop_lookup_service.dart:56-59`）。**生命周期升到 AppModel**（见 §7），新增 destination 路由 + `ignoreClipboardTexts` 抑制 | 改 |
| `ClipboardPanelController` | Dart 新 | 面板编排：收到剪贴板文本 → 查词 → 推第二窗；显隐/暂停/位置记忆 | 新 |
| `GlobalLookupController` | Dart | 瞬态覆盖窗编排。transient 去向直接复用 `lookupText()`（`global_lookup_controller.dart:377-398`）；抓选区前登记抑制文本 | 微改 |
| `GlobalLookupWindow` | C++ | 加构造 `Options{install_dismiss_hooks, …}`；面板实例不装 WH_MOUSE_LL / 前台切换钩子；窗类注册加 once 守卫 | 改 |
| 面板窗实例 + channel | C++/Dart | `flutter_window` 第二成员 + channel `app.hibiki.reader/clipboard_panel`（方法集同 global_lookup，另加 setOpacity/setPinned/dragStart） | 新（薄） |
| `global_lookup_host.html/js` | JS | 加面板布局模式（fixed-viewport：root 卡撑满、内容内滚）+ grip 拖动条 + 图钉/× 按钮 | 改 |
| `popup.html/js/css` + settingsJs | JS | 卡片渲染 + 半透明背景变量（`--hibiki-card-bg-alpha`） | 微改（单一真相源 `buildPopupSettingsJs` 加一个变量） |
| 设置 schema / prefs | Dart | `desktop_clipboard_destination` 三选 + 面板透明度/位置/图钉 prefs | 新 key |

每个组件可独立理解与测试：
- `ClipboardPanelController`：输入「句子文本」，输出「面板上一帧渲染」，副作用「无」（不碰剪贴板、不碰焦点）。
- 面板窗实例：输入「rect + JS 帧」，输出「屏上一块常驻卡 + 交互事件」；与瞬态窗共享类、不共享状态。
- destination 路由：纯函数，`(request, destination, platform) → consumer`。

## 4. 数据流

```
外部 app 复制（或 Textractor 自动复制）
  → clipboard_watcher（Win: AddClipboardFormatListener 事件，非轮询）
  → DesktopLookupService（app 级生命周期，AppModel 持有）
      · shouldTriggerOnClipboard：app 前台复制不触发（现状保留）
      · dedupeClipboard：同上次/空白吞掉（现状保留）
      · ignoreClipboardTexts：命中抓选区登记的文本 → 一次性吞掉（§8 新增）
      · kMaxLookupInputChars=2000 截断（现状保留）
  → 按 desktop_clipboard_destination 路由：
      main      → pendingRequest → HomeDictionaryPage 消费（现状，语义一字不改）
      panel     → ClipboardPanelController.update(text)
                    → AppModel.searchDictionary（整句自动查一次，autoRead 遵循现有开关）
                    → buildStackRenderScript(sentence: text)   // 句子横幅 = 剪贴板全文
                    → channel render → 面板窗 renderStack 原地替换 root
                    → 窗未显示则按记忆 rect 显示（不夺焦点，NOACTIVATE）
      transient → GlobalLookupController.lookupText(text)      // 现有瞬态窗，光标处弹卡
```

面板「原地更新」与瞬态「隐藏-离屏自测-reveal」的关键差异：面板 rect 固定，**跳过离屏自测**，直接 `renderStack` 替换——内容超高走内滚，不调窗口尺寸，因此无闪、无跳位。

## 5. 交互细节（面板窗）

- **拖动**：host 顶部窄 grip 条，JS mousedown → `postMessage(dragStart)` → native `ReleaseCapture()` + `SendMessage(WM_NCLBUTTONDOWN, HTCAPTION)`。NOACTIVATE 窗拖动不夺焦点。松手后 native 读回 rect → Dart 存 pref。
- **图钉**：grip 条上按钮，切 `SetWindowPos(HWND_TOPMOST/HWND_NOTOPMOST)`。默认钉住（游戏场景刚需）。注：独占全屏游戏 TOPMOST 也盖不住，文档注明需无边框窗口化——平台限制，不是 bug。
- **×（关闭）**：藏窗 + 暂停面板路由（`ClipboardPanelController.paused=true`）。重唤两途：设置开关；或 Ctrl+Shift+D（现有热键语义=「立即查当前剪贴板」，destination=panel 时顺带取消暂停并显示面板——同一语义，零特殊分支）。
- **点窗外 / 切前台**：**不关**（不装 dismiss 钩子）——这就是常驻语义本身，不是遗漏。
- **嵌套卡**：句子条逐字点 / 卡内点词 → 现有 iframe 级联，`computeFrameRect` 边界参数从工作区换成面板 rect（纯函数换参，`global_lookup_layout.dart:92-169`）。子卡点空白处收子层、每层 × ——全现状。
- **调尺寸**：面板右下角 resize grip，同 HTCAPTION 手法发 `HTBOTTOMRIGHT`。存 pref。
- **恢复位置**：启动/重唤时 rect clamp 到当前可见工作区（防显示器拔掉后窗丢屏外）。

## 6. 半透明（唯一技术 gate）

- 逐像素透明底子已有：`put_DefaultBackgroundColor({0,0,0,0})`（`global_lookup_window.cpp:614-619`，TODO-893）。
- 半透明 = 卡片背景 CSS `rgba`：`buildPopupSettingsJs` 加 `--hibiki-card-bg-alpha` 变量（面板传用户值，in-app 与瞬态窗恒 1.0——现有表面零变化）。文字/外字图全不透明，只淡背景。
- 设置滑杆 50%–100%，默认 85%。
- **M0 gate**：真机验证 WebView2 在非 layered HWND 上对半透明像素的合成（能否真透出底下游戏画面）。代码注释只佐证了全透明像素（TODO-893），半透明未验。**gate 失败降级**：面板用不透明暗色紧凑卡，滑杆隐藏——设计其余部分不受影响。

## 7. 设置、生命周期与向后兼容

### 新增/调整 prefs
| key | 类型/默认 | 说明 |
|---|---|---|
| `desktop_clipboard_destination` | string `main`（默认） | `main` / `panel` / `transient`；`panel`/`transient` 仅 Windows 且覆盖窗 `isSupported` 时可见 |
| `clipboard_panel_opacity` | double `0.85` | 卡片背景不透明度，0.5–1.0 |
| `clipboard_panel_rect` | string（逻辑像素 `x,y,w,h`） | 位置/尺寸记忆，恢复时 clamp 工作区 |
| `clipboard_panel_pinned` | bool `true` | TOPMOST 图钉 |

- `desktop_clipboard_enabled` 总开关**不动**；`desktop_clipboard_window_mode`（主窗置顶三段）仅 `destination==main` 时显示（它管的是主窗）。
- 设置项挂现有 Lookup 页「Lookup Behavior」section，紧跟现有剪贴板三项（`settings_schema_lookup.dart:277-351`）。
- i18n 全部经 `hibiki/tool/i18n_sync.dart`，改后 `dart run slang` + `dart format`。

### 生命周期上移（数据结构修正，不是行为破坏）
现状：`DesktopLookupService.start/stop` 绑在 `HomeDictionaryPage` initState/dispose（`home_dictionary_page.dart:154-164,222-226`），且 `app_model.dart:882-886` 注释明确守卫「HomePage 根节点不常驻监听」——那是「去向只有主窗 tab」时代的产物。改为：

- **AppModel 持有 start/stop**（enabled 开 → start；关 → stop），`HomeDictionaryPage` 退化为 `destination==main` 时的消费者（addListener/consume 逻辑原样保留，TODO-376 的 post-frame 消费兜底继续成立）。
- `destination==main` 的用户可见行为**一字不改**：不抢前台（TODO-1355 policy 保留）、结果落 tab、热键唤前台。唯一内部差异是 watcher 在 tab 未挂载时也在跑——pending 排队语义本来就支持（TODO-376）。
- `app_model.dart:882-886` / `home_page.dart:224,273-279` 的守卫注释同步改写，防后人按旧注释「修复」回去。

### 兼容红线（Never break userspace）
- 默认 `destination=main` → 已开启剪贴板查词的存量用户升级后行为零变化。
- 瞬态覆盖窗（Ctrl+Alt+D）的全部现状不动；面板是加窗，不改旧窗。
- `desktop_clipboard_window_mode` 旧值与旧 bool 迁移链（`preferences_repository.dart:398-418`）不动。

## 8. 顺手根修：抓选区剪贴板事件泄漏

**坐实的潜在 bug**（TODO-617 spec 第 58 行规划过「抑制 clipboard_watcher 自触发」，但从未实现——`selection_capture_ffi.dart` / `global_lookup_controller.dart` / `desktop_lookup_service.dart` 均无护栏）：

Ctrl+Alt+D 抓选区 = 存旧剪贴板 → 清空 → 注入 Ctrl+C（目标 app 写入选区）→ 读取 → 恢复旧值（`selection_capture_ffi.dart:53-166`）。每步都发 `WM_CLIPBOARDUPDATE`，此刻 app 必不在前台（`shouldTriggerOnClipboard` 放行）：
- 清空 → `dedupeClipboard` trim 成 null 吞掉（侥幸无害）；
- **选区文本 → 泄漏一次假查词**（与覆盖窗显示的重复）；
- **恢复的旧文本 → 泄漏一次陈旧查词**。

现状症状藏在主窗 tab 后台（不可见）；`destination=panel` 后会变成**可见的错句闪烁**。修法（数据契约，非时间窗 hack）：

- `DesktopLookupService.ignoreClipboardTexts(Set<String> texts)`：按文本登记一次性忽略集；`_handleClipboardChange` 命中即消耗并跳过。
- 登记时机：捕获流程里「读到选区文本之后、恢复旧值之前」登记 `[捕获文本, 旧剪贴板文本]`（清空步产生的空文本本就被 dedupe 吞掉，无需登记）；抓取失败/超时路径登记实际已写入剪贴板的值。
- 纯函数化：`shouldIgnoreClipboardText(text, ignoreSet) → (ignore, nextSet)`，直接可测。
- 实现计划中先真机复现现状泄漏（一条集成断言），修后同路径转绿——按 BUG 流程建档（`dart run tool/bug.dart new`）。

## 9. 测试与验证

**纯函数/widget 层（可离屏落地）**
- destination 路由：`(request, destination, platform) → consumer` 全组合。
- `shouldIgnoreClipboardText`：登记-命中-消耗-未命中四态。
- 面板几何：`computeFrameRect` 以面板 rect 为边界的级联 clamp；rect 恢复 clamp 工作区。
- pref 默认值/迁移：`destination` 缺省 `main`；面板三 pref 默认值。
- 源码守卫：`HomeDictionaryPage` 仅 `destination==main` 消费；面板实例不装 dismiss 钩子（grep native Options 传参）。

**真机 gate（Windows，`run_windows_itest.ps1` + observe_capture 抓真像素）**
- M0：半透明像素合成（面板卡下垫花屏背景，像素比对透出率）。
- 拖动/图钉/×/重唤/记忆位（focus-driver 驱动）。
- VN 流 E2E：脚本连发剪贴板写入，断言面板原地更新、无闪烁、焦点始终在前台 app。
- 抓选区泄漏修复：Ctrl+Alt+D 后面板/主窗 tab 无假更新。

## 10. 里程碑

| 阶段 | 内容 | 可独立回退 |
|---|---|---|
| M0 | 半透明合成真机 spike（现有瞬态窗改 rgba 试渲，不落库）——**gate** | 是（纯验证） |
| M1 | `destination` 设置 + AppModel 生命周期上移 + transient 接线（方案三副档）+ §8 泄漏根修 | 是 |
| M2 | native Options 化 + 第二窗实例 + channel + 面板布局模式 + `ClipboardPanelController`（此步结束面板可用：显示/更新/嵌套/制卡） | 是 |
| M3 | grip 拖动 + 图钉 + × 暂停/重唤 + 透明度滑杆 + 位置尺寸记忆 | 是 |
| M4 | 打磨：多显示器/DPI、i18n 17 语言、docs、设置 hint 文案 | 是 |

## 11. 决策记录

| 决策点 | 结论 | 理由 |
|---|---|---|
| 弹窗宿主 | 第二个裸 WebView2 覆盖窗实例 | 与瞬态窗关闭语义不同，两实例零 mode 分支；不起第二 Flutter engine（TODO-617 三坑） |
| 半透明 | CSS 卡背景 rgba + 透明度滑杆；整窗 alpha 不做 | `WS_EX_LAYERED` 与 WebView2 组合表面不共存；只淡背景保文字可读 |
| 主场景交互 | 常驻 + 原地更新 + 点外不关 + 默认置顶可解钉 | 用户确认主场景=游戏/VN 自动复制流；yomitan 三痛点反推 |
| 副档 | `transient` 去向复用现有瞬态窗 | 成本≈0，覆盖「偶尔复制」场景 |
| 剪贴板去向 | 三选 `main`/`panel`/`transient`，默认 `main` | 存量用户零破坏 |
| 服务生命周期 | 上移 AppModel，tab 退化为 main 消费者 | 面板要求 app 级监听；单一拥有者消灭双生命周期特例 |
| 抓选区泄漏 | 按文本一次性忽略集，随本期必修 | panel 模式下由隐性变显性；文本契约优于时间窗 |
| texthooker 接入 | 本期不做，留 `ClipboardPanelController.update(text)` 入口 | WS 行流与剪贴板同形，后续一根线 |
| macOS/Linux | 维持主窗 tab | 覆盖窗 Windows-only；需求未出现 |
