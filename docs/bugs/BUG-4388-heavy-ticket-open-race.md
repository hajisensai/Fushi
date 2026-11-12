## BUG-4388 · heavy 租约的等待者探测排队票据时撞上别的进程删票据，排队中途崩溃退出 255
- **报告**：2026-11-11（agent 会话自查：同一晚一条 SRS 线上的重活被这样崩掉至少五次，其中一次已排了 72 分钟；本机 Windows 11，约 16 条 `heavy.dart` 同时在排）
- **真实性**：✅ 真 bug。现象：`dart tool/heavy.dart -- …` 排队途中抛 `PathAccessException: Cannot open file, path = '…/fushi-heavy/queue/<名>.ticket' (OS Error: …, errno = 32)`，退出码 255，被包的命令一条没跑。
  - 根因：`fushi/tool/test_flow/heavy_lease.dart:412` 的 `_tryLock` 把 `openSync` 写在 `try` 外，只把「加锁失败」当成「别人占着」，没管「打开失败」。Windows 上删除文件要先以 DELETE 权限打开它，而 Dart 的文件句柄不共享删除权限：票据正被删除时（主人放行后 `release`，或别的等待者清扫死票），其余进程对它的 `openSync` 一律报共享冲突（`ERROR_SHARING_VIOLATION`，errno 32）。排队的进程越多、轮询越密，撞上的概率越高。
  - 证据：独立脚本复现——辅助进程以不共享方式占住文件，`File.openSync(mode: FileMode.append)` 抛 `PathAccessException errno=32`，辅助进程退出后同一调用成功。
- **[x] ① 已修复** — `_tryLock` 在 Windows 上把打开时的共享冲突当成「此刻拿不到这把锁」返回 null（与锁被占同义）：那张票据正在消失，调用方下一轮轮询就看不到它了。其余打开失败照旧抛出，不吞。
- **[x] ② 已加自动化测试** — `fushi/test/tools/heavy_lease_test.dart`「a ticket another process has open unshared reads as live, not a crash」（仅 Windows）：辅助进程以不共享方式占住一张票据，`readHeavyQueue` 不抛、把它算作在排；占用解除后按普通死票清掉。
- **备注**：只处理 errno 32。删除挂起状态下的打开会报拒绝访问（errno 5），没有观察到、也没有处理：拒绝访问同时可能是真的权限问题，当成「占用」会让等待者无限期排下去。
