## BUG-4391 · A hand link of a multi-season video collection is saved and never sends
- **报告**：2026-11-11（T1 hands-on test, finding F1）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/tracking/media_tracking_repository.dart` `loadCompletedVideoTrackingProgress` and `MediaTrackingService.recordVideoProgress` skip collection links of multi-season collections on purpose (a site lists each season as its own entry), but `listUnlinkedHistory` listed such a collection as a plain "Needs manual link" row and `saveManualMappingAndSync` saved the link anyway: "Linked", then nothing ever sent.
- **[x] ① 已修复** — `saveManualMappingAndSync` refuses (`MultiSeasonCollectionLinkError`); the link dialog explains and points to "Split by season" / single episodes; the "Needs attention" row says why; existing dead links (`MediaTrackingRepository.inertMappingIds`) are listed under "Needs attention" with a remove action (finding F1 commit).
- **[x] ② 已加自动化测试** — `fushi/test/media/tracking/multi_season_collection_link_test.dart`.
- **备注**：per-season links of one collection are not built here (series-level links, W6, will own that model).
