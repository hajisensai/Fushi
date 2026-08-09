## BUG-1465 · 系列页未使用规范作品竖版海报
- **报告**：2026-08-09（用户：）
- **真实性**：✅ 真 bug。`home_video_page.dart` 的系列墙此前只取合集封面或分集截图，并继续用图片朝向探测，刮削到 `video_metadata_images.cover` 的竖版作品海报从未进入选图链。
- **[x] ① 已修复** — `home_video_page.dart:653,3522-3549,3870-3874,4178-4190` 预取规范作品图片，系列合集与独立作品优先显示刮削海报，并固定为 2:3 竖版卡槽；“全部视频”仍保留原始视频截图和自适应朝向。
- **[x] ② 已加自动化测试** — `video_library_series_structure_guard_test.dart` 锁定规范海报入口和系列竖版朝向；`home_video_collection_cover_card_test.dart` 继续覆盖旧合集封面/成员回退契约。
- **备注**：用户设置的合集封面仍优先于在线刮削海报，不改变封面保护规则。
