## BUG-2540 · ASS \fax 切变覆盖 \frz 旋转矩阵项（招牌歪斜）
- **报告**：2026-09-14（Discord 用户 moonbeam：「the background text also appears slanted」——旋转贴合纸面的手写招牌在 Fushi 里看着像被斜切）
- **真实性**：✅ 真 bug。`video_subtitle_overlay.dart` `_applyAssTransform` 里 `rotateZ` 之后用 `m.setEntry(0, 1, fax)` / `m.setEntry(1, 0, fay)` 写切变，把旋转已写入的 ±sin θ 整个覆盖——带 `\frz` 的招牌一加 `\fax`（排版组给倾斜纸面贴字的常规组合）就既不是旋转也不是切变，是一个剪切 + 缩放的怪矩阵。
- **[x] ① 已修复** — 切变作为独立矩阵 `assShearMatrix(fax, fay)` 右乘（`m.multiply`），得到 libass `calc_transform_matrix` 的 R·Shear（先切变再旋转）；`\fscx/\fscy` 仍在最内层。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_ass_shear_test.dart`（`assShearMatrix` 元素；widget：`\frz30\fax0.3` 的 Transform 2×2 等于 R(-30°)·Shear(0.3)，反对角旋转项保留、(0,1) 是合成项而非裸 fax）。
- **备注**：没有用户的 .ass 原件，此条按代码路径判定为必现缺陷；若用户样本另有 `\frx/\fry` 组合，透视项路径未改。
