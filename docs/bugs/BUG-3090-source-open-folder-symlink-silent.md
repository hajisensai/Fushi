## BUG-3090 · 来源「打开文件夹」：根目录是符号链接/联接点时被当文件选中，打不开时无提示
- **报告**：2026-10-09（审查 `f84a2186` 时发现）
- **真实性**：✅ 真 bug。`f84a2186` 把来源「打开文件夹」改走 `revealInFileManager`，它按 `FileSystemEntity.type(value, followLinks: false)` 判类型（`fushi/lib/src/utils/misc/reveal_in_file_manager.dart:115`，修前）：来源根目录是符号链接 / Windows 联接点时判成 link（非 directory），Windows 变成 `explorer /select,`（在父目录里选中它）而不是打开文件夹，Linux 打开的是父目录——相对旧的直接 `explorer <dir>` 行为退化。另外 `_openFolder`（`fushi/lib/src/pages/implementations/media_sources_view.dart:1234`）丢弃返回值，根目录不存在 / 盘没挂时点了没反应，违反原语「返回 false 调用方须提示」的契约。
- **[x] ① 已修复**（见本分支提交）— 原语新增「打开目录」形态 `openDirectoryInFileManager`（类型判断跟随链接 `followingLinkEntityType`，解析后是目录才以目录参数调用文件管理器；不存在 / 悬空链接 / 非目录返回 false），`revealInFileManager` 的「选中」语义不变。`_openFolder` 改用它，返回 false 时 `FushiToast` 报错（新 key `media_source_open_folder_failed`，经 `i18n_sync --add`）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/utils/reveal_in_file_manager_test.dart`：真实符号链接 → Windows 不带 `/select,`、Linux `xdg-open <链接>`；不存在 / 普通文件 / 悬空链接返回 false 且不启动文件管理器；移动端 / xdg-open 失败返回 false。
  - `fushi/test/pages/media_source_open_folder_backslash_guard_test.dart`：`_openFolder` 走 `openDirectoryInFileManager` 且失败时提示。
- **备注**：Windows 联接点未在 Windows 真机验证（本机 Linux），按 `FileSystemEntity.type` 跟随链接的语义推定。
