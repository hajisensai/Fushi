# 媒体页焦点所有权（丢快捷键 / 丢鼠标事件）

> [CLAUDE.md](../../CLAUDE.md) 的子文档。改视频页 / 阅读器页 / 漫画页的键盘、鼠标、手柄接线前先读这里。

## 先分清两层，别再合并成「快捷键坏了」

用户报「丢快捷键 / 丢鼠标事件」时，症状几乎从不在**绑定层**：

| 层 | 真相源 | 状态 |
|---|---|---|
| 绑定：哪个键触发哪个动作 | `lib/src/shortcuts/`（`ShortcutRegistry.resolveKeyboard` / `resolveGamepad` / `resolveMouse`、`InputBinding`、`WheelBinding`、`ShortcutScope`） | 早已统一。视频页、阅读器页全量接入 |
| 所有权：此刻谁持有键盘焦点 | `lib/src/focus/page_focus_ownership.dart`（`PageFocusOwnership`） | 2026-07 统一（PR #480） |

**丢键和丢鼠标是同一个机制的两个表现**：原生 WebView2 / media_kit surface 在任一指针手势后捕获 OS 焦点，Flutter 的 `FocusNode` 静默变孤儿，此后键盘和指针一起失联。所以先查所有权，别一上来翻 registry 绑定。

## 规矩：焦点回收只能走 PageFocusOwnership

页面持有一个 `_focusOwnership`，提供一个按 `FocusReclaimCause` 分流的判据（`_canOwnVideoFocus` / `_canOwnReaderFocus`），回收一律经：

- `reclaim(cause)` — 立即按判据回收
- `reclaimAfterFrame(cause)` — 需要等新宿主 build / reparent 时（进出全屏）。**它内部会 `ensureVisualUpdate()`**，因为 `addPostFrameCallback` 本身不调度帧——树静止（视频暂停）时裸用它，回调永不触发（BUG-1168）
- `guardOverlay(() => showDialog(...))` — 包裹一切会夺焦的覆盖层。`try/finally` 覆盖正常返回 / 抛异常 / 被 pop 三条路径

守卫 `hibiki/test/focus/media_page_focus_ownership_guard_test.dart` 禁止媒体页出现**任何形式**的 `requestFocus`（按裸 token 扫、按文件放行——`FocusScope.of(context).requestFocus(node)` 和经局部变量中转同样拦得住）。**别为了省事绕过它**：统一之前视频页 29 处、阅读器页 28 处补丁各带一套略有出入的门控，新增一个覆盖层就漏一处归还（BUG-1167 即此），这是回不去的老路。

唯一豁免：整个 `reader_hibiki/caret.part.dart`——popup header ↔ 正文之间的焦点来回是**页面内部**焦点转移（两个都归 Flutter 的节点之间搬运），不是「从原生控件手里夺回」。

## cause 不是装饰，判据真的按它分流

同一个页面对「弹窗可见时该不该抢焦点」有**相反**的正确答案，这是历史上最容易接错的一处：

- `gesture`（手势后）：弹窗可见 → **不抢**。弹窗是合法的 Flutter 焦点所有者（BUG-136）
- `popupRendered`（指针唤出弹窗后）：弹窗可见 → **必须抢**。词典弹窗是纯原生 WebView、没有 Flutter 焦点节点，不把焦点拉回正文，关词典键就永远抵达不了 `_handleKeyEvent`（BUG-1071 ②）
- `appResumed`：额外判 `ModalRoute.isCurrent`。这是全局生命周期回调，页面上方压着对话框时抢焦点会夺走它的键盘（Never break userspace）
- `chromeToggled`（本页底栏显隐）：**无条件收回**。底栏整体是 `ExcludeFocus`，任何时刻都不是合法的焦点所有者，没有「让位给谁」这回事——这里只是重新确认焦点仍在正文（已持焦时纯 no-op）。**别复用 `overlayClosed`**：后者带着「内容未就绪 / 歌词态 / 光标态 / 弹窗态一律不抢」的严格门控，套到切底栏上就成了「歌词模式下切一次底栏键盘再也回不来」（守卫 `hibiki/test/reader/reader_chrome_focus_guard_728_test.dart`）

新增回收点时先想清楚属于哪个 cause，别习惯性复制最近的一行。cause 判据里最容易错的一类，就是把「本页自己的 chrome」和「压在本页之上的覆盖层」混成一个。

## WebView 宿主还要一层：键盘桥

焦点抢回来只解决「OS 焦点归 Flutter」的情况。焦点归 WebView2 期间按下的键**只存在于 DOM 里**，必须在内容层截获后交回 Dart——桌面 Windows 上 fork 的 `flutter_inappwebview_windows` 只转鼠标不转键盘。

用 `lib/src/focus/webview_key_bridge.dart` 的 `webViewKeyBridgeScript({handlerName, keys})`，别自己写一份 `keydown` 监听：它固化了「只拦裸键、放行修饰键组合 / IME composing / `input|textarea|contenteditable`、命中才 `preventDefault`」这套判据，漏一条就是吃掉用户改键语义或打不出空格。

生成结果整体裹在 `;(function () { … })();` 里，键表关在闭包中：同一 document 注入多份桥（阅读器一份、漫画页规划中再一份）时，若键表是脚本级全局 `var`，后注入的一份会把先注入的整个覆盖掉而两个 listener 都还在，表现为「某一页的键突然全不响应」。前导 `;` 是拼接安全惯例（本脚本插在 setup 大脚本中间）。

改动注入脚本后注意 `hibiki/test/reader/reader_script_compactor_test.dart`：给 setup 模板新增插值必须在它的替身表里登记，否则该守卫直接 `StateError`（它保证最终拼装脚本的压缩有覆盖，并用 node `--check` 真解析）。

## 已知未接入：漫画页

`manga_hibiki_page.dart` 至今是硬编码 `if (key == LogicalKeyboardKey.arrowRight)`：不查 registry（不能改键、无手柄）、丢 `KeyRepeatEvent`（按住方向键不连翻）、零焦点回收、JS 侧无 keydown 桥。桌面上在漫画 WebView 里点/拖一次之后方向键翻页即失效且**无自愈路径**。

接入时要做的：`ShortcutScope.manga` + manga action 集 + 默认绑定 + i18n（走 `hibiki/tool/i18n_sync.dart --add`，禁手改 json）+ `PageFocusOwnership` 实例 + 键盘桥。**动手前先确认漫画在线源那批 PR（#411 / #417 系）已落地**，否则必然撞车重做。
