## BUG-1246 · 有声书跨章等待后触发已销毁 State 重绘

- **报告**：2026-07-29（用户：Android 错误日志显示有声书 cue 跨章节时，
  `_handleCueCrossChapter → _navigateToChapter → _beginNavigation → _rebuild`
  最终触发 `State.setState` 的空值断言）
- **真实性**：✅ 真 bug。根因位于
  `hibiki/lib/src/pages/implementations/reader_hibiki/audiobook.part.dart:648-701`：
  `_handleCueCrossChapter` 会先 `await _pauseThroughImageOnlyChapters` 展示中间纯图片章，
  但 await 返回后没有复检 reader 生命周期，直接继续 `_navigateToChapter`。用户在等待期
  退出 reader 时，`dispose` 已 detach 有声书回调并销毁 State，但这个已经在飞的 Future
  仍会返回；`InAppWebViewController` 字段此时仍非 null，因此旧导航入口的
  book/controller 守卫放行，随后 `_beginNavigation` 通过
  `reader_hibiki_page.dart:1110-1113` 的 `_rebuild` 调用已销毁 State 的 `setState`。
  同时，图片章序列的 `finally` 会持住 controller 的 chapter transition，若直接丢弃
  导航而不取消，还会把守卫泄漏给进程级有声书 session。
- **[x] ① 已修复** — 在跨图片章 await 返回后复检 `mounted` 与 controller；页面已退出
  时先取消 chapter transition 再终止旧导航。`_navigateToChapter` 入口同步增加
  `mounted` 生命周期门，统一 `_rebuild` 转发器也在 `setState` 前做最终 mounted 复检，
  三层分别保证异步资源收尾、导航状态机和 State 更新边界不会越过 dispose。
  修复提交：`cda704db6`。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/reader_navigation_dispose_guard_test.dart` 锁定三项顺序契约：
  `_rebuild` 必须先 mounted 后 setState、导航必须在 `_beginNavigation` 前拒绝已销毁
  reader、有声书跨图片章必须在 await 后复检并释放 transition 后才允许最终导航。
  测试随修复提交 `cda704db6` 入库；改动文件定向 `dart analyze` 通过。
- **备注**：同一日志中的互联同步 Socket/HTTP 超时是独立网络错误，不是本崩溃的调用链
  根因，未在本条中混修。定向 `flutter test` 在执行任何断言前被 `pdfium_dart` native
  asset 下载超时阻断；按用户要求不等待完整编译/真机验收，仍应由 PR CI 执行单测，
  并在 Android 真机覆盖“播放跟随跨过纯图片章时立刻退出 reader”路径。
