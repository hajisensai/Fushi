## BUG-3024 · 设置恢复默认按钮挤压窄面板标题导致溢出
- **报告**：2026-10-06（PR #1984 审查 W1-006；视频快捷设置 320/360px、UI 2 倍）
- **真实性**：✅ 真 bug，沿真实调用链定位。`settings_schema_widgets.dart:151` 将已修改项包装为 `SettingsModifiedRow`；`settings_kit.dart:1384` 用横向 Row 永久为恢复按钮占 48+4dp。视频测试初值 `lookupOnly` 不等于 `VideoImmersiveMode.fallback`，故沉浸模式行显示该按钮。320/2−2×28（sheet）−52（reset）−2×16（行内距）=20dp；`settings_shared.dart:1136` 的标题 Row 固定图标30+间距12=42dp，正好溢出22dp。360宽同算40dp，溢出2dp，与CI两档证据一致。尚未取得原始 RenderFlex 创建位置，需新CI交叉核实。
- **[x] ① 已修复** — 恢复按钮装饰按共享设置行的标题最小宽、图标槽、内边距和完整触控宽决定横排/换行。窄时恢复按钮移到内容下方右侧，内容获得全宽；宽时维持原横排。Flex 与 Flexible 保持子树身份，修改状态切换不重建被装饰控件。
- **[x] ② 已增加自动化测试** — `fushi/test/settings/settings_modified_row_narrow_test.dart`：真实 modified picker、320/360px、UI 2倍、文本1/2倍，检查无异常、按钮位于内容下方、完整触控宽、真实重置回调、子元素身份稳定；另验宽行按钮保持并列。原 `video_quick_settings_sheet_test.dart` 失败用例完整保留。
- **备注**：按 integration owner 指令不排本地Flutter重活，新增5项尚未执行，交PR CI；未做设备端布局复测，不宣称W1-006已运行验证通过。
