## BUG-3048 · 移动端划词后翻页，选择高亮与两端手柄留在新页面上

- **报告**：2026-10-05；首轮修复后用户继续反馈切页仍有手柄。
- **真实性**：✅ 真 bug。原分页从未清选择；首轮把清理接在 `noteUserScroll`，但它是 capture 阶段输入意图而不是已发生位移。连续模式手柄 touchmove 在 target handler 前就被清掉；只保护 dragAnchor 漏掉 activeHandle。另有 VN 独立 renderScreen 路径和分页程序化定位没有经过原 paginate 清理点，旧手柄直接挂 html，正文替换不销毁它。
- **[x] ① 已修复** — 本轮修复提交（见分支日志）：
  - `reader_pagination_scripts.dart:1281` 分离强制失效与活动拖选保护；`noteUserScroll` 仅清恢复/图片锚。
  - `:3560` 连续 scroll 比较真实内容轴坐标；重复/无位移输入不清，活动长按/手柄拖动不打断。显式连续翻页真的移动后强制清。
  - `:2565` 分页 `setPagePosition` 只在实际位移后强制清，覆盖普通翻页、字符/fragment/进度/音频定位；`limit` 与同位置重写保留选择。
  - `reader_visual_novel_scripts.dart:2602` 在替换 DOM **之前**完整 `clearSelection`，即使活动拖选或同屏重建也结束旧会话；仅 reveal/limit 不清。
  - selection 模块拒绝 detach 的 ranges/anchors，清理后迟到 touchend 不复活菜单，完整 clear 通知 Flutter 收起操作条。
- **[x] ② 已加自动化测试** — `reader_selection_viewport_behavior_test.{js,dart}` 执行工作树生产代码：274 场景，10 个内存 mutation 全部检出；覆盖 capture→target 传播、横/竖排实际位移、两种活动拖选、显式/程序化分页、VN 同屏/跨屏 detach 前清理、CSS highlight/wrapper、原生 range 和宿主通知。`reader_pagination_viewport_selection_guard_test.dart` 守装配入口。
- **备注**：`implemented_unverified`，最终补修未再 adb。不要称桌面“完全不受影响”：完整 clear 也删除浏览器原生 range，行为测试明确涵盖 native-only selection。