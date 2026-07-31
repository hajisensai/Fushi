## BUG-1231 · 跨章节书内搜索只跳到章首且不高亮

- **报告**：2026-07-29（用户：书内搜索命中其他章节时只跳到目标章开头，命中词既不定位也不高亮；同章命中正常）
- **真实性**：✅ 真 bug。根因位于
  `hibiki/lib/src/pages/implementations/reader_hibiki/navigation.part.dart:546-551` 的异步边界
  （修复后的绑定点见同文件 `390-402`）：
  第一层根因是 `_navigateToChapterAndWait` 先 `await _navigateToChapter()`，后者内部又
  `await InAppWebViewController.loadUrl()`，返回后才写入 `_pendingPreciseLocate`。
  部分平台上 `loadUrl` 的 Future 返回前，新页面已经完成恢复并触发
  `_onRestoreComplete`；恢复链此时消费到空 pending，随后补写的
  `scrollToSearchMatch` 再无执行入口。因此章节导航本身成功，但章内定位与
  `hoshi-search` CSS Highlight 都没有发生。审查又发现第二层竞态：
  `_beginNavigation` 在目标 DOM ready 前已提前更新 `_currentChapter`；若 restore 中
  再点同一目标章的另一个命中，旧分流只比较章号，便会对旧 DOM 直接执行第二次 JS，
  而第一条 pending 随后在新 DOM settle 后反向覆盖它。独立复核再发现第三层竞态：
  `onRestoreComplete` 没有携带创建该文档时的导航代次；旧文档的迟到回调可能完成新代
  restore，并在 generation mismatch 时先清掉新代 pending。
- **[x] ① 已修复** — 把 `preciseLocateJs` 沿
  `_navigateToChapterAndWait → _navigateToChapter → _beginNavigation` 传入，在导航代际
  递增后立即绑定 pending，严格早于 `loadUrl`。新导航仍先清理上一代 pending，
  失败/超时也会清理本代 pending，保留原有代际隔离语义；并将章号与
  `_restoreInFlight` / `_readerContentReady` 一起判定 DOM 所有权。同一逻辑目标章尚未
  ready 时，新命中替换当前代际 pending，确保最后一次选择胜出；dispose 复用
  `_failNavigation()` 立即清 pending 并完成 wait=false，不执行晚到的旧 DOM 定位。
  每导航 config 另携带 immutable `navigationGeneration`，三种 reader shell 均随
  restore 回调原样回传；Dart 在任何计时、ready、pending 副作用前校验回调代次。
  stale generation 的 queue consume 只返回空、不清当前代 pending。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/chapter_jump_double_jump_atomic_chain_test.dart` 保留时序守卫：
  定位意图必须完整转发到 `_beginNavigation`，绑定点必须位于
  `await _loadChapterDirectly(index)` 之前；同时
  `hibiki/test/reader/reader_search_navigation_test.dart` 真执行共享状态机，覆盖跨章、
  ready 同章、restore 中同章二次选择、重复文本不同 offset、迟到旧回调不得消费或
  清除新代最终选择、代际顶替和 dispose；引擎静态守卫另锁定三种 shell 的代次运输链。
- **备注**：已做源码链路验真和自动化回归；按用户要求不等待完整编译验收。本条属于
  reader/WebView 交互，原始跨章节点击路径仍应由 PR CI 后补真实设备肉眼复测。
