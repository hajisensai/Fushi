## BUG-4102 · work-profile-session-partial-scope
- **报告**：2026-11-05（用户：反馈 kEFPY4cuKZ 的后续，PR #2866 合入后按推荐补齐）
- **真实性**：✅ 真 bug。#2866 把作品级配置改成会话覆盖层后，覆盖层只接了阅读样式 / 悬浮字幕样式 / 查词：
  - 键范围只认阅读器命名空间与 `floating_lyric_*`，并把字体目录 / 各用途字体表排除在外——`fushi/lib/src/profile/work_profile_scope.dart:84`（`_readerGlobalKeys`）、`:100`（`isWorkScopedPrefKey`）。主题键、`video_subtitle_style`、`srs_mining_*` 都不在内。
  - 主题读自己的 live 缓存，不经覆盖层——`fushi/lib/src/models/theme_notifier.dart:1695`（`_get` 只读 `_prefs`）。
  - 制卡链的 Anki 设置读裸 live 存储——`fushi/lib/src/anki/anki_view_model.dart:688`（`createAnkiRepository()` 默认存储），进书不换牌组 / 笔记类型；复习制卡固定落激活配置的复习副本（`_readSrsMiner` 只读 `srsStoreProvider`）。
  - Android `:popup` 进程 / 悬浮词典是另外的 isolate，没有任何通道知道主进程正打开哪部作品——`fushi/lib/src/models/app_model.dart:4919`（`refreshForWarmDictionaryPopup` 只对账偏好 / 词典），查词仍按全局配置。
- **[x] ① 已修复** — 覆盖层补齐到 Anki 牌组（配置拥有的 Anki 字段）、复习制卡目标（目标 / 牌组 / 笔记类型 / 字段映射，制卡落进绑定配置的复习副本）、主题、视频字幕样式、字体（含字体目录）：`WorkProfileScope.isWorkScopedPrefKey` 扩键；`ThemeNotifier` 读写经覆盖层并在会话变化时重建；新增 `WorkScopedAnkiSettingsStore` 只接在本机制卡链上（快照 / 应用配置的 `ProfileRepository` 改用裸 live 存储，避免把作品配置的牌组快照进激活配置）；`ReaderSettings` 字体写入经覆盖层；会话变化后 `AppModel` 重解析字体链。主进程把当前会话（配置 id + 会话内写入次数）发布到设备本地偏好 `work_profile_session`（写入递增 `prefs_version`），弹窗进程冷启动 / 热复用时经同一条 `WorkProfileScope.enterProfile` 镜像，不另写一份逻辑；主进程启动时清空。
- **[x] ② 已加自动化测试** — `fushi/test/profile/work_profile_full_scope_test.dart`（键范围、主题 / 视频字幕样式 / 复习制卡目标 / 字体 / Anki 的会话读写与退出恢复、快照没有 Anki 字段时不接管、`writeWorkScopedAnkiSettings`、弹窗镜像、发布不白抬 `prefs_version`、发布键设备本地、接线源码守卫）；`work_profile_session_test.dart` 更新字体键断言。
- **备注**：弹窗进程里在会话期间改设置会写进绑定配置快照，但不会回推给主进程内存里的会话（主进程下次进入作品时读到）。真机 / 模拟器复测未做。
