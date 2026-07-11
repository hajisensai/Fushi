# 剪贴板查词独立弹窗设计 · 常驻半透明面板 + 瞬态副档

> 状态：设计已确认（2026-07-10），M1-M3 已实现（见同日 -plan.md 与分支
> `worktree-clipboard-panel-spec` 提交序列）；待真机 gate（§6 backdrop / §9）。
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

- **拖动**：host 顶部窄 grip 条，JS mousedown → `postMessage(beginWindowDrag)` → native `ReleaseCapture()` + **`PostMessage`**`(WM_NCLBUTTONDOWN, HTCAPTION)`（真机修复：SendMessage 在 WebMessageReceived COM 回调栈里同步进模态循环会挂住 WebView2 派发=拖不动；PostMessage 让模态循环从消息泵正常启动）。拖/拉结束由 `WM_EXITSIZEMOVE` 统一回报 rect → Dart 存 pref。NOACTIVATE 窗拖动不夺焦点。
- **与主窗解耦（真机修复）**：面板窗**无 owner**（CreateWindowExW 传 nullptr，不传主窗 HWND）——owned 窗随 owner 最小化被系统隐藏（症状=最小化 app 面板跟着没了）、Z 序变更连带 owner（症状=点图钉把主 app 拉前台）。瞬态查词窗保持 owned（短命窗随主窗收纳合理）。`SetTopmost` 补 `SWP_NOOWNERZORDER` 兜底。
- **图钉**：grip 条上按钮，切 `SetWindowPos(HWND_TOPMOST/HWND_NOTOPMOST)`。默认钉住（游戏场景刚需）。注：独占全屏游戏 TOPMOST 也盖不住，文档注明需无边框窗口化——平台限制，不是 bug。
- **×（关闭）**：藏窗 + 暂停面板路由（`ClipboardPanelController.paused=true`）。重唤两途：设置开关；或 Ctrl+Shift+D（现有热键语义=「立即查当前剪贴板」，destination=panel 时顺带取消暂停并显示面板——同一语义，零特殊分支）。
- **点窗外 / 切前台**：**不关**（不装 dismiss 钩子）——这就是常驻语义本身，不是遗漏。
- **嵌套卡**：句子条逐字点 / 卡内点词 → 现有 iframe 级联，`computeFrameRect` 边界参数从工作区换成面板 rect（纯函数换参，`global_lookup_layout.dart:92-169`）。子卡点空白处收子层、每层 × ——全现状。
- **选词区/释义分流（真机第 4 轮修正，取代上一条的面板内语义）**：
  - **选词区（句子条）**：字号与词条正文一致（`.global-lookup-sentence-panel`，1em 主色），视觉为连续正常文本（无逐字 hover 框；逐字 span 只作码点→点击位映射）。点字 → `panelSentenceLookup` 桥（后缀 + 码点下标）→ Dart `_lookupFromBanner` **换根结果=底部原地更新**（与剪贴板流同一 latest-wins 序列），不再嵌套压卡；引擎 `bestLength` 折算码点后经 `__globalLookupSentenceHit` 整词高亮（「按正常的断词」=词典引擎分词）。
  - **释义文字点击**：`onLinkClick`/`textSelected` → **独立瞬态覆盖窗**（`GlobalLookupController.lookupText`，OS 光标处、点外即关、携带整句供制卡）——子 iframe 出不了面板 HWND，「弹窗可越出面板边界」唯一真解是第二个顶层窗。瞬态窗不可用时回退面板内嵌套卡（点击绝不丢）。瞬态窗自身的句子条/嵌套语义不变（`__globalLookupPanelRoot` 仅面板 root 注入）。
- **焦点（真机第 4 轮）**：面板窗**可激活**（`SetActivatable(true)`：创建时不带 `WS_EX_NOACTIVATE`）——点击面板焦点落面板、游戏失焦，滚轮不再穿透滚动底下的游戏；程序化 show/update 全程 `SW_SHOWNOACTIVATE`/`SWP_NOACTIVATE`，台词流更新绝不抢游戏焦点。瞬态覆盖窗保持 NOACTIVATE（§5 保证 3）。
- **释义点击反馈与定位（真机第 5 轮）**：①被点的释义/见出语/汉字标签加 `.global-lookup-ext-hit` 高亮（`markGlobalLookupExtHit`，下次点击替换、重渲清除；仅面板 root，嵌套卡/in-app 自有反馈）；②外部瞬态窗**锚定被点文字正下方**而非 OS 光标点：host 重锚定的面板窗内 CSS px 矩形 + `_panelRect` 原点 = 屏幕逻辑 px，经 `lookupText(anchorScreenRect:)` 传入，native `showAt(atCursor:false)` 直接用该点并以其算工作区偏移（级联种子自动对齐，零 native 改动）；无锚点调用方（热键/悬浮字幕）保持 atCursor 语义。
- **窄宽度词典列收敛（真机第 5 轮）**：TODO-1357 的「窄屏不硬塞多列」只按平台定默认（桌面 2 列），面板拖窄后固定多列玻璃卡互相挤压重叠——popup.js `updateEffectiveDictColumns` 按真实视口宽度算 `--dict-columns-effective = min(用户设置, floor(宽/170px))`，grid 消费 effective 变量（缺席回退原值），resize 监听即时收敛（in-app 弹窗同规则受益）。附带修 `_renderPanel` 的 `clamp(160, viewport)` 在视口 <160 时下界>上界抛 ArgumentError 的面板假死。
- **调尺寸**：面板右下角 resize grip，同 HTCAPTION 手法发 `HTBOTTOMRIGHT`。存 pref。
- **恢复位置**：启动/重唤时 rect clamp 到当前可见工作区（防显示器拔掉后窗丢屏外）。

