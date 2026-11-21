## BUG-5106 · 大 SRT / VTT 字幕轨异步解析后，复制 + 排序 + 重叠收口回到 UI isolate
- **报告**：2026-11-22（外部审计 HBK-AUDIT-012，Codex 2026-11-21 PR 审查，来源 PR #3957）
- **真实性**：✅ 真 bug（根因 `packages/fushi_engine/lib/media/video/video_subtitle_source.dart:372-396`@cbdc2a45ed：`parseSubtitleContentAsync` 只把 `SrtParser` / `VttParser.parseStringAsync` 派到后台 isolate，回来后在调用方 isolate 上跑 `clampPlainTextCueOverlaps`（`subtitle/plain_subtitle_overlap.dart:21-23` 复制整表 + 排序 + 两趟全表扫描）；播放器页面 `video_fushi_page.dart:6620`、`_readAndParse` 都经这一入口）
- **[x] ① 已修复** — `parseSubtitleContentAsync` 改为把整条 `parseSubtitleContent`（解析 + 重叠收口）作为同一个任务：超阈值整段 `Isolate.run`，调用方只收结果；阈值沿用 `CueParseDispatch`（分支 claude/audit-fix-video-player-async）
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_source_test.dart`「large srt/vtt: overlap clamp runs inside the background parse task」（isolate 局部计数 `debugPlainTextOverlapClampRuns` 断言调用方 isolate 收口 0 次，并核收口语义）+ 小内容仍同步收口
- **备注**：没把收口搬进 Rust：它是存量 Dart、只在解析时跑一次，搬进 `ffc_parse_subtitle_*` 要改 C ABI 并给有声书 SRT 加开关；放进同一后台任务已消除 UI isolate 上的整轨处理。首帧 / 切轨的真机抖动对比未做。

### 根因

PR #3957 给 SRT / VTT 加了解析期的重叠收口，同步入口在解析函数里做，异步入口却写成
`clampPlainTextCueOverlaps(await XxxParser.parseStringAsync(...))`——await 回来已经在调用方
isolate 上，整轨 O(n log n) 的复制排序就落在 UI isolate。

### 修复

`parseSubtitleContentAsync` = 「同步入口 `parseSubtitleContent` 整体」按内容大小选同步 / `Isolate.run`，
闭包在非 async 帮手里建，只捕获不可变入参。

### 变异实测

把 `parseSubtitleContentAsync` 恢复成 cbdc2a45ed 的写法，新增的 large srt / large vtt 两条用例变红
（调用方 isolate 收口计数为 1）；恢复修复后全绿。

### 实测（40000 条倒序部分重叠 SRT，2.1 MB，Windows 本机 flutter test）

- 调用方 isolate 上的整轨收口次数：修前 1 次 / 轮，修后 0 次。
- 单次收口本身（同一份 40000 条）：6～11 ms，修前全部落在 UI isolate，修后在后台 isolate。
- 计时器测得的事件循环最大间隔修前 11.8～29.3 ms、修后 11.1～42.9 ms：两边都被结果跨 isolate
  回传（40000 个对象反序列化）主导、噪声大于收口本身，不能当作改进证据，只说明没变差的量级。
