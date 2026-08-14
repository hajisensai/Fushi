## BUG-1637 · 纯SRT有声书听书进度跨设备完全不同步
- **报告**：2026-08-14（互联全域盘点发现）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/sync/sync_orchestrator.dart` `_syncAudiobookProgressLive`：hostKeys 用 `info.bookKey` 建交集，而纯 SRT standalone 有声书的 `bookKey` 恒为空串、身份是 `uid`（`RemoteAudiobookInfo.identity`）——本地 `audiobook_pos_<uid>` prefs 永远落不进交集，听书进度跨设备完全不同步。host 端 `get/putAudiobookPosition` 与 `audiobookExists` 早就按 identity（bookKey ∪ SrtBooks.uid）命中，缺的只是 client sweep 这一环。次生问题：`_downloadRemoteSrtAudiobook` 下载纯 SRT 包后也没有进度回填（srt-backed 路径的 `_downloadRemoteBookProgress` 有对应段），叠加交集 bug = 下载不带进度、之后也永不同步。
- **[x] ① 已修复** —（本分支提交）`_syncAudiobookProgressLive` hostKeys 改用 `info.identity`（空 identity 跳过）；`_downloadRemoteSrtAudiobook` 下载成功后 best-effort 回填 `remoteAudiobookPosition(identity)` 到 `audiobook_pos_<uid>` prefs 对。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_orchestrator_live_progress_test.dart`（standalone SRT audiobook sweep 组：host 只有 SrtBooks 行、本地按 uid 键有带戳进度 → sweep 后 host prefs 落定；真 server+backend 端到端）。下载回填是页面胶水（复用同一 identity 语义），由该测试覆盖根因链路。
- **备注**：与 [BUG-1620]/[BUG-1636] 同属「互联完整支持批次」。
