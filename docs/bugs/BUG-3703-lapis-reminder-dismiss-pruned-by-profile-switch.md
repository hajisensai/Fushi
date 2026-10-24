## BUG-3703 · lapis-reminder-dismiss-pruned-by-profile-switch
- **报告**：2026-10-24（用户：复习页「把旧 Lapis 笔记迁到 Fushi 卡片」横幅点了「不再提醒」后还老是弹）
- **真实性**：✅ 真 bug。「不再提醒」写偏好 `srs_lapis_migration_reminder=false`（`fushi/lib/src/srs/srs_providers.dart:511`），但该键没进 `ProfileKeys._excludedPrefKeys`，会随 Profile 快照走；`ProfileRepository.applyProfile` 把「目标快照里没有的 live 键」全部删除（`fushi/lib/src/profile/profile_repository.dart:218-222`）。切到一个在点「不再提醒」之前建的 Profile（含媒体绑定的临时切换）就把键删了，回落默认 true；当次会话 `StateProvider` 还缓存 false，下次启动横幅重新出现。
- **[x] ① 已修复** — 键加入 `ProfileKeys._excludedPrefKeys`（设备本地，与 `p2p_download_notice_dismissed` 同族），并登记进 `kKnownPreferenceKeys`。提交 `0f6de841bf`。
- **[x] ② 已加自动化测试** — `fushi/test/profile/profile_repository_test.dart`「切到老 Profile 不会删掉旧 Lapis 迁移横幅的「不再提醒」」；变异实测：去掉排除项后该测试红（Expected 'false' / Actual null）。
- **备注**：修复前已被删掉的「不再提醒」不会自动恢复，用户需再点一次。
