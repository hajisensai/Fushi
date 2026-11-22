## BUG-5206 · home-edit-exit-button-double-click-restore
- **报告**：2026-11-22（用户：开发者自报，应用内反馈 0i8iO2LwXj）
- **真实性**：✅ 真 bug。页头「编辑首页」是动作组最后一颗；进编辑态后 `_toolbarItems`（`fushi/lib/src/pages/implementations/home_dashboard_page.dart` 编辑态分支）把动作组换成唯一一颗「恢复默认」，正好落在同一位置，连点「编辑首页」的第二下直接把当前网格换回默认模板。
- **[x] ① 已修复** — 编辑态页头只放「退出编辑」（×，与系统返回同一出口 `_finishWidgetEdit`，保存并退出）；「恢复默认」挪进底部编辑工具栏（添加 · 撤销 · 恢复默认 · 完成），仍可撤销。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_page_test.dart`「BUG-5206：连点「编辑首页」…」：进编辑态后同一坐标是退出按钮、页头没有恢复默认、底栏有；在同一坐标再点一下 → 退出编辑态且布局不变。
- **备注**：新 i18n key `home_widget_exit_edit`。
