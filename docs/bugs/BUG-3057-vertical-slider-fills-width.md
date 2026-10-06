## BUG-3057 · 竖直 FushiSlider（MD3）横向吃满父级宽度：Slider 在有界高度下撑满、旋转后成一大块
- **报告**：2026-10-06（PR #1984 CI：`fushi_expressive_controls_test`「竖直滑块：旋转 90°」红，RotatedBox 240 高 × 800 宽）
- **真实性**：✅ 真 bug（`d477b5b95aa` 引入竖直滑块起即存在）。Material `Slider` 的 `_RenderSlider.computeDryLayout` 在有界高度下取 `constraints.maxHeight`；`FushiSlider` 竖直时直接 `RotatedBox(quarterTurns: 3, child: slider)`，旋转前高度约束就是父级宽度，于是竖条横向撑满父级（命中区与布局都按整宽算）。Apple 分支自带 `SizedBox(height: m.height)` 不受影响。生产代码暂无竖直滑块使用点。
- **[x] ① 已修复** — `_buildMd3` 竖直时外包 `IntrinsicHeight`，厚度取 Slider 自身固有高度（`fushi/lib/src/utils/components/glass/fushi_glass_toggles.dart:1192`）。提交 `02fd809c731`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/fushi_expressive_controls_test.dart`「FushiSlider M3E 竖直滑块：旋转 90°，方向键上增大」（高 > 宽 + 方向键上增大）。
- **备注**：
