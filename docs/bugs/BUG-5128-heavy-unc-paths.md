## BUG-5128 · heavy.dart 启动检查把 UNC 共享路径折成当前盘根路径，排队前就拒掉存在的脚本
- **报告**：2026-11-22（外部审计 Codex 2026-11-21 PR 审查 HBK-AUDIT-047，来源 PR #3802）
- **真实性**：✅ 真 bug。`fushi/tool/test_flow/heavy_command_check.dart` 旧 `_absolute`（develop 8b8e6acd28 的 :66-84）把 `\` 统一成 `/` 后按 `/` 切段、丢空段，再以单个 `\` 开头拼回：`\\nas\build share\tools\run build.bat` 变成 `\nas\build share\tools\run build.bat`（当前盘根下），`checkHeavyCommandStarts`（:117-120）拿它查 `File.existsSync` 查不到，`heavy.dart` 以 127 退出、不排队。工作目录本身在共享上时（`.\gradlew.bat`、裸名在 cwd 查找、根相对 `\x`）同样坏；`..` 也会爬过 `\\server\share` 共享根。把新测试跑在旧实现上 6 条 UNC 用例全红。
- **[x] ① 已修复** — `_absolute` 改用 `package:path` 的 `p.windows` / `p.posix` 上下文 `normalize(join(cwd, path))`（Windows 先把 `/` 统一成 `\`，因为 `package:path` 原样保留 `//nas/share` 这种根的写法）：UNC 共享根作为一个整体根保留、`..` 不越过共享根，根相对 `\x` 落到 cwd 的盘或共享上，分隔符统一为本平台的。去掉了手写的 `_isAbsolute` 与切段逻辑。
- **[x] ② 已加自动化测试** — `fushi/test/tools/heavy_command_check_test.dart` 新增 group「UNC paths keep their share root」7 条：带空格的绝对 UNC 批处理、正斜杠 UNC + PATHEXT 补扩展名、cwd 在共享上的相对路径、`..` 不越过共享根、cwd 在共享上的裸名查找、根相对路径留在 cwd 共享、缺失的 UNC 脚本仍被拒。变异实测：换回旧实现 6 条红（缺失脚本那条两边都绿）。
- **备注**：只修排队前的存在性检查。带空格的可执行路径实际启动走 `Process.start(runInShell: true)` 交给 cmd.exe，本修复未改启动路径，未在真实 SMB 共享上实测。
