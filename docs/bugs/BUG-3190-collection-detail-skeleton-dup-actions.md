## BUG-3190 · 作品资料页骨架旧样式、背景海报看不见、右上角与左侧按钮重复
- **报告**：2026-10-09（用户：哈吉千歳，应用内反馈 Hqbie63YQc，Windows 2560×1440@1.5）
- **真实性**：✅ 三条都是真 bug。
  - 骨架：`fushi/lib/src/media/detail/media_detail_kit.dart` 的 `MediaDetailSkeleton` 恒画单列「封面在左 + 整宽条目」，而加载完成的 `MediaDetailLayout` 在 ≥1080 宽时是两栏（左栏居中 hero、右栏集卡）——加载期间先闪旧版式。
  - 海报：`fushi/lib/src/media/collections/collection_detail_layout.dart` 的 `kCollectionHeroBackdropBlur = 16` + `MediaDetailBackdrop` 的 30%→72% 底色 scrim + 55% primaryContainer 色晕，横版 fanart 被压成一片色雾。
  - 重复：`fushi/lib/src/pages/implementations/media_collection_detail_page.dart` 的 hero「⋯」（`_heroMoreItems`）是右上角管理菜单的子集，「标签」「补齐缺集」在 hero 次按钮与右上角菜单各有一份。
- **[x] ① 已修复** — 本 PR：骨架按与 `MediaDetailLayout` 相同的判据分两栏 / 宽 hero / 窄 hero；fanart 不再模糊、改用「露画面」scrim（起始侧托住信息栏、自上而下落到底色），封面垫底仍重模糊；hero 去掉「⋯」，右上角菜单去掉与 hero 次按钮重复的「标签」「补齐缺集」（枚举与分发一并删）；宽屏右上角加「海报横幅 / 两栏」版式切换（用户确认「要改」，横屏可参考竖屏：海报横幅 = 宽屏也走单列、fanart 横幅在顶，偏好 `video_detail_poster_layout` 跨作品记住）。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/media_detail_collection_layout_test.dart`（两栏 / 手机骨架几何、fanart 不包 `ImageFiltered`、hero 与菜单去重守卫、版式切换接线）；`fushi/test/pages/collection_manage_menu_guard_test.dart` 随之更新。
- **备注**：真实像素对照见 PR（`collection_detail_pixel_preview_test.dart` 与 `video_library_chrome_preview_test.dart` 的 before / after）。
