## BUG-4845 · TXT 超长段落绕过分章上限
- **报告**：2026-11-18，关联 GitHub issue #3725。用户反馈几十 KB 的 TXT 可打开、700 多 KB 的 TXT 打开超时。
- **真实性**：✅ 分章上限失效已沿真实代码路径证实。`packages/fushi_engine/lib/media/audiobook/text_to_epub.dart:122` 的 `_plainTextToHtml` 只按双换行生成 `<p>`，单换行成为 `<br/>`；`_splitIntoChapters`（同文件 `:87`）仅在段落之间切分，不拆超过 30000 字符的单个段落。仅单换行或无换行的小说因此可生成远超上限的巨章。此缺陷与报告现象吻合，但尚未确认它是该设备超时的直接原因。
- **[x] ① 已修复分章缺陷** — 提交 `a6f4fc17`。在章节打包前，将超长纯文本段落拆成有界段落；HTML 长度预算计入 `<p></p>\n`，只在完整 XML 实体、`<br/>` 与 Unicode 码点之间拆分。现有小段落和文件 / 内存导入入口的行为保留。
- **[x] ② 已增加自动化测试** — `fushi/test/media/audiobook/text_to_epub_test.dart`：精确 750 KiB 仅单换行文本、无换行长段落、40 种边界偏移的 XML 转义 / 换行 / 非 BMP 字符。断言多章、各章 body HTML 不超过 30000、XML 可解析、拼接正文无丢失。
- **验证**：直接提取实际源码中的分章和 XHTML 方法进行隔离 Dart 验证，旧实现 1 通过 / 3 失败，修复后 4 通过 / 0 失败；这不覆盖完整 EPUB ZIP / Rust FFI 管线。全量 `flutter analyze --no-pub` 通过（No issues found，退出码 0）。Android 包构建未完成，随后按用户要求停止；未进行真机 / WebView / 三种 view mode 复测，不声明 #3725 已解决。
- **范围**：只修复纯文本导入的分章上限，不调整 8 秒内容就绪提示，不改书架刷新或数据库，也不重写旧书章节 / 阅读位置。旧书已生成的 EPUB 不会因本修复自动改变；可保留原书、用新标题导入原 TXT 副本对照。
