## BUG-4926 · 条目右键菜单「设置」子菜单：鼠标往右划向子菜单时收起，永远点不到
- **报告**：2026-11-18（应用内反馈 iEhadpzweB，Windows）
- **真实性**：✅ 真 bug（widget 测试用真实鼠标悬停复现：指针停在行与子菜单之间的缝里，子菜单被收起）。根因 `fushi/lib/src/pages/implementations/media_item_dialog_page.dart:2140`（修复前）：子菜单用 `CompositedTransformFollower.offset` 在「设置」行外侧留 4px `_gap`，这条缝既不在行的 `InkWell` 悬停区里，也不在子菜单的 `MouseRegion` 里。`_syncHover`（:2091）只延一帧就判 `_hoverRow || _hoverMenu`，指针横移时只要有一次事件落进缝、且该帧内没有下一次事件，两边都判为未悬停 → `_close()` 收起 `OverlayPortal`，之后子菜单不存在，指针再也移不进去。
- **[x] ① 已修复** — 行与子菜单的悬停区改为首尾相接：跟随偏移不再带横向 `_gap`，缝改成子菜单 `MouseRegion`（`hitTestBehavior: opaque`）里朝向本行的透明内边距（右侧时左内边距、翻到左侧时右内边距），子菜单视觉位置不变；`_placement` 的翻转判据（`_gap + _width`）不变。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_item_actions_presentation_test.dart`「hovering across the gap into the settings submenu keeps it open」与翻到左侧的同名用例：真实鼠标悬停打开子菜单 → 停在缝正中若干帧 → 子菜单仍在 → 移入并点中一项。修复前两条均红（`Found 0 widgets with text "Edit CSS"`），修复后绿。
- **备注**：开放中的 PR #3803 把这段代码搬进 `media_item_context_menu.part.dart`，两者合并时需把本修复带过去。真机鼠标复测未做（真机验证按规则取消）。
