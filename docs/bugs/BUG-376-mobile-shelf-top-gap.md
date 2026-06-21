## BUG-376 · 手机首页页头顶距过大(标题离顶部空一行)
- **报告**：2026-06-21（用户：TODO-667）
- **真实性**：✅ 真 bug — 根因 `hibiki/lib/src/utils/components/hibiki_material_components.dart:1584`（修前）：`HibikiPageHeader` 默认顶部 padding 为 `compact ? gap : page + 8`，首页书架/查词/视频三 tab 直接 new `HibikiPageHeader` 从不传 `compact`（恒 false）→ 顶距恒 `page + 8 = 24`。手机竖屏下 `HomePage` 已用 `SafeArea(top:true)` 让出状态栏/刘海（`home_page.dart:563`），再叠 24 的标题顶距，视觉上标题离顶部空出一行（用户：「和摄像头差一行」）。桌面/平板顶部无系统栏遮挡且内容区另有左右留白，24 合适。
- **[x] ① 已修复** — `hibiki_material_components.dart`：顶部 padding 改为三档——`compact`(上方有 AppBar)走 `gap=8`；非 compact 且窗口为手机竖屏/窄窗(`WindowSizeClass.compact`，宽<600)走 `page=16`(收掉多余一行，保留 SafeArea 让出的状态栏+16 呼吸不顶到摄像头)；非 compact 的中/宽窗(桌面/平板，宽≥600)保持 `page+8=24` 不变。提交：见 worktree todo-667-shelf-top-gap。
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/hibiki_material_components_test.dart` 三条 widget 行为守卫：compact(360)顶距=16、桌面/平板(700/1000)=24、compact 模式(360/1000)恒=8。
- **备注**：仅 UI 间距调整；三个首页 tab（书架/查词/视频）+ `HibikiPageScaffold(showAppBar=false)` 的窄窗页面一并受益（统一收顶距），桌面/平板不变。需真机复测手机竖屏书架标题贴顶观感。
