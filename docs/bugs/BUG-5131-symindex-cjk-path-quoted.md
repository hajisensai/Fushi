## BUG-5131 · 符号索引按行读 git 文件清单，中文路径被转义后改动文件漏判、返回旧结果
- **报告**：2026-11-22（Codex 2026-11-21 PR 审查 HBK-AUDIT-017，PR #4024）
- **真实性**：✅ 真 bug。根因 `tool/symindex/symdb.py:47-52`（PR head 39351763b1）：`changed_files` 按行读 `git diff --name-only` / `git ls-files -o` 的输出，git 默认 `core.quotePath=true` 把非 ASCII 路径转义成 `"\344\270\255..."`，与索引 `file.path` 里存的实际路径对不上 → 改过的中文路径文件不进改动集合，`sym.py` 仍把它的索引旧行当有效，`live_grep` 也不搜它（新标识符查不到）。临时仓库复现：改动集合得到 `'"\\344\\270\\255\\346\\226\\207/\\344\\271\\231.dart"'` 而非 `中文/乙.dart`。
- **[x] ① 已修复** — b3334488e8：新增 `git_paths`（`tool/symindex/symdb.py:45`），所有 git 文件清单统一带 `-z` 按 NUL 切原始路径（`changed_files` 的 diff / untracked、新增的 `files_under`）；任一 git 调用失败整体降级。`sym.py` 的 `git grep` 降级输出加 `-c core.quotePath=false`，中文路径按原样显示。
- **[x] ② 已加自动化测试** — `tool/symindex/symdb_test.py` 的 `ChineseChangedFilesTest`：中文路径的 tracked 修改、未跟踪、删除、已暂存四种改动，以及已提交改动后索引旧行被丢弃、实时搜索命中新标识符。变异实测：撤回 `-z` 改回按行读，两条用例变红（`FAIL: test_cjk_tracked_untracked_deleted_and_staged` 等），恢复后 14/14 通过。
- **[x] 同根补修（审查复核时发现）** — 仓库根路径含中文时 `build.py` 的 `git()`、`sym.py` 的 `repo_root()` 读 `git rev-parse` 输出没指定 encoding，Windows 按本地代码页 cp936 解 UTF-8 字节失败，`stdout` 为 None → `AttributeError` 崩溃（临时仓库 `中文仓库/` 实测两个入口都崩）。两处改为 `encoding='utf-8'`；`symdb_test.py` 的 `CjkRepoRootTest` 在中文根目录里建索引并实时查询。变异实测：分别撤回两处 encoding，用例各自变红，恢复后 15/15 通过。
- **备注**：纯 Python 工具，无设备复测需求。
