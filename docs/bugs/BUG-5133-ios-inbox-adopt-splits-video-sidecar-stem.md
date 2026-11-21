## BUG-5133 · ios-inbox-adopt-splits-video-sidecar-stem
- **报告**：2026-11-22（外部审计 Codex 2026-11-21 PR 审查 HBK-AUDIT-019，PR #4027）
- **真实性**：✅ 真 bug。PR #4027 的 `ImportInbox.adoptRootFiles` 把根上散文件逐个用 `_freeFilePath`（按单个文件名避重名，旧 `fushi/lib/src/media/import/import_inbox.dart:276-298`）移进分类子目录；外挂字幕靠与视频同 stem 配对（`packages/fushi_engine/lib/media/video/video_sidecar.dart:43` `pickSidecar`）。`Video/` 已有 `EP01.mkv` 时，根上的 `EP01.mkv` + `EP01.srt` 变成 `EP01 (2).mkv` + `EP01.srt`：新视频找不到字幕，旧视频反而配上新字幕；只有字幕撞名时反过来，新视频去配旧字幕。最小复现测试在修复前红（`PathNotFoundException: ...Video\EP01 (2).srt` / `...Video\EP01 (2).mkv`）。
- **[x] ① 已修复** — `import_inbox.dart:274` `adoptRootFiles` 改为按依赖组分配目标路径：`_groupBySidecarStem`（:304）把每个非字幕文件按 stem 开组，字幕按 `listSidecarSubtitles` 同一配对规则（不分大小写、可带语言标记）归入能配上的最长 stem；`_freeGroupStem`（:354）为整组挑一个所有成员都不重名的 stem（`<stem> (n)`），组内成员共用。
- **[x] ② 已加自动化测试** — `fushi/test/media/import/import_inbox_test.dart`「只有视频撞名时…」「只有字幕撞名时…」「不撞名的组与不相干文件原名搬入…」；变异实测：换回修复前的 `import_inbox.dart`，前两条红。
- **备注**：真机（iOS iTunes 文件共享）未验证。
