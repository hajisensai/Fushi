## BUG-1809 · iOS歌词loadData返回后不触发onLoadStop导致永不ready
- **报告**：2026-08-24（`iPhone pay` / iOS 26.6 物理机，从有声书快速设置进入歌词模式）
- **真实性**：✅ 真 bug。阶段探针证明状态持久化、歌词 profile、5 cues / 78KB HTML 生成与 `loadData` 均返回，但 iOS 没有歌词 onLoadStop/ready。继续追到 `webview.part.dart:2505-2519`：iOS 会把 `loadData(baseUrl: https://fushi.local/lyrics)` 交给 `shouldOverrideUrlLoading`，而现有代码只放行 `_isNavigatingToChapter`，歌词主文档没有该旗，遂被当普通链接 `CANCEL`。所以旧正文仍留在 WebView，HTML 内 ready bridge 也没有机会执行。既有 BUG-649 只过滤旧正文 onLoadStop，没有给歌词主文档导航放行。
- **[x] ① 已修复** — 放行歌词主文档导航并增加 ready bridge；提交 `bb1f2ddf7`。完成前并发审查发现多个未等待 `_loadLyricsPage()` 可交错，原全局 bool finalizer 锁会丢掉新文档 ready、让旧 load 清新 load 状态。提交 `a3e82e646` 为每次 load 分配单调 generation，写入 HTML/DOM 并随 `onLyricsReady` 回传；sentinel、finalizer、每个异步注入边界和退出模式均核对/失效 generation，旧文档不能完成新文档。复核继续发现导航放行/主框架 error 仍共享 bool；提交 `0e7caed50` 把 generation 写入 `https://fushi.local/lyrics?generation=N`，shouldOverride 与 onReceivedError 只放行/清理当前 N，旧 error 不能关闭新 load 的导航窗口。
- **[x] ② 已加自动化测试** — HTML ready 契约与 iPhone 歌词 DOM/截图 GREEN；补充：合入前发现
  `lyrics_mode_html_test.dart` 的 generation 断言只覆盖默认值 `loadGeneration = 0`，把源码两处
  `$loadGeneration` 写死成 `0`（正是本修复要消灭的复发形态）照样全绿；已补
  `load generation is interpolated, not hard-coded to the default 0`（`loadGeneration: 7`），变异实测该写死
  改动使其单独变红。注意这几条 itest（`reader_lyrics_mode_entry_itest.dart` 等）**不在任何 runner 里**，
  真单测门 `flutter_test_failures.dart` 只跑 `test/`，只能真机/模拟器手跑。RED 曾连续 60 秒超时并停在 `loadData returned`。generation 加固新增 HTML token/bridge 测试和完整 source-chain 守卫；缺 token、旧直接调用锚点、无 generation 校验均实测红，相邻 36 条歌词测试全绿。`reader_lyrics_mode_entry_itest.dart` 在持久 Mac 书架上若精确夹具卡片位于 lazy grid 屏外，改按精确 bookKey 走同一生产 openMedia（提交 `c1713cf18`），iPhone 与 macOS 真 Runner 均进入 `https://fushi.local/lyrics` 并通过。
- **备注**：歌词主文档 in-flight 状态已不是 bool，而是当前 URL generation；只在匹配 N 的 loadData 窗口放行 shouldOverride，匹配 N 的 sentinel finalize/主帧错误/退出歌词时清除，不放开后续普通链接。Dart `onLyricsReady` 与原 onLoadStop 共享 generation-aware finalize，双回调幂等、跨 load 回调隔离。iPhone 实机日志确认 `onLoadStop: https://fushi.local/lyrics?generation=1` 后 ready 截图与退出均绿。

### 合入 develop 前的根因收口：ready 通知不再轮询（2026-08-25）

原实现（`lyrics_mode_html.dart`）用「50ms × 100 次 = 5 秒条件轮询 + `requestAnimationFrame` 包装」等 JS bridge。两处都不是根因修法：

- **bridge 有确定的就绪原语**：`window.flutter_inappwebview` 由插件自己的 user script 在
  **AT_DOCUMENT_START** 注入（iOS `InAppWebView.swift:557` + `JavaScriptBridgeJS.swift:16`
  `injectionTime: .atDocumentStart`；Android 同名文件 `InAppWebView.java:564` +
  `UserScriptInjectionTime.AT_DOCUMENT_START`）。document-start user script 按规范先于文档内
  任何 inline script 执行，所以本页 inline 脚本跑到时 bridge 必然已存在——轮询分支在四个平台上
  全是死代码。
- **`requestAnimationFrame` 是同类风险**：本 bug 的前提就是「iOS WKWebView 某些状态下不派
  onLoadStop」，而离屏/后台/未合成的 WebView 同样会节流甚至不跑 rAF。拿一个可能不触发的回调
  兜底另一个可能不触发的回调，等于没兜。

**`flutterInAppWebViewPlatformReady` 不能当主路径**（复审时核过四个平台源码）：

| 平台 | `_platformReady` 标志 | 事件派发点 | 与 onLoadStop 的关系 |
|---|---|---|---|
| iOS `flutter_inappwebview_ios 1.1.2` | **没有**（只 `dispatchEvent`） | `InAppWebView.swift:1925` | 同一个 `webView(_:didFinish:)`，`onLoadStop` 在 `:1934` |
| macOS `flutter_inappwebview_macos 1.1.2` | **没有** | 同上 | 同上 |
| Android（vendored 1.1.3） | 有 | `InAppWebViewClient.java:240` | 同一个 `onPageFinished`，`onLoadStop` 在 `:249` |
| Windows（fork） | 有 | `in_app_webview.cpp:647` | 同一个 `NavigationCompleted` |

即该事件与 `onLoadStop` **同源同触发**，在本 bug 的失效状态下一样不派——改用它会把 iOS 打回原状。

**最终形态**：同步调用 `callHandler('onLyricsReady', $loadGeneration)`；只有同步调用没打出去时才
`addEventListener('flutterInAppWebViewPlatformReady', …, {once: true})` 兜一次。无轮询、无 rAF、无重复触发。
守卫见 `fushi/test/media/audiobook/lyrics_mode_html_caret_test.dart` 的
`ready notifier uses the document-start bridge, not a timer`（三条，变异实测：换回轮询+rAF 版本三条全红）。
