## BUG-968 · 有声书片段导出文字与选区不符且移动端缺少音频
- **报告**：2026-07-21（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/pages/implementations/reader_hibiki/audiobook.part.dart:1176` 的动态卡片直接渲染对齐 cue 文本而非 EPUB 实际选区；`audiobook_clip_export.dart:351` / `:502` 依赖 FFmpeg 隐式选流；移动端仅分享 MJPEG/MOV 视频时，部分接收端会忽略容器内 AAC，造成用户看到“缺少音频”。
- **[x] ① 已修复** — 本提交仅在 cue 拼接文本与实际选区按空白归一化后完全一致时启用动态卡片，否则回退到精确选区静态卡片；两条 FFmpeg 路径显式映射 `0:v:0` 与 `1:a:0`；移动端 MOV 分享时同时附带裁剪后的 AAC，并保留文件供系统异步读取。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/audiobook_clip_export_contract_test.dart` 覆盖选区/cue 一致与不一致、静态/动态显式音频映射、MOV 附带 AAC；连同现有合成和移动选区守卫共 46/46 通过，`flutter analyze --no-pub` 0 问题。
- **备注**：当前没有已连接的 Android 实机，因此“手机端接收应用实际拿到视频 + AAC”仍待真机导出复测；PR 保持 Draft，不把源码与自动化结果冒充实机结论。
