## BUG-869 · 静态 \fscx/\fscy 被按行级「最后值生效」建模，句尾/前缀压扁标签把整行压扁
- **报告**：2026-07-16（用户：Youjo Senki S02E02 NanakoRaws .ass 对比 PotPlayer「咱们的全扁了」；该文件 432 处 `\fscx50` + 215 处 `\fscx100`）
- **真实性**：✅ 真 bug。ASS 的 `\fscx`/`\fscy` 是 **span 级**标签（标签处生效直到下一次覆盖）：`{\fscx50}（名前）{\fscx100}本文` 只压说话人前缀、`…足りません{\fscx50}。` 只压句尾句号。我们（修复前）把静态值累积成**行级**单值（最后值生效）经 `_applyAssTransform` 整盒缩放——探针实测句尾式整行 scale=0.5→0.5（「全扁了」），前缀式整行 1.0（该扁的不扁）。
- **[x] ① 已修复** — parser：静态 `\fscx`/`\fscy` 写进段样式 `SubtitleSpan.scaleX/scaleY`（1.0 归一成 null；同时保留 xf 供 `\t` 动画 from 基线，TODO-1374 招牌弹入不回归）。overlay：`_applySpanScale` 逐字符缩放——布局盒宽压成 advance×sx（`_charSize` TextPainter 测量缓存 + SizedBox），`OverflowBox` 定尺寸 + `Transform`（底部中心锚≈基线缩放）真缩字形；行高不变（近似）。行级 Transform 只保留 `\t` 缩放动画（动画在场时 span 静态缩放跳过防双重）与样式表 ScaleX/Y。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_span_scale_test.dart`：①parser 断言前缀段 scaleX=0.5/主文段恢复、句尾式只覆盖句号 grapheme；②widget 断言 overlay 内恰一个缩放布局盒、宽=正常 advance×0.5、未标注字符不受影响。既有 video/+audiobook/ 2333 测试无回归（含 TODO-1374 招牌 \t 动画）。
- **备注**：`\fscy` 纵向缩放不改行盒高（libass 会改行高，罕见场景接受近似）。姊妹链：[[BUG-855]] [[BUG-867]]。
