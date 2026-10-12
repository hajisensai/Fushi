## BUG-3281 · 歌词模式标点与引号字形与正文不一致
- **报告**：2026-10-10 应用内反馈 #Uo18xEP8Ks（Windows：标点符号和阅读器模式显示不一致，以阅读器为准）、#sHjyKaghes（Android：日语引号方向不一致）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/audiobook/lyrics_mode_html.dart:259-262`（修前）覆盖层主题的回退字体链以 `system-ui, -apple-system` 打头。那是拉丁系统字体（Windows Segoe UI / Android Roboto / Apple SF），它们自带 “ ” ‘ ’ … — 等歧义宽度标点，CSS 按「链里第一个有该字形的字体」取字，于是这些标点用的是拉丁半角字形（竖排时只能整体侧转，方向与正文不同），而汉字假名与 。、「」 落到后面的日文字体。正文的链（`ReaderContentStyles._bodyFontFamily` → `contentFontFamilyCss`）链首就是按书语言选的 CJK 字体，标点全用 CJK 全角字形。另外歌词竖排不读正文的「竖排字形朝向」设置（`vert_text_orient`），选了 upright 的用户两边朝向也不同。
- **[x] ① 已修复** — 歌词回退链改用与正文同源的 `contentFontFamilyCss`（书的内容语言 `_contentLanguage`，覆盖层主题用黑体链、旧观感用明朝链，`fallbackWhenUnknown: true`）；用户自定义正文字体仍排链首。竖排输出 `text-orientation`，取正文同一设置（关键字白名单，非法值回落 mixed）。提交 `9880325ff1`（分支 `cc/fb-lyrics-mode`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_mode_feedback_batch_test.dart`（`BUG-3281` 组）：body 字体 = 正文同款链、不含 system-ui / -apple-system；自定义字体在链首；无主题用衬线链；text-orientation 跟设置、横排不输出、非法值回落。
- **备注**：未截图对比真机渲染。
