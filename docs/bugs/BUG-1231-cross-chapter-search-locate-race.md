## BUG-1231 · 跨章节书内搜索只跳到章首且不高亮

- **报告**：2026-07-29（用户：书内搜索命中其他章节时只跳到目标章开头，命中词既不定位也不高亮；同章命中正常）
- **真实性**：✅ 真 bug。根因位于
  `hibiki/lib/src/pages/implementations/reader_hibiki/navigation.part.dart:546-551` 的异步边界
  （修复后的绑定点见同文件 `390-402`）：
  `_navigateToChapterAndWait` 先 `await _navigateToChapter()`，后者内部又
  `await InAppWebViewController.loadUrl()`，返回后才写入 `_pendingPreciseLocate`。
  部分平台上 `loadUrl` 的 Future 返回前，新页面已经完成恢复并触发
  `_onRestoreComplete`；恢复链此时消费到空 pending，随后补写的
  `scrollToSearchMatch` 再无执行入口。因此章节导航本身成功，但章内定位与
  `hoshi-search` CSS Highlight 都没有发生。同章分支不重载页面，直接执行
  `scrollToSearchMatch`，所以不受该竞态影响。
- **[x] ① 已修复** — 把 `preciseLocateJs` 沿
  `_navigateToChapterAndWait → _navigateToChapter → _beginNavigation` 传入，在导航代际
  递增后立即绑定 pending，严格早于 `loadUrl`。新导航仍先清理上一代 pending，
  失败/超时也会清理本代 pending，保留原有代际隔离语义。修复随本 PR 提交。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/chapter_jump_double_jump_atomic_chain_test.dart` 新增时序守卫：
  定位意图必须完整转发到 `_beginNavigation`，绑定点必须位于
  `await _loadChapterDirectly(index)` 之前；同时继续锁住一次消费和代际守卫。
- **备注**：已做源码链路验真和自动化回归；按用户要求不等待完整编译验收。本条属于
  reader/WebView 交互，原始跨章节点击路径仍应由 PR CI 后补真实设备肉眼复测。
