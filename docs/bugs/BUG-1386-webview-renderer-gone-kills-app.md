## BUG-1386 · Android renderer 被回收时未接管 onRenderProcessGone，整个 app 被系统杀掉

- **报告**：2026-08-02（看板 TODO-2589 收口，源自 PR#690 修启动预热时暴露的同类缺口）
- **真实性**：✅ 真 bug（真机崩溃风险，非只影响 CI）

### 根因

Android 上一个 WebView 的 HTML 渲染跑在独立的 chromium renderer 子进程里。系统内存紧张时会回收
它（`didCrash=false`）。此时后果由 `WebViewClient.onRenderProcessGone` 的返回值决定 ——
本仓 vendored 的
`third_party/flutter_inappwebview_android/android/src/main/java/com/pichillilorenzo/flutter_inappwebview_android/webview/in_app_webview/InAppWebViewClientCompat.java:811-822`：

```java
if (webView.customSettings.useOnRenderProcessGone && webView.channelDelegate != null) {
  webView.channelDelegate.onRenderProcessGone(didCrash, rendererPriorityAtExit);
  return true;                                    // 自报接管，只有那一个 WebView 白屏
}
return super.onRenderProcessGone(view, detail);   // 没接管 → AwBrowserTerminator 杀掉整个 app 进程
```

注意 Java 侧是**发完事件立刻 `return true`**，而 Dart 回调签名是 `void`，返回值回不到 Java。
所以**救 app 的唯一动作就是「传了非 null 的 `onRenderProcessGone`」**：
`third_party/flutter_inappwebview_android/lib/src/in_app_webview/in_app_webview.dart:444-445`
（headless 侧 `headless_in_app_webview.dart:380-381`）在
`params.onRenderProcessGone != null && settings.useOnRenderProcessGone == null` 时把
`useOnRenderProcessGone` 自动推成 `true`，从而走进上面那个 `return true` 分支。回调体里写什么
只影响「死后能恢复多少」，不影响「app 是否被杀」。

PR#690（BUG-1372）只修了 `main.dart` 的启动预热那一处。`lib/` 下**另外 5 处**构造全部没传这个
回调，五处同构地暴露在同一颗地雷上：

| 站点 | file:line |
|---|---|
| 漫画阅读器 | `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:2899` |
| EPUB 阅读器 | `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:1654` |
| 词典弹窗 | `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart:1249` |
| Lapis 样式编辑器预览 | `hibiki/lib/src/anki/lapis_style_editor_page.dart:379` |
| 有声书剪辑离屏渲染（headless） | `hibiki/lib/src/media/audiobook/audiobook_clip_webview_render.dart:173` |

（iOS/macOS 上游已实现且 WKWebView 终止不杀 app，只白屏；Windows fork 原生从不 raise
`ProcessFailed`；Linux 无实现。本条只做 Android 侧崩溃止血。）

### 修复

- **[x] ① 已修复** — 新增单一入口 `hibiki/lib/src/webview/webview_death_guard.dart`
  的 `WebViewDeathGuard`（epoch key + `flushBeforeRebuild` / `afterRebuild` 两个钩子 +
  重建预算），五处各自只声明「抢救什么 / 重建后调哪个已有 restore」：

  | 站点 | flushBeforeRebuild | afterRebuild |
  |---|---|---|
  | 漫画 | `_windowGate.abandon()` + 丢 controller + `_flushPosition()` | `setState` 换 epoch key（恢复锚 `_currentSpread`/`_currentFraction` 实时更新，重建安全） |
  | EPUB 阅读器 | 取消 `_progressPollTimer` + 丢 controller + `_flushPosition()` | **null（只救命不重建）** |
  | 词典弹窗 | 清 `_ready`/controller/推送去重基线 + 置 `_refreshWhenReady` | `setState` 换 key，新 `onLoadStop` 全量重推 |
  | Lapis 预览 | 丢 controller | `setState` 换 key，`onLoadStop → _refreshPreview` 自愈 |
  | 有声书剪辑（headless） | 置 `rendererDead` + 解开 8s load 等待 | null（一次性离屏管线不重建，发 null 帧让调用方回退单句静态） |

  阅读器刻意不重建：恢复锚 `_initialProgress`/`_initialCharOffset`
  （`reader_hibiki_page.dart:1208/1211`）记的是**进入本章那一刻的快照**，章内滚动只更新
  `_lastProgress*`；跨章翻进本章时 `_beginNavigation`（`navigation.part.dart:428-429`）常把它们
  写成 `0.0 / -1`。换 key 强制重建后 restore 会回到章首，紧接着
  `_onRestoreComplete → _refreshProgress → _debouncedSavePosition` 把回退位置如实落库，把 DB 里
  更靠后的真实进度覆盖掉。另有两处硬阻塞：`webview.part.dart:1809-1821` 的
  `debugEvaluateJavascript == null` 断言只在 dispose 清（State 不重建 ⇒ 第二次
  `onWebViewCreated` 必炸），`navigation.part.dart:903-907` 的 `_refreshProgress` 无 try/catch。
  白屏可退出重进，进度写回退不可逆 —— 两害相权本轮只救命。

