## BUG-4783 · host 端视频指纹没有在途去重：同一文件并发请求各自整文件算一遍 SHA-256
- **报告**：2026-11-17（PR #3538 合入后只读核实遗留项）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/video/video_source_fingerprint.dart:22-55`（修前）`fingerprint()` 只有「算完才写入」的 `_cache`：查缓存未命中就直接 `Isolate.run` 整文件 `ffcSha256FileSync`，算完才写缓存，没有在途表。host 端点 `packages/fushi_engine/lib/sync/fushi_sync_server/video.part.dart` 的 `/fingerprint` 每个请求都直接调 `VideoSourceFingerprint.instance.fingerprint`，两个 client（或同一 client 制卡 + 回跳）同时请求同一个几 GB 的文件 → 两个 isolate 并行全量读盘，首次等待翻倍、播放端同盘读也被拖慢。
- **[x] ① 已修复** — `VideoSourceFingerprint` 加 `_inFlight`（按绝对路径，`FileStat` 相同才复用）：同文件同状态的并发调用共用一个 Future，完成写缓存、成功 / 失败都摘掉在途条目；文件在算的期间变了，新状态另起一次、旧那次的收尾不会摘掉新条目。计算本体抽成可注入的 `VideoFingerprintCompute`（默认仍是 isolate 里的原生 SHA-256）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_source_fingerprint_test.dart` 「BUG-4783」组：三路并发只算一次、算完命中缓存；在途那次失败时等待者都收到错误且之后重算。
- **备注**：host 扫库后预热指纹属取舍（会增加扫库 IO），未做。
