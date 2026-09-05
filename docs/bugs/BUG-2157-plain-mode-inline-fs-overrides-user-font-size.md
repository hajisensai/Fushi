## BUG-2157 · 关闭尊重字幕自带样式后行内 fs 仍覆盖用户字号，字号滑块整条失效
- **报告**：2026-09-05（用户：「尊重 ass 关了也是改不了大小」）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/media/video/video_subtitle_overlay.dart:2668`（修复前行号）
- **[x] ① 已修复** — `video_subtitle_overlay.dart` `_styleForGrapheme`：行内 `\fs` 字号改为与 `respect` 同源门控，关闭「尊重字幕自带样式」时回落 `base.fontSize`（用户滑块字号）。提交见本条末。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_plain_mode_inline_fontsize_test.dart`（4 条：单段 `\fs`、滑块跟随、一行多段 `\fs` 混排统一、respect 开不回归）。修复前 3 红 1 绿，修复后 4 绿。
- **备注**：

### 现象

视频页把「尊重字幕自带样式」关掉后，字幕外观设置里的**字号滑块对 .ass 字幕完全无效**——
拖到最大最小画面上字都一样大。用户预期是「关掉就一律用我的外观设置」（开关文案 `video_setting_subtitle_respect_ass_hint` 原文：
"turn off to force your appearance settings"）。

### 根因

`_styleForGrapheme` 里行内 span 的字号是唯一**没有**被 `respect` 门控的外观通道：

```dart
fontSize: span.fontSizePx != null
    ? (respect ? _scaleAssFontSize(...) : span.fontSizePx!)   // ← 关掉尊重也照用作者 \fs
    : base.fontSize,
```

`base.fontSize` 才是用户滑块字号（纯字幕模式下 `cueFontPx` 恒 null，基线正确）；但只要这行 ASS 带
`{\fs...}`，`span.fontSizePx` 就把它整条盖掉。而且盖上去的是 **PlayRes 空间的裸数字**（`\fs90` → 逻辑像素 90），
连 respect 开时那套「按显示区高/PlayResY 缩放 + 字体 cell/em 校准」都没走，属于脏值直穿渲染。
fansub 的 ASS 对白普遍每行套 `{\fs...}`，所以用户看到的是「滑块彻底没反应」而不是「偶尔没反应」。

这与 BUG-1285（纯字幕模式下行内 `\c` 主色穿透，OP 歌词渲染成黑字）**完全同型**：兄弟属性
`\c`/`\1c` 主色、`\3c` 描边色、`\1a` 填充透明度、`\fsp` 字距、`\shad` 阴影、`\fscx/\fscy` 缩放、
cueStyle 主色/字号、`\t` 动画都已按 `respect` 门控，`\fs` 是最后一条按「历史 span 行为」放行的漏网。

### 修复

`fontSize` 改成 `(respect && span.fontSizePx != null) ? _scaleAssFontSize(...) : base.fontSize`，
并更新 `_styleForGrapheme` 的文档注释（原文写着「只保留行内 `\i \b \u \s` 这些文本语义与历史 `\fs` 裸像素字号」）。
respect 开的路径逐字节不变。

### 验证

- 新守卫 4 条：修复前 3 红（`Expected: <36> Actual: <90.0>`）、修复后 4 绿。
- `fushi/test/media/video` 全目录：`FLUTTER TEST VERDICT: PASSED - 3274 tests ran, all tests passed`。
