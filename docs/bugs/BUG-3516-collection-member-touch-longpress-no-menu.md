## BUG-3516 · 合集详情页触屏长按成员只进多选，拿不到库页同一份卡片菜单
- **报告**：2026-10-18（用户：iPad，「合集里面的漫画长按缺少各种功能，其他合集内的也可能缺少」，截图为长按后进入「已选 1 项」多选态）
- **真实性**：✅ 真 bug。非手动序 / 有筛选 / 列表视图下成员走 `_MemberGridTile` / `_MemberListRow`（`fushi/lib/src/pages/implementations/media_collection_grid_detail_page.dart`），`InkWell.onLongPress` 恒为 `_toggleSelected`；菜单只挂在 `ContextMenuTrigger` 上，而它只认鼠标按钮（`fushi/lib/src/shortcuts/context_menu_trigger.dart:164`）。默认排序是卷号（非手动），所以触屏用户默认就拿不到 BUG-2969 接好的共享菜单。手动序拖排网格（`FushiReorderableGrid` 长按原地松手 → 菜单）不受影响。
- **[x] ① 已修复** — d6e6cf32c9：新增 `_memberLongPressHandler`，非多选态长按弹菜单（锚点取格子中心），多选态长按仍切换勾选；进多选走工具条按钮。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_collection_grid_detail_page_test.dart`「非拖排网格触屏长按弹库页同一份卡片菜单，不进多选」。
- **备注**：书架 / 漫画库 / 游戏库三处共用此详情页，一处修复全部生效。