- **[x] ② 已加自动化测试** —
  - 源码扫描守卫 `hibiki/test/webview/webview_render_process_gone_guard_test.dart`：正向规则扫全
    `lib/`（词法掩码后找以独立标识符身份出现的 `InAppWebView(` / `HeadlessInAppWebView(` 构造，
    窗口由 `enclosingCall` 括号配对给出），断言**每一处**都传了非 null 的
    `onRenderProcessGone`，且没有哪处把 `useOnRenderProcessGone` 显式写成 `false`
    （唯一一种「回调传了、Java 侧仍回落 super」的假绿写法）。发现数为 0 或少于当前已知 6 处
    一律 fail，防重构后守卫静默空跑。
  - 行为测试 `hibiki/test/webview/webview_death_guard_test.dart`：flush 先于 rebuild、epoch 换
    key、flush 抛错不挡重建、重建预算封顶、`afterRebuild == null` 只救命、同一次死亡重入丢弃。
  - 变异实测：摘掉 Lapis 那处的 `onRenderProcessGone` → 守卫红并精确报出
    `lib/src/anki/lapis_style_editor_page.dart:402 InAppWebView —— 没有 onRenderProcessGone 参数`；
    给该处加 `useOnRenderProcessGone: false` → 第三条断言红；把该处换成不走
    `WebViewDeathGuard` 的内联闭包 → 守卫仍绿（验不误伤）。

- **备注**：Windows fork（`packages/flutter_inappwebview_windows`）原生侧从不 raise
  `ProcessFailed`，那边注册 `onRenderProcessGone` 是死代码，要改 C++，属独立工作量，本条不含。

### 派生（TODO-2603）：阅读器「能重建」的三处前置

上面 ① 里那段「阅读器刻意不重建」的理由**已随本次改动失效**，别再照抄。三处前置本轮全部收口，
但**重建本身仍未打开**（`afterRebuild` 依旧是 null）——打开它要连着真机验证（renderer 真死一次、
重建后落点与落库都对），刻意留成独立一轮，本轮只做静态前置。

复核结论（对 `origin/develop` `4d576bc9d`）：三处**当时都仍成立**，没有被别的 PR 修掉或重构走。

| 前置 | 复核到的 file:line（修前） | 根因 |
|---|---|---|
| ① 恢复锚陈旧 | `reader_hibiki_page.dart:1209/1212/1215/1223` 声明；`reader_hibiki/navigation.part.dart:428-434` 写（`_beginNavigation`） | 见下 |
| ② 断言只在 dispose 清 | `reader_hibiki/webview.part.dart:1809-1821` | 钩子生命周期属于 State，断言却按 WebView 实例建模 |
| ③ `_refreshProgress` 无 try/catch | `reader_hibiki/navigation.part.dart:903-907` | 报废 controller 上 `evaluateJavascript` 抛 → 未捕获异步错误 |

#### 前置 ① 的真根因不是「值偶尔是 0」，是**一个状态被两种语义共用**

`_initialProgress` / `_initialCharOffset` / `_initialCharOffsetEnd` / `_initialFragment` 同时充当
「本次导航的待消费目标」和「新建 WebView 该恢复到哪」。前者一次性、后者要一直有效，于是恢复落定
之后这组字段就变成一张过期的进章快照（跨章翻页恒 `0.0 / -1`）。重建 restore 回章首 →
`_onRestoreComplete → _refreshProgress → _debouncedSavePosition` 把回退位置如实落库 → **覆盖掉
DB 里更靠后的真实进度**。

**修法是切生命周期 + 定唯一所有者**，不是加「锚是不是 0」的判据：

- 阶段 ①（`_restoreInFlight == true`）：所有者 = 导航发起方（`_beginNavigation` / `_initBook` /
  `reloadWithCurrentSettings` / 有声书 cue 恢复）。此时实时进度采样读到的还是旧页面，不得覆盖。
- 阶段 ②（恢复落定后）：所有者 = 实时进度采样。`_refreshProgress` /
  `_syncPositionFromWebViewProgress` 每写一次 `_lastProgress*`，就经
  `_adoptLiveProgressAsRestoreAnchor` 让恢复锚跟着走；一次性字段（句尾锚 / 内链 fragment）在接管时
  清空。

