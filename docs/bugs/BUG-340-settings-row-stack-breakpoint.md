## BUG-340 · 设置行 <360 竖排堆叠断点过宽（全 App 设置行观感退化）
- **报告**：2026-06-19（用户：TODO-599 / 551 审计发现的低危回归）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/utils/components/settings_shared.dart:325`（d95923c6c 引入）
- **[x] ① 已修复** — commit `2cc1823c6`
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/settings_shared_test.dart`
- **备注**：

### 根因
`d95923c6c`（`fix(video): make control settings responsive`）给 `AdaptiveSettingsRow.build`
的 `LayoutBuilder` 加了一个**固定**断点 `constraints.maxWidth < 360`：只要行带非 flex
的 `trailing`（开关 / 步进器 / 内联下拉），可用宽度 < 360 就把控件从「label 左 / 控件右」
横排改成「label 一行 / 控件下置一行」竖排堆叠。

问题在于 `360` 是个无依据的魔数，且远大于真正放不下的宽度：

1. `_buildRowLayout` 里 label 本就是 `Expanded`（会收缩 / 换行），`trailing` 又是自尺寸
   （契约见 line 294-303 注释），所以横排在远低于 360 的宽度都不会溢出——根本没有横向压力。
2. 一张设置卡片在常见手机（逻辑宽 360-411dp）减去页边距后，行的 `maxWidth` 经常落在
   ~328-380。**高 UI scale 时 App 把逻辑宽缩小，`maxWidth` 更容易掉到 360 以下**，于是
   几乎每一行带控件的设置行都被错误地竖排堆叠，对齐 / 观感整体退化。

即：断点把「有充足横向空间」的正常行也当成了「窄到放不下」。真正需要堆叠的视频设置行
走的是**显式** `controlBelow: true`（`video_quick_settings_sheet.dart` 569/712/841/990/...），
不依赖这条 `< 360` 自动堆叠分支——所以收紧 / 改对断点不会破坏视频设置的响应式意图。

### 修复
把固定 `360` 换成**随文本缩放联动**的阈值，使「窄到放不下才堆叠」成立：

```dart
final double textScale = MediaQuery.textScalerOf(context).scale(1);
final double stackThreshold = (180.0 * textScale).clamp(180.0, 420.0);
...
constraints.maxWidth < stackThreshold
```

- 1x（默认字号）→ 阈值 180dp，远低于任何真实手机设置行宽度（≈320-380dp），正常行恢复横排。
- 2x（超大字号）→ 阈值 360dp，label 与控件都变大、确实需要更多空间时仍会下置堆叠。
- clamp 上界 420 防止极端缩放要求一个不可能的宽度。

依据：横排真正放不下的临界宽度 ≈ 内边距(2×rowHorizontal=32) + 可读 label 最小宽 + gap(12)
+ 自尺寸控件宽，在 1x 下约 280dp 以内；选 180dp 作 1x 基准留足裕量，既不误堆叠也不溢出。
`Never break userspace`：极窄屏 / 超大字号下确实放不下时仍正确堆叠（守卫覆盖）。

### 测试
`hibiki/test/widgets/settings_shared_test.dart`：
- `normal-width switch rows stay horizontal at 1x scale (no spurious stack)`——
  360 / 400 宽 + 1x，断言开关在 label **右侧**且**同一行**（横排）。撤回 360 即转红（已实测）。
- `truly narrow switch rows stack the control below the label`——
  280 宽 + 2x，断言开关下置堆叠（响应式仍生效，未破坏 d95923c6c 意图）。
- 原有 `narrow non-flex trailing rows stack without overflow`（320@2x）与
  CJK 2x 用例仍绿（阈值 2x→360，maxWidth≈320<360 仍堆叠）。
