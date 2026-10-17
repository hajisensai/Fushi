## BUG-3023 · 音频来源弹窗：丢失文件提示把说明挤成一列字、重新选择按钮被推出视口
- **报告**：2026-10-06（PR #1984 CI：`test/pages/audio_sources_missing_file_test.dart` 4 条红）
- **真实性**：✅ 真 bug（M3E wave 1 回归，43b39c92702）。`fushi/lib/src/pages/implementations/dictionary_settings_dialog_page.dart:619` `_UnavailableSourceNotice` 把说明（`Expanded`）与「重新选择音频数据库」`FushiTextButton.icon` 放进同一个 `Row`：按钮按固有宽度先占位，560px 弹窗里说明只剩约 17px 宽、逐字换行把整行撑到约 860px，按钮被推出来源列表的可滚视口（测试里点击落在窗外，回调收不到）。手机窄屏与长译文同样会出现。旧版是说明与按钮上下排列。
- **[x] ① 已修复** — 06e965a92b2：errorContainer 色块内改为「图标 + 说明」一行、按钮另起一行靠尾对齐。
- **[x] ② 已加自动化测试** — 06e965a92b2：`fushi/test/pages/audio_sources_missing_file_test.dart`「BUG-3023 missing-file notice keeps the explanation readable…」钉说明宽度 > 来源行一半、按钮中心在列表视口内（旧布局下红：说明宽 17.3px）。
- **备注**：
