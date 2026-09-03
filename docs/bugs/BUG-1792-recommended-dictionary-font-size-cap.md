## BUG-1792 · 推荐字体超过8MiB导致词典字体静默不生效
- **报告**：2026-08-23（用户：）
- **真实性**：✅ 真 bug。现场 Klee One 文件为 8,724,204 字节，超过 `DictionaryFontCss` 原 8 MiB 单文件上限（8,388,608）；Noto Sans JP 与 Shippori Mincho 推荐文件也超过该上限。构造词典弹窗 CSS 时这些文件会被静默跳过。
- **[x] ① 已修复** — 将单个内联字体的有界上限提高到 32 MiB，覆盖当前推荐的中日韩字体，同时保留同步读取与 data URL 的硬上限保护。
- **[x] ② 已加自动化测试** — `fushi/test/reader/dictionary_font_css_test.dart` 固定默认上限必须覆盖至少 10 MiB 的推荐字体。
- **备注**：字体 data URL 仍由现有 `(path, mtime, size)` 缓存复用，避免每次查词重复读盘和 Base64 编码；本次按用户要求跳过测试。
