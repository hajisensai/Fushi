## BUG-5242 · subagent_wait_slice：链式命令里一条 heavy 自带 --wait-max-min，其余 heavy 都拿不到默认时限
- **报告**：2026-11-22（审查 HBK-AUDIT-234，起因 PR #4115）
- **真实性**：✅ 真 bug。`tool/claude_hooks/subagent_wait_slice.mjs:53` `withHeavyWaitLimit` 对整条命令 `command.includes('--wait-max-min')` 就整体返回 null；`dart tool/heavy.dart --wait-max-min=3 -- flutter analyze; dart tool/heavy.dart -- flutter test a.dart` 的第二条因此不带时限，子代理可能陪一个等不完的队列空等。
- **[x] ① 已修复** — 按每一次 heavy.dart 调用判断：只看这次调用自己的参数（到它的 `--` 或本条 shell 命令结束为止），没有才补 `--wait-max-min=10`；`--` 之后属于被包命令的同名参数不算。
- **[x] ② 已增加自动化测试** — `tool/claude_hooks/subagent_wait_slice.test.mjs` 「judges each heavy.dart run of a chain by its own flags」：首段显式、后段默认 / 首段默认、后段显式 / `--` 之后的同名参数 / 全部显式四种。修复前首例返回 null。
- **备注**：已装到 `~/.claude/hooks/` 的副本要重跑 `node tool/claude_hooks/subagent_wait_slice.mjs --install` 才会更新。
