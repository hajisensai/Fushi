## BUG-5098 · video-fingerprint-store-quadratic-rewrite
- **报告**：2026-11-22（Codex 2026-11-21 PR 审查 HBK-AUDIT-009，PR #3936）
- **真实性**：✅ 真 bug。① `packages/fushi_engine/lib/media/video/video_fingerprint_store.dart` 的 `put`（修前 129 行起）每条都 `jsonEncode` 整张表再写临时文件 + flush + rename：互联 host 首次预热 N 个视频，缓存落盘累计序列化 N(N+1)/2 条。实测（同一台机器、同一组路径，Dart VM）：N=500 修前写盘 26,252,995 字节 / 8.2 s，N=2000 修前 420,497,495 字节 / 27.1 s。② `video_fingerprint_warmer.dart` 的 `_loop`（修前 69 行）在跑的期间来过 `request()`（host 每次 `GET /api/library/videos` 都会请求）时，本轮结束立刻 `do … while (_again)` 再跑一轮全库 stat，绕过 `minInterval`。
- **[x] ① 已修复** — 落盘改成按键追加的 JSON Lines 日志：每次 put 只追加该条一行，同一时刻攒下的多条并成一次追加；失效行超过「在用条目数 + 256」才整份压实（临时文件 + rename），摊下来每条 O(1)；读时逐行回放，写到一半的尾行只丢那一行，旧版整表 JSON 照样读入、下次写入压实成新格式。修后 N=500 写 106,890 字节 / 1.2 s，N=2000 写 428,890 字节 / 4.7 s（flush 次数两边都是 N，每次只是一行）。预热的补跑改为本轮结束后经 `request()` 走同一道间隔：跑的期间来的任意多次请求并成间隔满后的一轮。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_fingerprint_warm_test.dart`：2000 条 put 写盘字节 ≤ 2×N×单行字节、日志 N 行、重开命中；并发 put 并成 ≤2 次追加；同键覆盖触发压实且回放取最新值；maxEntries 淘汰后重开一致；尾行截断只丢一条；旧格式兼容；跑的期间 5 次请求只跑 1 轮、补的一轮在 `minInterval` 满后才跑且只跑一次（fake_async）。
- **备注**：缓存文件名仍是 `video_fingerprints.json`（冻结的磁盘名），内容格式改为 JSON Lines。
