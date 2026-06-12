## BUG-212 · 自定义主题调色盘图标深色主题消失
- **报告**：2026-06-12（用户：）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/utils/components/hibiki_material_components.dart:1288`
- **[x] ① 已修复** — `hibiki/lib/src/utils/components/hibiki_material_components.dart:1288`
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/hibiki_scheme_swatch_test.dart（新增 group「BUG-212 · 徽章图标随徽章背景取对比」）`
- **备注**：

### 现象
外观设置「自定义主题」那一行的色卡（`HibikiSchemeSwatch`，settings_actions.dart:376-402）右下角有个小圆形角标，上面是调色盘图标 `Icons.palette_outlined`。深色（黑色）app 主题下这个调色盘图标看不见；浅色（白色）app 主题下正常显示。

### 根因
`HibikiSchemeSwatch.build`（`hibiki/lib/src/utils/components/hibiki_material_components.dart:1278-1291`）画 badge 小圆角标时：
- 圆圈**背景色** = `menuRole`（第 1283 行）= `colors[3]` = **被预览方案**的 `surfaceContainerHigh`（见 `hibikiSchemeSwatchColors`，components:1217）。custom-theme 色卡的方案由 `appModel.customTheme*` 衍生（settings_actions.dart:380-389），其亮暗由 `customThemeDark` 决定，与当前 app 主题无关。
- 圆圈里图标**前景色** = `cs.onSurface`（第 1288 行）= **当前 app 主题**的 `colorScheme.onSurface`。

两个颜色来自**两个不相干的 colorScheme**：badge 背景跟着被预览方案走，图标色跟着 app 主题走，对比度完全不受控。当 app 是深色主题时 `cs.onSurface` 是浅色（近白）；若用户自定义主题恰是浅色方案（`customThemeDark=false`），它的 `menuRole`（surfaceContainerHigh，surface 家族）也是浅色 → 浅色图标画在浅色 badge 背景上 → 对比度近零 → 图标「消失」。反之白色 app 主题下 `cs.onSurface` 是深色，画在浅色 badge 上仍清晰 → 用户只在深色主题看到消失。

同文件的兄弟组件 `HibikiColorSwatch`（components:1041-1043）画 overlay 图标时用的是 `_swatchForegroundFor(color)`——根据**圆圈自己的背景色**取黑/白对比前景，这是正确范式；`HibikiSchemeSwatch` 的 badge 没用它而是硬借 app 主题的 `cs.onSurface`，这就是 bug。

### 修复
把 badge `IconTheme` 颜色从 `cs.onSurface` 改为 `_swatchForegroundFor(menuRole)`（components:1288）：图标色相对 **badge 自己的背景色**取对比，与 `HibikiColorSwatch` 范式一致。这样图标色与 badge 背景永远来自同一坐标系，深/浅 app 主题、深/浅自定义方案任意组合都可见。不加分支，只修正错误的数据流来源。

### 测试
`hibiki/test/widgets/hibiki_scheme_swatch_test.dart（新增 group「BUG-212 · 徽章图标随徽章背景取对比」）`：在深色 app 主题 + 浅色被预览方案（badge 背景浅色）下渲染带 overlay 的 `HibikiSchemeSwatch`，断言 badge 图标的 `IconTheme.color` 不是 app 主题的浅色 `onSurface`，而是与浅背景对比的 `Colors.black`；并验证 `_swatchForegroundFor` 取自 badge 背景而非 app 主题（撤掉修复该用例转红）。