## 6. 半透明（唯一技术 gate）

- 逐像素透明底子已有：`put_DefaultBackgroundColor({0,0,0,0})`（`global_lookup_window.cpp:614-619`，TODO-893）。
- 半透明 = 卡片背景 CSS `rgba`：注入 `--hibiki-card-bg-rgb` 三元组 + 面板路径注入 `--hibiki-card-bg-alpha`（默认 1，in-app 与瞬态窗零变化）。文字/外字图全不透明，只淡背景。
- 设置滑杆 50%–100%，默认 85%（整窗 alpha：看清底下游戏与面板正文的平衡点）。
- **实现期修正（2026-07-10）**：调查证实非 layered 顶层窗对桌面是不透明的
  （popup.css:1225 注释）——纯 CSS rgba 只对「窗口底色」半透明，**透不到底下
  的游戏**。真透视走 **Win11 `DWMWA_SYSTEMBACKDROP_TYPE`(acrylic) +
  `DwmExtendFrameIntoClientArea`**（`GlobalLookupWindow::ApplySystemBackdrop`，
  面板 channel `applyBackdrop` 返回 OS 是否接受）；`WS_EX_LAYERED` 仍不可用
  （与 WebView2 组合表面不共存），不碰。
- **Win10 回退（2026-07-10 用户要求研究后补）**：Win10 无文档化 per-window
  backdrop，唯一可行路 = 未文档化 `SetWindowCompositionAttribute` ACCENT_POLICY
  （TranslucentTB/EarTrumpet 用了近十年；Win10 功能冻结，消失风险趋零）。刻意用
  `ACCENT_ENABLE_BLURBEHIND(3)` 而非 `ACRYLICBLURBEHIND(4)`——acrylic accent 自
  Win10 1903 起有从未修复的拖动/缩放卡顿回归，而面板靠 HTCAPTION 拖动摆位会正面
  命中；BLURBEHIND 无此 lag，仍是「模糊+半透明」。GradientColor 带 0x01 alpha
  黑 tint（部分版本 alpha=0 不生效）。透明度链：Win11 acrylic → Win10 blur →
  都不行才不透明。
- **M0 gate 真机结论（2026-07-10 用户实测）：acrylic 路线判死**——①用户可见
  面板完全不透明（backdrop 未能透过 windowed WebView2 子窗合成）；②即使合成
  成功，acrylic 是毛玻璃（重度模糊+着色），本就看不清底下的游戏/网页，不满足
  「透视」诉求。
- **最终机制（第二轮修正）：整窗 LWA_ALPHA**——`WS_EX_LAYERED` +
  `SetLayeredWindowAttributes(LWA_ALPHA)`（`GlobalLookupWindow::SetWindowAlpha`，
  面板 channel `setWindowAlpha`）。整窗（含文字）统一变淡、真透视底下内容；
  Win10/11 通用（无需能力探测，原 backdropOk 门控删除，滑杆恒可用）；查证
  WebView2 + 整窗 LWA_ALPHA 有工作先例（CppWeb 样例 80%），不可行的是
  LWA_COLORKEY。关键坑：设 layered 位后必须立刻调 SLWA 否则窗口不渲染。
  注意与早前「WS_EX_LAYERED 与 WebView2 不共存」注释的区分：那是逐像素/
  colorkey 路线的结论，整窗 uniform alpha 不受影响。
- acrylic/accent 链（`ApplySystemBackdrop`）保留在 native 供未来（如 DComp
  逐像素路线的降级）复用，面板不再调用；卡背景 CSS alpha 基建同理保留、面板
  恒传 1.0（双重变淡会让文字更虚）。

## 7. 设置、生命周期与向后兼容

