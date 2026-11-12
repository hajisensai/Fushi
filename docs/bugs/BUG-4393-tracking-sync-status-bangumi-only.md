## BUG-4393 · Settings Sync section and control status report Bangumi only
- **报告**：2026-11-11（T1 hands-on test, finding F5）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/tracking/media_tracking_settings_body.dart` read `MediaTrackingService.loadStatus()` (`packages/fushi_engine/lib/media/tracking/media_tracking_service.dart`), whose sync fields are hard-wired to Bangumi; `fushi/lib/src/ops/ctl_settings_body_tracking.dart` `mediaTrackingStatusRecord` too. With AniList / MangaBaka signed in and Bangumi not, both said "Never synced", pending 0.
- **[x] ① 已修复** — both read `loadProviderStatuses()` (built-in and plugin sites alike): Settings shows one row per signed-in site (last sync, pending, failed, sign-in rejected); the status op lists `sites` and sums the signed-in ones; the item is titled "Tracking status" (finding F5 commit).
- **[x] ② 已加自动化测试** — `fushi/test/media/tracking/media_tracking_settings_sync_sites_test.dart`.
- **备注**：the control channel's `connect` / `search` items stay Bangumi-token-only (not changed here).
