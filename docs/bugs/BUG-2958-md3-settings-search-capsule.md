## BUG-2958 · MD3 设置页搜索栏被压成 12 圆角方框（胶囊判据认不出包了 Padding 的放大镜）
- **报告**：2026-10-05（协作者 shishamo：Android MD3 设置页圆角不对，截图里搜索栏是圆角矩形）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/glass/fushi_glass_inputs.dart` `_isSearchDecoration` 只认 `prefixIcon` 直接是放大镜 `Icon` / `FushiIcon`；设置页 MD3 搜索栏给放大镜包了一层 `Padding` 自配留白，判据认不出 → 走普通输入框分支，把调用方写好的胶囊边框覆写成 12 圆角。
- **[x] ① 已修复** — 判据先剥掉 `Padding` 包装再认图标（`fushi_glass_inputs.dart:61`）。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/fushi_glass_inputs_test.dart`「MD3 search field stays a capsule (prefix wrapped in Padding: true/false)」：三种边框都必须是 999 圆角胶囊。
- **备注**：同截图里的「分组列表项断开」是 MD3 分段分组列表（Android 16 设置，`settings_shared.dart` `kSettingsSegmentGap = 2` / 外角 24 / 内角 4）的既定设计，由多条测试钉住；真机放大核对渲染与设计一致（`android-shots/22-md3-settings-after.png`），未改。是否改回连续卡片需所有者拍板。
