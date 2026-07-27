## BUG-1178 · update-manifest 竞态测试超时会级联带红兄弟用例
- **报告**：2026-07-28（用户：）
- **真实性**：✅ 真 bug（测试夹具缺陷）。两处根因：
  1. **级联** `hibiki/test/tools/update_manifest_publish_race_test.dart`（原 `_Fixture.publish` 用 `Process.run` / 原 `_Fixture.dispose` 无保护地 `root.delete(recursive: true)`）：`publish` 以 `workingDirectory: root.path` 起 bash。用例一旦超时，`test` 包只是放弃 `await`，**OS 进程还活着**；Windows 上任何进程的 CWD 目录不可删，于是 `addTearDown(fx.dispose)` 直接抛 `PathAccessException: Deletion failed ... 另一个程序正在使用此文件`，把一次超时变成额外的 tearDown 报错，同时遗留的 bash/git 子进程继续抢 CPU 拖慢后续用例。
  2. **逼近超时线** `tool/publish_update_manifest.sh:196`（原）`sleep $((attempt * 3))`：竞态用例里输的一方固定真睡 3 秒。对真 GitHub remote 这是正确的礼貌退避，但本测试推的是本地裸库，没有任何需要退避的对象。
- **纠正用户前提**：「单独跑要 42 秒」不成立。实测整个文件**测试执行只 14 秒**（`concurrent` 用例 5 秒最慢），42~48 秒里的大头是 `flutter test` 的编译，每个测试文件都一样，与本文件无关。真正贴近 30 秒线的场景是全量并发跑时本文件抢不到 CPU（实测争用下整文件涨到 34 秒）。
- **[x] ① 已修复** — 两处都改：
  - 夹具改用 `Process.start` 并把 `Process` 句柄存进 `_Fixture._running`，只有真正 `await exitCode` 拿到退出码后才摘句柄；`dispose()` 先 `kill(SIGKILL)` 所有幸存进程再删目录，且删除失败只吞 `FileSystemException`（systemTemp 由 OS 回收），保证一个用例的失败绝不外溢成兄弟用例/组级失败。
  - 脚本退避抽成 `MANIFEST_RETRY_BACKOFF_MS`（**生产默认仍是 3000**）+ `backoff_sleep()` 纯 bash 整数运算；测试传 `50`。竞态**语义**（重新 fetch live tip、重新 merge、绝不 clobber）分毫未动，只去掉与语义无关的等待时长。
- **[x] ② 已加自动化测试** — `hibiki/test/tools/update_manifest_publish_race_test.dart::production retry backoff stays polite to the real GitHub remote`：扫脚本源码断言默认退避仍为 `3000`，防止有人拿这个 seam 去「加速 CI」变成对 github.com 的高频重试。级联本身由夹具结构消除（`_running` + 容错 dispose），并已用临时 probe 用例做过正负对照验证。
- **验证**：修复后整文件跑 22 次全绿，`concurrent` 用例 5s → 2s，整文件 14s → 10s。负向验证：把 `publish`/`dispose` 还原成 `Process.run` + 硬删，插入「起了 publish 不 await 就走」的 probe 用例，立刻复现 `PathAccessException: Deletion failed ... 另一个程序正在使用此文件` 且指向 `_Fixture.dispose`；换回修复版同一 probe 通过。
- **备注**：与 BUG-1177 / BUG-1179 同批。
</content>
