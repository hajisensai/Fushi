## BUG-3808 · 无标题 mdx 都被当成同一本「Title (No HTML code allowed)」
- **报告**：2026-10-23（用户：反馈 cto-U3CIS_，macOS，导入多个没有标题的 mdx 词典时都被当作「Title (No HTML code allowed)」同一本，后面的不会导入）
- **真实性**：✅ 真 bug。MdxBuilder 在作者没填标题时往头部写的是字面占位「Title (No HTML code allowed)」，不是空串；`mdx_reader.cpp` 原样取 `Title`（`native/fushidicts/fushidicts_src/mdx/mdx_reader.cpp:246`），`importer.cpp:1531` 只在标题为空时回退文件名，于是多本无标题 mdx 撞同名，Dart 侧按同名判重复跳过。
- **[x] ① 已修复** — `mdx_reader` 解析头部时把占位标题与空白标题归一成空，交给导入端按文件名命名；真实标题不受影响。提交见分支 `claude/feedback-system-fix-d0ccae`。
- **[x] ② 已加自动化测试** — `native/fushidicts/tests/mdx_placeholder_title_test.cpp`（占位 / 带空白的占位 / 纯空白 → 文件名；真实标题仍胜出）。反向验证：去掉归一化后 3 条 FAIL。
- **备注**：已导入成占位名的那一本不会自动改名；用户删掉重导即可。
