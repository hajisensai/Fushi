## BUG-4400 · Linking again to the same entry and number sent the progress again
- **报告**：2026-11-11（T2 hands-on test G13: each relink added a "Sent" Activity row）
- **真实性**：✅ 真 bug. `MediaTrackingRepository.saveMapping` (`packages/fushi_engine/lib/media/tracking/media_tracking_repository.dart`) cleared `sentProgress` / `sentCompleted` on every update of an existing link, also when entry, kind, unit and number were unchanged, so the same progress was queued and sent again.
- **[x] ① 已修复** — an update with the same entry, kind, unit and number keeps what the link sent; a real change still starts over (T2 F5 commit).
- **[x] ② 已加自动化测试** — `fushi/test/media/tracking/tracking_hold_and_unlink_test.dart` ("G13 …"), `tracking_catch_up_test.dart` (same link vs changed link).
- **备注**：—