### 新增/调整 prefs
| key | 类型/默认 | 说明 |
|---|---|---|
| `desktop_clipboard_destination` | string `panel`（默认，用户 2026-07-10 拍板改） | `main` / `panel` / `transient`；`panel`/`transient` 仅 Windows 且覆盖窗 `isSupported` 时可见；非 Windows 路由自动退回 main |
| `clipboard_panel_opacity` | double `0.85` | **整窗**不透明度（LWA_ALPHA 真透视），0.5–1.0 |
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
- **默认 `destination=panel`（2026-07-10 用户显式拍板，覆盖初版「默认 main 零
  破坏」决策）**：Windows 存量用户若已开启剪贴板查词，升级后复制改弹独立面板
  ——这是产品决策不是事故；显式选过 `main` 的用户不受影响（存值优先）。
  macOS/Linux 覆盖窗不可用，路由自动退回主窗 tab，行为不变。
- 预热双条件门控：仅「剪贴板查词开 且 destination==panel」才预热第二
  WebView2——开关关着的用户（出厂默认）零额外进程。
- 瞬态覆盖窗（Ctrl+Alt+D）的全部现状不动；面板是加窗，不改旧窗。
- `desktop_clipboard_window_mode` 旧值与旧 bool 迁移链（`preferences_repository.dart:398-418`）不动。

## 8. 顺手根修：抓选区剪贴板事件泄漏

**坐实的潜在 bug**（TODO-617 spec 第 58 行规划过「抑制 clipboard_watcher 自触发」，但从未实现——`selection_capture_ffi.dart` / `global_lookup_controller.dart` / `desktop_lookup_service.dart` 均无护栏）：

Ctrl+Alt+D 抓选区 = 存旧剪贴板 → 清空 → 注入 Ctrl+C（目标 app 写入选区）→ 读取 → 恢复旧值（`selection_capture_ffi.dart:53-166`）。每步都发 `WM_CLIPBOARDUPDATE`，此刻 app 必不在前台（`shouldTriggerOnClipboard` 放行）：
- 清空 → `dedupeClipboard` trim 成 null 吞掉（侥幸无害）；
- **选区文本 → 泄漏一次假查词**（与覆盖窗显示的重复）；
- **恢复的旧文本 → 泄漏一次陈旧查词**。

现状症状藏在主窗 tab 后台（不可见）；`destination=panel` 后会变成**可见的错句闪烁**。修法（数据契约，非时间窗 hack）：

- **实现期修正（代码审查发现）**：captured 回声可能在抓取轮询的 await 间隙
  **先于事后登记**到达——单靠「读到文本后登记忽略集」拦不住主泄漏路径。方案
  升级为**捕获期括号**（仍是文本契约，不是时间窗）：
  - `DesktopLookupService.beginSelfInflictedCapture()`：抓取方在首次写剪贴板前
    开括号，期间到达的剪贴板事件一律暂存（自产/真实此刻无法区分）；
  - `endSelfInflictedCapture(ignoreTexts)`：抓取完成、恢复写入**之前**收口——
    先登记 `[捕获文本, 旧剪贴板文本]`（拦截收口后才到的恢复回声），再回放暂存
    事件：命中本次自产集合=丢弃，未命中=捕获窗口里的真实用户复制原样放行；
  - `finally` 保证异常路径也收口（括号留开会把后续真实复制卡死在暂存里）。
- 一次性忽略集（`ClipboardIgnoreSet`）保留：吞收口后到达的恢复回声；未命中的
  真实复制使整批登记过期（防陈旧条目误吞用户后续复制）。
- 已按 BUG 流程建档：`docs/bugs/`（selection-capture-clipboard-echo，编号见文件；
  并发分支撞号由 integration owner 落地时统一改号 reindex）。

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
| 剪贴板去向 | 三选 `main`/`panel`/`transient`，默认 **`panel`** | 初版默认 main（零破坏）；2026-07-10 用户拍板改默认独立窗口——面板即本功能的本体 |
| 服务生命周期 | 上移 AppModel，tab 退化为 main 消费者 | 面板要求 app 级监听；单一拥有者消灭双生命周期特例 |
| 抓选区泄漏 | 按文本一次性忽略集，随本期必修 | panel 模式下由隐性变显性；文本契约优于时间窗 |
| texthooker 接入 | 本期不做，留 `ClipboardPanelController.update(text)` 入口 | WS 行流与剪贴板同形，后续一根线 |
| macOS/Linux | 维持主窗 tab | 覆盖窗 Windows-only；需求未出现 |
| 面板自动朗读 | 面板**故意不接** autoReadOnLookup | VN 台词流逐句自动发音会与游戏配音叠放刷屏；瞬态窗（单次显式查词）保持接入 |
| 面板预热时机 | 仅 destination==panel 时预热第二 WebView2 | 默认 main 的用户不为面板常驻进程树（零破坏承诺）；切到 panel 时补预热 |
| 面板更新并发 | latest-wins 序号（每个 await 后核对） | VN 流下旧句结果可能后完成覆盖新句（审查发现） |
