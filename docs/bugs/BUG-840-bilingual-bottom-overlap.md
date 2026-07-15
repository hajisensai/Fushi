## BUG-840 · 双语底部对白跨层/边距重叠
- **报告**：2026-07-15（用户：截图画面底部日文「クローゼットに押し込んだだけ…」与中文「不就是一股脑塞进衣柜里吗」糊在同一条基线）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_subtitle_overlay.dart` 的 `_positionKey`（`:L$layer` 后缀 + `:$ml:$mr`）把双语两条底部对白（日文一层 + 中文一层、或 MarginL/R 各异）拆成不同 `_positionKey` 组，各组独立 `Positioned.fill` 定位、又都被 `_paddingFor` 的 `max(bottomPadding, scaledMarginV)` 夹回同一底基线 → 叠印。既有 `_positionKey` 的 MarginV 折叠只覆盖「同 layer/margin、仅 MarginV 异」的双语（[[project_ass_blur_border_and_group_flicker_bug796_797]] 的 marginv 守卫），跨 Layer / 跨 MarginL/R 落在缺口外——组间**无全局碰撞避让**。
- **[x] ① 已修复** — `video_subtitle_overlay.dart` 新增 `_mergeBottomBaselineGroups`：把**文本两两互异**的底部基线折叠组（无 \pos/\move、竖直锚=底部、MarginV 会被夹回基线）按水平锚点分桶合并进一个竖排堆叠组（libass 同位不同文本竖排避让），键归一为不含 Layer/MarginL/R 的底部基线桶。桶内出现重复文本（同句多层拷贝=卡拉OK特效层）则整桶不合并，各层仍同位叠画（[[project_ass_blur_border_and_group_flicker_bug796_797]] BUG-833 不回归）。提交 `4d4be72e9`。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_bilingual_cross_layer_overlap_test.dart`：跨 Layer（JP layer0 + CH layer1）竖排分行不叠印；跨 MarginL 竖排分行；同文本多层拷贝仍同位叠画一行。
- **备注**：右侧字幕列表把双语显示成相邻两行是**正确**的（各占一行）；列表里同文本重复才折叠（[[BUG-839]]）。触发本 bug 的双语 `.ass` 用户已无留档，按「跨组底部避让 + 同文本不拆」的通用 libass 语义修，待真机 A/B 复测原始双语文件。
