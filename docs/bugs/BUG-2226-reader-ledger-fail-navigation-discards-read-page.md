## BUG-2226 · 导航失败/兜底超时 discard 丢掉用户真读过的上一页
- **报告**：2026-09-06（用户：「检查一下触发其他翻页是否还有这样的问题」——枚举翻页触发源时发现）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/reader_fushi/navigation.part.dart:467-474`（`_failNavigation` → `_readLedger.discard()`）：装载失败 / `_navigateToChapterAndWait` 10s 超时 / 内容就绪兜底超时（BUG-868）时账本当前单元仍是**导航发起前用户正读的那页**（`_beginNavigation` 不 `leave()`），discard 把它整页丢掉；且失败后不重启 10s 轮询。
- **[x] ① 已修复** — `_beginNavigation` 在 loadUrl 之前 `leave()` 结算跳走前那页（见 BUG-2225），`_failNavigation` 的 `discard()` 此后只兜「导航发起后新页曾短暂 arrive」的空状态。
- **[x] ② 已加自动化测试** — `reader_read_ledger_wiring_guard_static_test.dart`（`_beginNavigation` 的 leave 在 `_preciseLocateQueue.clear()` / `_restoreInFlight = true` 之前）+ `reader_read_ledger_boundaries_test.dart`（跨章导航失败：leave → discard 不丢上一页）。
- **备注**：与 BUG-2225 同一提交。
