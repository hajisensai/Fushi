## BUG-4785 · 待传样本文件缺原文件名旁注时用假名上传、被服务端拒收后丢掉
- **报告**：2026-11-17（PR #3565 遗留项核实：待传样本文件缺 `.name` 旁注时文件名回退成 `file.f0`，被服务端按扩展名拒收、然后被悄悄丢掉）
- **真实性**：✅ 真 bug（窗口窄：需在复制样本文件进待传区的中途崩溃 / 断电）。根因：
  - `fushi/lib/src/feedback/feedback_store.dart:308`（修前 `:302-318`）`copyFile` 先把本体复制成正式槽位名，再写 `.type`，最后写 `.name`；两步之间中断就留下一个没有原文件名的槽位，而 `scan()`（`:377` 起）只看本体，照样当待传。
  - `fushi/lib/src/feedback/feedback_service.dart`（修前 `:889`）上传时 `nameOf(...) ?? 'file.$slot'` 编一个扩展名为 `f0` 的假名，服务端扩展名白名单必拒（4xx），按 `isPermanentAttachmentRejection` 算永久拒收，文件被删——白白上传最多 100 MB 后丢失。
- **[x] ① 已修复** — `copyFile` 改成本体先复制到 `<槽位>.part`，`.type` / `.name` 旁注写完后再 rename 成正式名（`feedback_store.dart:308-332`），中途失败删掉 `.part` 并原样抛出；`.part` 列入不算槽位的后缀（`:255`），`remove` 一并清理（`:370`）。不变量：本体在 = 原文件名旁注在。上传端去掉假名回退：缺旁注的样本文件槽位（只可能是待传区被外部动过）记日志、当损坏丢掉，不再上传（`feedback_service.dart:861-873`，名字取自 `:906`）；了结槽位的清理抽成 `_forgetPendingSlot`（`:934`）。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_files_service_test.dart`：①「copyFile 中途失败（写原文件名旁注出错）不留下没有原文件名的待传槽位」——在 `f0.name` 处放目录让写旁注必然失败，断言 `scan()` 为空、无 `.part` 残留；正常走完后 `.part` 不算槽位（修前顺序下 `f0` 本体留在待传区，断言红）。②「待传样本文件缺原文件名旁注：当损坏丢掉，不编假名上传」——删掉 `f0.name` 后重试只发 `f1`、`dropped == 1`（修前会以 `file.f0` 发出 f0 请求，断言红）。
- **补全（合并审查）**：`.part` 不算槽位后，崩溃留下的 `.part`（最多 100 MB）与孤立旁注只有「从本机移除」才会删。现由 `FeedbackPendingStore.discardInterrupted()` 在 `FeedbackService._load` 里、任何提交之前清掉；`copyFile` 失败路径连已写的旁注一起删（`_deleteInterrupted`）。同一测试加断言，撤掉 load 里那次调用即红。
- **补全（合并后复审）**：上一条把 `discardInterrupted()` 放进了 `_load` 里 `scan()` 的同一个 try，清理一失败（`.part` 被占用 / 没权限）`scan()` 就不跑，这一整次运行里所有待传附件都看不到、没法重试。清半成品只是收拾磁盘，现单独 try、记 `feedback.pending_discard` 日志后照常 `scan()`（`feedback_service.dart` `_load`）。测试 `fushi/test/feedback/feedback_pending_discard_test.dart`「清半成品失败（.part 删不掉）不连累 load 扫出待传附件」（单独成文件，dist 在 Windows 与 macOS 各跑一遍）：Windows 开着句柄、POSIX 把目录 chmod 555 让删除必然失败，断言 `.part` 仍在（前提成立）且 `pendingSlots` 仍有 `f0`；撤掉单独的 try 即红（实测 `Expected: Set:['f0'] Actual: Set:[]`）。
- **备注**：崩溃窗口用「写旁注失败」等价模拟，未做真机断电复测。
