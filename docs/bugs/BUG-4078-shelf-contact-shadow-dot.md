## BUG-4078 · shelf-contact-shadow-dot
- **报告**：2026-11-04（用户：库页封面底下很多地方都有一个黑点，截图是游戏库网格）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/shelf_cover_material.dart` 的 `ShelfContactShadow` 用 `RadialGradient` 画接触阴影；径向渐变半径默认按盒子**短边**算（0.5 × shortestSide），而阴影盒是「封面宽 × 1.07」×16dp 的扁条，于是只剩正中一颗 16dp 直径的圆点，其余全透明——读作每张封面底下一个黑点。书架 / 漫画 / 视频 / 游戏库共用这一个组件，全都中招。
- **[x] ① 已修复** — 给渐变加 `_StretchToEllipse`（`GradientTransform`），绕中心按 宽/高 横向拉伸，圆变成铺满整个阴影盒的椭圆。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/shelf_cover_material_test.dart`「横版封面」用例：取阴影的 `RadialGradient.transform`，断言短边圆的右端点被映射到盒子右边（旧实现 transform 为 null 直接红）。
- **备注**：
