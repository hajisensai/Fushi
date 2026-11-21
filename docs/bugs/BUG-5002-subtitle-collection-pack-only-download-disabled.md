## BUG-5002 · 只有整季包的字幕来源「下载全部」是灰的
- **报告**：2026-11-20（路线图 #3722 遗留（docs/plans/2026-11-17-novel-manga-video-remaining-roadmap.md 第 3 节），c23 写测试时发现、要求先验真伪）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/subtitle_collection_panel.dart:275` 的 `canRunSubtitleCollectionBatch` 只看 `selected.index.isEmpty`，而整季包按设计不进 `SubtitleEpisodeIndex`（`subtitle_episode_matching.dart:60`）；`runSubtitleBatch` 却会经 `_ArchivePackSplitter` 按集号从可解开的 zip 包里拆（`subtitle_batch.dart` 的 `packs.subtitleFor`），成员行也据 `unpackablePackFormat` 预览「将从整季包中拆出」。不是有意：按钮与成员行、与批量能力三者自相矛盾。
- **[x] ① 已修复** — 60d70a4d05：门槛改为「有单集文件 **或** 有可解开的整季包」；只有 RAR / 7z 的来源仍禁用。
- **[x] ② 已加自动化测试** — `fushi/test/pages/subtitle_collection_panel_test.dart`（只有 zip 整季包的来源可批量、下载中仍禁用；只有 RAR 包仍禁用；e481e29a2b 修测试子类）。
- **备注**：真 Jimaku 整季包来源的端到端批量未在设备上验。
