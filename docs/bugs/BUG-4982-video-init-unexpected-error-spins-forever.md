## BUG-4982 · 视频页打开时未预期异常不进失败态，永久转圈
- **报告**：2026-11-20（来源：路线图 #3722 c31 的 video-2，代码审读复核成立）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_fushi_page.dart:4354-4361`（基准 `origin/develop@7745effa2e`）：`_init()` 对 `_initVideo()` 的未预期异常只做收藏来源上报就 `rethrow`，而 `initState`（`:3988`）与 `_retryLoad`（`:13192`）都是 fire-and-forget 地调它——异常落进无人 await 的 future，`_failed` 从未置位，页面停在加载态：没有原因、没有重试入口。会走到这里的是 `_initVideo` 里没有局部 try/catch 的步骤：读库行（`widget.repo.getByBookUid`）、合集成员 / 刮削元数据查询、`_applyLoad` 里 `controller.load` 之前的 `resolveEnabledShaderPaths` / `listLuaScriptPaths` 等。后者抛出时首开新建的在途控制器（`_pendingController`）也一直挂到退页。
- **[x] ① 已修复** — `_init` 统一 catch：记错误日志、撤掉自己首开登记且尚未交给 `_controller` 的在途控制器、置 `_failed` / `_failReason`（经 `_describeLoadFailure`），不再 rethrow；`_retryLoad` 走同一个 `_init`，一并覆盖。提交 `6e3b58612c`（分支 `pr/video-page-load-failures`）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_page_load_failures_test.dart`「init 的未预期异常进入失败态并给出重试入口」：注入读库行即抛的 `VideoBookRepository`，断言进入失败态、失败页标题可见、加载态消失、无在途控制器。把 catch 改回 rethrow 的变异下该用例红（实测）。
- **备注**：未做设备复测（本轮所有者定不做真机 / 模拟器验证）。
