# 设计 token 单一真相源治理（零视觉语言变更）

分支：`worktree-design-token-governance`（从 origin/develop fresh）
范围：全仓治理管道，数值近似维持（用户拍板：不引入新视觉数值，留下一轮）。

## 核实后的真实图景（实证，非臆想）

用户原诊断的"4 个坑"经实证核实后：

1. **无 type scale = 假阳性**。widget 树内实测：现状有效 TextTheme = 完整 M3 2021 阶梯
   （57/45/36/32/28/24/22/16/14/16/14/12/14/12/11，字重 w400/w500 分级）。字号由 geometry
   在渲染期按 locale 供给；`app_model.dart:1120` 的 flat 15 槽 override 只换 fontFamily，不抹字号。
   → **不改**（改写 = 风险打破现有正确 M3 阶梯）。改为加守卫锁死。
   （附带发现，越界不修：flat override 的自定义 UI 字体被 geometry 的 Roboto 盖掉，custom family applied=false。）
2. **两套间距体系 = 真但已死**。旧 `Space`/`spacing.dart` 仅 4 文件消费。→ **已做**（见进度）。
3. **534 EdgeInsets + 34 BorderRadius = 数字虚高**。真实可落地量约十几处：
   - `BorderRadius.circular` 字面量分布：12×8、8×6、6×4、16×2、10×2、999×1、28×1。
     其中 12/16/28 大多在 `theme_notifier.dart`（主题 shape 配置，本已中心化）；真正消费方漂移
     只有 8×5 + 12×2 ≈ 7 处；6/10/999/×uiScale 无对应 token = 一次性，留原地。
   - `EdgeInsets.all` 分布：24×17（**无 token**）、12×5（无）、8×4（=gap）、16×1（=page）…
     绝大多数硬编码值不匹配现有 5 个 spacing token。为 24/12 发明新 token = 用户推迟的"新数值"，本轮不做。
   → **诚实范围**：把匹配 token 的圆角/间距（值相同）收敛到 const 层；一次性几何留原地 + 守卫防复发。
4. **Cupertino 分叉 22/55 不同步 = 假阳性**。Cupertino 主题从 Material `ColorScheme` 自动派生
   （`main.dart:1148` + `adaptive_theme.dart`），seed 改动自动传导。→ **不做**。

## 核心工程决策

- radii/spacing **与主题无关、是固定常量** → 用 `static const` 常量做迁移目标，
  **保留 const**（若迁到 `HibikiDesignTokens.of(context)` 运行期查找会丢 const，534 处丢 const 不可接受）。
- 只迁**值等于标准角色**的硬编码（数值保持，视觉零变）；一次性几何（3.3px overflow、6/10px 圆角、
  stadium 999、×uiScale）**留原地**，靠守卫 + allowlist 防新增。

## 进度

- [x] **B 间距清尸**（commit `da36c4087`）：迁 4 消费方为数值保持字面量（normal=10 基：
  Space.normal→Gap(10)/small→Gap(4)/semiSmall→Gap(6)/spaces.big→25/spaces.small→4/
  insets.horizontal.small→EdgeInsets.symmetric(horizontal:4)），摘 Spacing 挂载，删 spacing.dart（190 行）。analyze 干净。
- [ ] **C1 const 圆角层**：`HibikiBorderRadius`（design_tokens.dart）static const BorderRadius；
  HibikiRadii getter 委托它（单一真相源）。
- [ ] **C2 圆角迁移**：theme_notifier ~10 shape 配置 + 消费方漂移 ~7 处 → HibikiBorderRadius const。值相同。
- [ ] **C3 EdgeInsets 精确匹配**：all(16)→page/card、all(8)→gap 等少量精确匹配迁移（可选，量小）。
- [ ] **E1 圆角守卫**：源码扫描测试，禁 design_tokens/theme_notifier 之外新增字面量
  `BorderRadius.circular({8,12,16,28})`，带 allowlist。
- [ ] **E2 type scale 守卫**：widget 测试锁死有效 TextTheme 仍有 M3 分级（防未来被 flat 化）。
- [ ] 验证：全量 `flutter analyze` + `flutter test`；合并回 develop。

## 不做（红线/YAGNI）
- 不改 type scale、不改 Cupertino、不发明新数值 token、不迁一次性几何、不重写 theme_notifier/app_model。
- 不动 window.hoshiReader、持久化 key、reader_ttu/ttuBookId 兼容残留。

## Round 2：用户选择"现在就设计新视觉阶梯"（editorial B）

fork 拍板：不停在管道治理，直接上一套新的 "editorial" 视觉阶梯 B（用户从 3 套方向中选定）。

### 新数值（B，已落地）
- **Type scale**（`HibikiTypeScale`，app_model.textTheme 应用）：display 40/33/28 w400；
  headline 24/22/20 w600；title 18/16/15 w600；body 17/15/13 w400；label 13/12/11 w500。
  比 M3 默认（57→11）压缩了 display、加重 headline/title、放大 body 更好读。
  实证确认：显式字号穿过 MaterialApp 的 geometry 合并保留（探针验证）。CJK 安全：letterSpacing 仅 displayLarge -0.25，其余 0。
- **Radii**（`HibikiRadii.*Value` + `HibikiBorderRadius` const）：chip 6、card/group/menu 10、
  control 12、dialog/sheet 16（旧 8/12/16/28，更锐利）。theme_notifier 11 处主题 shape 全部
  引用 `HibikiBorderRadius`（单一圆角真相源，新值真正传导）。
- **Spacing**（`HibikiSpacingTokens`）：page 20、card 20、rowVertical 12、gap 8、+section 32
  （旧 16/16/10；rowV 10 曾不在 4px 栅格）。传导到 83 个 `.spacing.X` 消费方。

### 已知/已接受的后果
- compact list tile 44→48px：新 body 字号更大导致 content-driven 高度增，是"更好读 body"的取舍（已更新断言）。
- 5 个对话框测试用 320×240 极端视口（比任何真机小）恰好被撑破 5px → 视口修正为 320×480（真机 cap≥550px 无影响）。
- 值断言测试（hibiki_material_components / video_quick_settings）更新到新 B 值。
- golden 全部重生成（编辑器渲染 tofu 是 flutter test 标准行为；golden 验圆角/间距/布局/配色）。
  ⚠ golden 在本机 Windows 重生成；若 CI golden job 用其它平台，可能需在该平台复生成。

### 验证
- `flutter test test/`：我改动的全部测试绿；全量残留 ~3 失败是**既有并发 flaky**（每轮不同集、隔离皆过），非本改动。
- `flutter analyze`（含 test）：No issues found。
- ⏳ **待真机截图验证**（阅读器/书架/设置/视频逐屏）——视觉变更按项目铁律需真机复测，尚未做。