于是「恢复锚始终等于当前阅读位置」变成**结构性事实**。原先设想的「崩溃回调里把 `_lastProgress*`
拷进 `_initial*`」那个补丁被整个消掉了——崩溃路径根本不需要知道恢复锚这回事。

判据凿成纯函数 `restoreAnchorOnLiveProgress`（`hibiki/lib/src/reader/reader_restore_anchor.dart`）；
四个字段仍是 State 的存储（既有守卫按字段名钉住导航侧写入形态，改名会连带重写十来个无关守卫，
不值得），只是多了一个 `_restoreAnchor` 聚合读视图 + 一个接管写入口。

- **[x] ① 根因修复**
  - `hibiki/lib/src/reader/reader_restore_anchor.dart`（新）：`ReaderRestoreAnchor` +
    `restoreAnchorOnLiveProgress`。
  - `hibiki/lib/src/pages/implementations/reader_hibiki/navigation.part.dart`：`_restoreAnchor`
    getter、`_adoptLiveProgressAsRestoreAnchor`，接进 `_refreshProgress` 与
    `_syncPositionFromWebViewProgress`；`_refreshProgress` 的 `evaluateJavascript` 补 try/catch +
    `ErrorLogService.log('ReaderHibiki._refreshProgress.eval')`（前置 ③）。
  - `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart` +
    `reader_hibiki_page.dart`：调试钩子断言改成所有者身份判据
    `ReaderHibikiPage.debugHookOwner`（前置 ②），`dispose` 无条件释放所有权。检测力度与旧断言
    等价（另一个 State 抢装仍炸），只是不再把「同一页重装」误判成「两个阅读器同时活着」。
  - `hibiki/lib/src/webview/webview_death_guard.dart`：把「恢复锚是进章快照所以不重建」的理由
    改写成「要具备重建能力就得把恢复锚的所有权修对」，并点名不要用崩溃回调拷贝当补丁。

- **[x] ② 已加自动化测试**
  - 真行为测 `hibiki/test/reader/reader_restore_anchor_test.dart`：`_ReaderProgressLoop` 按真实
    调用顺序跑「跨章进第 3 章 → 恢复落定 → 读到 0.62/char 1500 → renderer 死 → 换 key 重建 →
    restore → 落库」，落库那步走生产的 `readerPositionSaveArgs`，断言重建后落库值 **等于**重建前
    （`normCharOffset 6200 / charOffset 1500`）且 `restoredTo.isChapterStart` 为假；另测恢复在飞
    期间旧页面采样不得顶掉待消费目标、一次性字段接管时清空。
  - 接线守卫 `hibiki/test/reader/reader_restore_anchor_wiring_guard_test.dart`：窗口全部走
    `source_guard.methodBody` 花括号配对，钉住三处前置都接在真实路径上（接管顺序
    `_lastProgress* → 接管 → 落库`、两个采样所有者都接管、身份判据 + `dispose` 释放、
    try/catch 与 fail-open 日志）。
  - 变异实测（改动全部反向文本替换还原，无 `git checkout --`）：
    1. `restoreAnchorOnLiveProgress` 改成恒返回 `current`（锚永不推进）→ 行为测 3 条红，其中
       「读到章中 → renderer 死 → 重建恢复」报 `重建 restore 必须回到用户读到的位置，回章首就是丢进度`；
    2. 从 `_refreshProgress` 摘掉 `_adoptLiveProgressAsRestoreAnchor(...)` → 守卫「接管顺序」条红
       （`Actual: <-1>`）；
    3. 把 `onWebViewCreated` 换回旧的 `debugEvaluateJavascript == null` 断言 → 守卫「身份判据」条红；
    4. 摘掉 `_refreshProgress` 的 try/catch → 守卫「前置 ③」条红（`tryIdx == -1`）；
    5. `dispose` 里删掉 `debugHookOwner = null` → 守卫「dispose 释放钩子所有权」条红；
    6. 把 `_syncPositionFromWebViewProgress` 的接管实参改成 `_lastProgressCharOffset` → 守卫
       「第二个所有者也接管」条红。
  - 顺带修好一处**塌掉的既有守卫**：`hibiki/test/reader/reader_image_page_progress_anchor_test.dart`
    用 `src.substring(idx, idx + 1200)` 定长窗口切 `_refreshProgress`，本轮补 try/catch 后被守的
    `_applyImagePageProgressFallback();` 被挤出窗口 → 红的是守卫自己而不是行为退化。两处定长窗口
    （1200 / 900）改用 `source_guard.methodBody` 的花括号配对。变异实测：摘掉
    `_refreshProgress` 里的 `_applyImagePageProgressFallback();` → 该条仍红（不是改绿了事）。
