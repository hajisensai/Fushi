## BUG-1515 · 父作品短篇被错误拆成独立系列卡
- **报告**：2026-08-10（用户：修复“其他花絮不见”后，Re:Zero 又被拆成四张系列卡）
- **真实性**：✅ 真 bug。错误修复 `80d5ab4a8b` 把“成员全是 short/extra 的合集”恢复成独立系列卡；真实库里这 12 集虽位于三个扫描合集，但 `video_metadata_extras.work_id` 全部指向 Re:Zero 主作品 `work_id=19`，应在主系列详情的花絮区统一展示，不能在系列墙拆卡。
- **[x] ① 已修复** — 撤回 `video_series_visibility.dart` 的独立卡规则，系列墙继续排除全部父作品附件；`media_collection_detail_page.dart` 已按 canonical work 加载所有 52 条 Re:Zero 花絮/短篇并在主系列详情中展示。
- **[x] ② 已加自动化测试** — 扩充 `fushi/test/pages/video_library_series_structure_guard_test.dart`，同时守卫“系列墙排除父作品附件”和“主系列详情加载、渲染 canonical work 花絮”两端接线。
- **备注**：没有删除或移动任何合集成员；修复的是系列墙与主作品详情之间的展示归属。
