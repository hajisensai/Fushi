## BUG-4786 · 处理台另存样本文件在 macOS 上必定失败
- **报告**：2026-11-17（PR #3565 遗留项核实：处理台「另存样本文件」在 macOS 上必定失败，file_picker 8.3.7 的 macOS saveFile 收到 bytes 就抛 UnsupportedError）
- **真实性**：✅ 真 bug。根因：`fushi/lib/src/pages/implementations/feedback/feedback_dev_page.dart`（修前 `:453-461`）`_saveFile` 在所有平台都给 `FilePicker.platform.saveFile` 传 `bytes`；file_picker 8.3.7 `lib/src/file_picker_macos.dart:82-83` `if (bytes != null) throw UnsupportedError('Bytes are not supported on macOS')`，走 catch 弹「另存失败」。Windows / Linux 实现收 bytes 但不用，桌面端由我们拿到路径后 `writeAsBytes`，只写一次。同目录 `feedback_dev_video_page.dart:144` 桌面分支不传 bytes，没问题。
- **[x] ① 已修复** — 抽出 `saveFeedbackSampleFile`（`feedback_dev_page.dart:83`）：桌面端（`isDesktopPlatform`）调 `saveFile` 不带 bytes（`:93`）、拿到路径自己写盘；移动端把 bytes 交给插件写、自己不写。`_saveFile` 改调它（`:476`）。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_dev_save_file_test.dart`：照 macOS 行为写的假 picker（收到 bytes 就抛 UnsupportedError），断言桌面分支 `saveFile` 收到的 bytes 为 null 且文件写入一次；取消返回 false 不写；移动分支 bytes 交给插件、自己不写。撤掉实现（桌面也传 bytes）桌面用例红。
- **备注**：没有 macOS 机器，未真机复测；行为依据锁定版本 file_picker 8.3.7 源码。
