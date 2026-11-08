## BUG-4242 · fushi_server backup: --config <path> after the subcommand is taken as the restore-config flag
- **报告**：2026-11-08（服务端 Fushi 复习端到端测试，还原备份时）
- **真实性**：✅ 真 bug。`fushi_server backup restore <file> --yes --config my.yaml` 打印用法、退出 64；`--config` 写在 `backup` 前面才行。README 说「所有子命令接受 `--config <path>`」。
  - 根因：`packages/fushi_server/lib/src/commands/backup_commands.dart:44`（修复前）`addFlag('config', defaultsTo: true)` 给 `--no-config` 用。package:args 在子命令没定义某个选项时才退回顶层的同名选项；子命令自己的可取反 flag `config` 盖住了顶层的 `--config <路径>`，于是 `--config` 被当成「还原配置」开关，路径变成多余的位置参数，`command.rest.length != 2` → 用法错误。失败是安全的（不会用错配置），只是用不了。
- **[x] ① 已修复** — 改成不可取反的 `addFlag('no-config', negatable: false)`（`backup_commands.dart:46`），读取处 `command['no-config']`（`:161`）。命令行拼写不变（仍是 `--no-config`），顶层 `--config <路径>` 放在子命令后面也认。提交见本分支。
- **[x] ② 已加自动化测试** — `packages/fushi_server/test/cli_exit_code_test.dart`「--config <path> after `backup restore` is the global option」：经真实 `runFushiServerCli` 解析，备份文件不存在时得到 66（找不到文件）而不是 64（用法错）；带 `--no-config` 同样。旧定义下该用例失败（Expected 66, Actual 64）。
- **备注**：服务端包 `dart test test/server_backup_test.dart test/cli_exit_code_test.dart` 12/12 通过，`dart analyze` 无问题。
