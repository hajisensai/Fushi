## BUG-3007 · Jimaku 混合语言字幕包忽略请求语言与批量语言偏好
- **报告**：2026-10-06（第 1 批 PR 代码审查）
- **真实性**：✅ 真 bug（真实代码路径静态定位）。`fushi/lib/src/media/video/jimaku_subtitle_provider.dart:157` 的压缩包选取只传请求集号，没有保存或消费 `VideoSubtitleSearchRequest.languages`。搜索明确允许语言未知的包，但解包后未补硬过滤，含英文与日文同集字幕的包会按 ZIP 内顺序选择英文，`subtitle_search_panel.dart:1080` 随后直接落盘。`fushi/lib/src/media/video/subtitle/subtitle_batch.dart:165` 也仅按集号挑第一个条目，忽略批量 `preferredLanguage`，并把首个下载文件的语言复制给其它条目。
- **[x] ① 已修复** — Jimaku 候选保存请求语言，解包后按文件标签（缺失时用包标签）执行显式硬过滤，只把符合请求的条目交给批量下载。批量对包内候选使用与普通候选相同的语言排序和文件名 tie-break；偏好只排序，缺首选仍可使用其他语言，每个结果按自身文件标记语言。其它 provider 的单文件下载标签优先级不变，SubDL 既有选集回退未改。提交由本轮主代理统一完成。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/jimaku_archive_pack_test.dart` 增加 provider + ZIP 测试：日语硬过滤选中后置日文、只有英文则明确失败；批量日语/英语偏好均挑对同集文件，缺偏好语言保留其它语言，逐文件结果标签正确且整包只下载一次。待主代理统一执行。
- **备注**：尚未真实站点下载或设备播放 E2E 复测，不宣称验证通过；需回补后续批次采用的集成分支。
