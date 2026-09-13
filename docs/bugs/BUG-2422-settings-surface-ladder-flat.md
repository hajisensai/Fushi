## BUG-2422 · 设置页页面底/导航窗格/卡片三层对比度仅1.05糊成一片（M3阶梯最挤段+全局关阴影）
- **报告**：2026-09-10（用户：shishamo，「设置页色彩管理还是有点问题，总感觉不对劲」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_design_tokens.dart:190-192`（token 映射落在 M3 阶梯最挤的一段）× `fushi/lib/src/models/theme_notifier.dart:155/1306/1320`（全局 `elevation: 0` + `surfaceTint: Colors.transparent`，把 M3 用来承担层次的阴影与叠层都关掉了）。
- **[x] ① 已修复** — `fushi/lib/src/models/theme_notifier.dart` 新增 `applyFushiSurfaceLadder`，三条主题路径出口统一收口；`deriveSurfaceRolesFrom` 改走 HCT tone 增量。提交见本 PR。
- **[x] ② 已加自动化测试** — `fushi/test/models/theme_surface_ladder_test.dart`（9 条，钉关系不钉色值，覆盖 7 个预设 × 亮暗 + 中性派生 + 系统取色）。
- **备注**：五平台共用同一条 Material 渲染路径，故此修复全平台生效。

### 复现与量化

对用户截图（亮色 / 系统主题 / 界面缩放 96%）逐像素采样：

| 层 | token | 实测 | 对上一层对比度 |
|---|---|---|---|
| 页面底 / 详情窗格 | `surface` | `#F9F9FF` | — |
| 导航窗格 | `surfaceContainerLow` | `#F3F3FA` | **1.053** |
| section 卡片 | `surfaceContainer` | `#EDEDF4` | **1.055** |

三层总跨度 **1.11**，全部低于大面积色块的可辨阈值——「看得出有东西但分不清边界」。

（同时排除一个非 bug：截图里「墨水屏模式」那行更深的横条是 `InkWell` 的 hover 叠层，实测 4% 黑，237→228 完全吻合，鼠标当时停在该行。）

### 根因

M3 baseline 亮色六级容器色是 tone 100/98/96/94/92/90，相邻只差 2 tone（≈1.05）。M3 的设计意图是让 **elevation 阴影 + surfaceTint 叠层**承担层次，色差只作辅助。Hibiki 是「扁平 + 描边」的视觉语言，全局 `elevation: 0`、`surfaceTint` 一律透明——阴影和叠层都不存在，层次就只剩这 1.05。

而 `FushiSurfaceColors.fromScheme` 的映射恰好落在阶梯最挤的一段：`page=surface(98)` / `group=surfaceContainerLow(96)` / `card=surfaceContainer(94)`，这三层是设置页、书架、媒体库最常同屏出现的组合；间距最大的 High / Highest 反倒给了搜索框和菜单这些小面积控件。

同源的另外三处：

1. **深色阶梯不均匀**：实测相邻 1.079 / **1.045** / 1.147 / 1.167，导航窗格→卡片恰好是最小的一跳。
2. **钉死底色前后层次一跳**：`deriveSurfaceRolesFrom` 按固定比例向黑/白 `Color.lerp`，比例照抄 M3 baseline；且 sRGB 混色非感知均匀，同样 4% 的比例纯白底下清晰、**纯黑底下只有 1.062**（gamma 在暗端压得厉害），钉死纯黑的自定义主题层级基本看不见。
3. **同一「系统」主题两端不一致**：Android 走 `CorePalette.toColorScheme()`（系统壁纸调色板），桌面走 `fromSeed(accent)`，两者推出的中性阶梯间距不同，此前无任何收口。

### 修复

`applyFushiSurfaceLadder(ColorScheme)`：只改 tone，色相/彩度锚定原 `surfaceContainer` 的 HCT，主题性格不变。

```
亮色  100 / 99.5 / 96.5 / 93.5 / 90.5 / 87
深色    3 /    5 /  9.5 /   14 /   19 / 24
```

| 关系 | 改前 | 改后 |
|---|---|---|
| 亮色 相邻层 | 1.051 ~ 1.054 | 1.074 ~ 1.100 |
| 亮色 页面底↔卡片 | 1.111 | **1.160** |
| 深色 相邻层 | 1.039 ~ 1.167（不均） | 1.086 ~ 1.176（均匀） |
| 深色 页面底↔卡片 | 1.130 | **1.203** |
| 钉死纯黑 第一级 | 1.062 | ≥ 1.07 |

亮色下探到 tone 93.5 就打住：tone 90 是 `secondaryContainer` 等 `*Container` 角色的地盘，卡片压到 92.5 时实测选中态对卡片从 1.109 掉到 **1.069**，列表选中项反而糊掉；收到 93.5 后是 1.098，与改前持平。深色无此约束（`secondaryContainer` 在 tone 30）。

墨水屏（`buildEinkColorScheme` 全塌成纯黑白，层次由描边承担）与用户钉死底色（`deriveSurfaceRolesFrom`）各自保持语义，不过阶梯。
