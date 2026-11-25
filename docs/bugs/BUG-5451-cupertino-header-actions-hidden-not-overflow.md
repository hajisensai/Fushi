## BUG-5451 · cupertino-header-actions-hidden-not-overflow
- **报告**：2026-11-25（用户：Cupertino 合集页录屏「合集右上角被藏起来了」「放不下应该是 ⋯ 而不是藏起来」）
- **真实性**：✅ 真 bug。页头动作的唯一收纳判据 `fushiResolveHeaderActions`（`fushi/lib/src/utils/components/fushi_material_components.dart`）只把 `FushiIconButton` 当可收纳动作（`fushiIsCollapsibleHeaderAction`）；合集详情页 `_headerActions`（`fushi/lib/src/pages/implementations/media_collection_grid_detail_page.dart:1066`）传的是 `FushiIconButtonControl`，一颗都收不进「⋯」，iOS 档 3 颗上限也不生效，`FushiShellHeaderActions` 只能横滑兜底，右侧删除等按钮被推出屏外。同类二级页顶栏还有 9 处（下载网关验证、放送日历、AI 助手、串流加入、合集版式切换、标签管理、作品网络、音乐服务器页、Lapis 样式编辑）。
- **[x] ① 已修复** — 这些页面顶栏动作统一改用 `FushiIconButton`（切换态走 `selected`）；`fushiResolveHeaderActions` 加 debug 断言，页头动作再出现 `FushiIconButtonControl` 直接报错。
- **[x] ② 已加自动化测试** — `fushi/test/pages/collection_detail_header_overflow_test.dart`（Cupertino iOS 手机宽：页头动作全是 `FushiIconButton`、外露按钮整颗落在屏内）。
- **备注**：底部动作条（`FushiBottomActionBar`）/ 迷你播放条不走页头收纳，不在范围内。
