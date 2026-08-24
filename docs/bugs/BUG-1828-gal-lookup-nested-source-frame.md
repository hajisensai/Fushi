## BUG-1828 · 游戏内嵌套查词丢失来源层导致子卡挂错谱系
- **报告**：2026-08-24（用户运行时报告，已脱敏）
- **真实性**：✅ 真 bug。`global_lookup_host.js:982-1022` 已把触发点击的
  `__frameId` 附到 `onLinkClick` / `textSelected`，但旧
  `global_lookup_controller.dart:1396-1429` 只消费 query/anchor，随后总以当前最深层
  为 parent。已有 child 时从 root / 中间层点词，新结果因此错误接成旧 top 的后代；
  `base_source_page.dart:765,782` 的 app 内参考路径则先按被点层截断后代。
- **[x] ① 已修复** — `global_lookup_stack.dart:219` 新增来源层解析：带未知 id 的迟到
  消息 fail-closed，只有无 stamp 的 legacy 消息回退 top；controller 在搜索前截断来源层
  后代，异步返回后按稳定 frame id、index、route 和 latest-generation 复核，再以该层
  push/highlight（本提交）。
- **[x] ② 已加自动化测试** —
  `test/lookup/global_lookup_controller_stack_test.dart` 覆盖 root / 中间层替换旧谱系、未知
  frame 丢弃与 legacy fallback；`lookup_word_highlight_surfaces_guard_test.dart` 禁止重新
  硬编码 `_stack.length - 1`。相邻查词回归 154 tests 与热路径/设置缓存 28 tests
  全部通过。
- **备注**：Windows Debug 构建已成功并启动，用户随后要求提交上游 PR；SGRE 原始路径
  “root 换 child / child 再下钻”两种谱系尚无单独的显式通过回报，未据此宣称 runtime
  已通过。完整游戏
  视口与单卡 cap 的几何拆分是另一边界，不混入本 bug。
