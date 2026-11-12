## BUG-4399 · Reopening a book link showed the planned volume, and Link silently put it back
- **报告**：2026-11-11（T2 hands-on test G4: Ajin 02 saved as volume 1, reopened showing 2）
- **真实性**：✅ 真 bug. `_TrackingLinkDialogState._pick` (`fushi/lib/src/media/tracking/page/tracking_link_dialog.dart`) used `planBookLinkForHit` first and the saved link's unit / number only when there was no plan, so the user's saved number was replaced by the plan on reopen.
- **[x] ① 已修复** — for the current entry the saved unit and number win over the plan (T2 F5 commit).
- **[x] ② 已加自动化测试** — `fushi/test/media/tracking/tracking_page_f5_test.dart` ("G4 + G5 + G12 …").
- **备注**：—
