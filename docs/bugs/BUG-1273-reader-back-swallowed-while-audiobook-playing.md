## BUG-1273 · 有声书播放中侧滑返回无效（退出链 await 停播放器）

- **报告**：2026-07-31（用户）
  > 「句子在播放的时候，手机的侧滑返回无效了，然后等你句子暂停，这个返回就有效了」
  用户补充确认：场景是**阅读器有声书**；暂停之后**那次返回自己生效**（不是要再滑一次）。
- **真实性**：✅ 真 bug。根因在阅读器退出链，不在返回手势 / 焦点 / 沉浸模式。
  - `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` 的 `onSourcePagePop()`
    （旧代码 `await appModel.audiobookSession.stop()`）
  - `hibiki/lib/src/media/audiobook/audiobook_session.dart:242` `AudiobookSession.stop()`
  - `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` PopScope 单飞门 `_popInProgress`

### 根因

阅读器的返回是一条**全程 await 的串行链**，pop 排在最后：

```
PopScope(canPop:false).onPopInvokedWithResult
  └ _popInProgress = true            ← 单飞门：链没跑完，后续每次返回直接 return（静默丢弃）
    └ await onWillPop()
      └ await onSourcePagePop()
         ├ await _syncAndFlushPosition()      // 位置落库（与播放态无关，毫秒级）
         ├ await _flushReadingStats()
         └ await audiobookSession.stop()      ← 问题所在
      └ await closeMedia()
    └ nav.pop()                                ← 直到这里用户才离开页面
```

`AudiobookSession.stop()` 的 await 段是「停 native 播放器 + 销毁解码器」：
`controller.stopPlayback()`（just_audio `_setPlatformActive(false)` 拆平台）+
`controller.disposeAndRelease()`（再 `await _player.dispose()` 真放句柄，TODO-1212）。
这一段**耗时不可控，而且只有播放态才真正干活**——未播放时 native 平台压根没激活，
stop 立即返回；所以用户只在「句子正在播」时遇到。

于是播放中按返回：第一次触发把 `_popInProgress` 顶住 → 后续每一次侧滑/返回键/ESC
都被静默丢弃（无任何 UI 反馈）→ 直到 native 播放器真停下来，`stop()` 才返回，
紧接着 `nav.pop()`。用户看到的顺序正是「声音停 → 页面同时退出」，主观上就是
「等句子暂停，那次返回才生效」。

`audiobookBackgroundPlay`（退出后续播）默认 `false`
（`preferences_repository.dart:207`），所以这条 stop 是默认路径，不是边缘配置。

### 修复

`onSourcePagePop()` 改 `unawaited(audiobookSession.stop().catchError(...))`。

TODO-831 引入这次 await 的动机是「pop 动画首帧下层书架不闪播放条」，但那个语义靠的是
`stop()` 的**同步首段**（第一个 `await` 之前就 `_reader/_controller/_book = null` +
`notifyListeners()`）——Dart 里 async 函数在首个 await 前同步执行，fire-and-forget
一样满足；native 资源释放与「用户已经离开这一页」没有因果关系。
`stop()` 的这条契约已写进 `AudiobookSession.stop()` 的文档注释。

顺带消掉旧代码的 W1 隐患：不再需要 try/catch 防「stop 抛平台异常 → 异常沿 onWillPop
逃逸 → nav.pop() 不执行」，异常由 `catchError` 就地记录。

未改动：`_syncAndFlushPosition` / `_flushReadingStats` 仍 await（BUG-203 要求在 WebView
存活时写穿实时位置，且与播放态无关，暂停态实测返回即时）；`dispose()` 里的
`unawaited(stop())` 兜底保留（二次调用对已清空 controller 是 no-op）；
需要「资源真已释放」的调用方（数据根迁移 TODO-1212）仍 await 全程。

- **[x] ① 已修复** — `unawaited` 化退出路径的 stop + 在 `AudiobookSession.stop()` 上写明同步首段契约
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/reader_back_not_blocked_by_stop_test.dart`
  - 行为层：fake just_audio 平台让 native 释放挂在 gate 上，**播放中**调 `stop()` →
    stop 的 Future 确实不完成（证明 await 它就会吞掉返回），但同步首段已把
    `isActive/controller/book` 清空并 `notifyListeners`（证明 fire-and-forget 不丢 TODO-831）。
  - 源码层：`onSourcePagePop()` 必须 `unawaited(` 调 stop，不得
    `await appModel.audiobookSession.stop()`。
  - 变异实测：① 把退出路径改回 `await` → 源码守卫红；② 在 `stop()` 同步首段插入 await →
    行为层「同步首段必须 notifyListeners」红。两次变异均实测抓到，事后零残留。

### 备注

- 验证限制：本地 Android 14 模拟器上测试书未配对音频、QA 视频文件缺失，**播放态未在真机复现**；
  且 `adb input swipe` 注入事件触发不了 SystemUI 的边缘返回手势（未播放态基线可用返回键复现：
  返回正常退回书架）。根因与修复由退出链代码路径 + 上述行为层测试确证。
- 相邻未改：视频页 `_handleBackOrExit` 也在 pop 前 `await _controller?.flushPosition()`，
  但只是 DB 写、不停播放器，与本 bug 结构不同；如果之后出现「视频播放中返回迟钝」再单独处理。
