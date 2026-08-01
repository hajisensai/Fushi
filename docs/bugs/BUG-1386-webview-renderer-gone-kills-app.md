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
