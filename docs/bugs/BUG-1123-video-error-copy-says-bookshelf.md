## BUG-1123 · video-error-copy-says-bookshelf
- **报告**：2026-07-26（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/i18n/strings_zh-CN.i18n.json`（key `video_load_failed_not_found`，修复前值「在书架中找不到该条目。」）：该 key 唯一引用点是 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:1833`（`_init()` 中 `repo.getByBookUid` 返回 null——**视频**条目不在媒体库时的失败文案），但 zh-CN 译文写成书侧的「书架」，视频报错把用户指向书架，与视频侧统一称呼「媒体库」（`section_video_library` / `home_stat_library` 均译「媒体库」）矛盾。仅 zh-CN 有此病：en 及其余 15 语均为英文原文 "This item was not found in your library."（library 无歧义），zh-HK 亦是英文回退。
- **[x] ① 已修复** — ``c3cd8bd02``。zh-CN 值改为「在媒体库中找不到该条目。」（视频侧库的统一称呼，对齐 `section_video_library`）；`dart run slang` 重生成 `strings.g.dart`。引用点代码零改动。
- **[x] ② 已加自动化测试** — `hibiki/test/i18n/video_error_copy_not_bookshelf_guard_test.dart`（值扫描守卫：zh-CN 该 key 必含「媒体库」不含「书架」；en 必含 library 不含 bookshelf；并扫全部 `video_` 前缀 key，zh-CN/zh-HK 不得出现「书架/書架」措辞）。
- **备注**：文案层 bug，最强可落地层是 i18n 值扫描守卫（widget 层只能复述同一字符串，无额外增益）。
