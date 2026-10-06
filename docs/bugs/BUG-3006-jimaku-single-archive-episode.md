## BUG-3006 · Jimaku 单文件字幕包忽略明确集号冲突，给其他集安装错误字幕
- **报告**：2026-10-06（第 1 批 PR 代码审查）
- **真实性**：✅ 真 bug（真实路径静态定位）。`packages/fushi_engine/lib/media/video/subtitle/subtitle_archive.dart` 的 `pickArchivedSubtitle` 在唯一文件时直接返回，不检查 `fallbackToFirst: false` 和请求集号。Jimaku 带集号搜索仍从未过滤列表补入压缩包，`fushi/lib/src/media/video/jimaku_subtitle_provider.dart:157` 下载时要求严格选集；请求第 9 集、包内有效字幕只有 `Show - 01.ja.srt` 时却返回第 1 集，`subtitle_search_panel.dart:1080` 随后直接落盘并交给播放器。
- **[x] ① 已修复** — 唯一文件带明确集号时，严格模式继续逐集匹配，不匹配返回 null 并由 provider 报 `archive/notFound`。无集号单文件、未指定请求集号与 SubDL 的宽松回退保留既有行为。提交由本轮主代理统一完成。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/jimaku_archive_pack_test.dart` 增加真实 provider + 内存 zip 路径：唯一文件集号匹配、generic 文件无集号、明确集号不匹配（含非字幕条目过滤），以及非严格和无请求集号兼容。测试待主代理统一执行。
- **备注**：本记录的真实性来自代码路径定位，尚未设备复测，不宣称播放 E2E 验证通过。需将修复回补仍会用于后续批次的集成分支。
