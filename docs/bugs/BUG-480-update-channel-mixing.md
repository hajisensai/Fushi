## BUG-480 · 更新渠道混推：稳定版收到调试/测试版同基版本推送 + 同基跨通道未当成同版本
- **报告**：2026-06-30（用户：「现在 hibiki 的更新一直推送？我刚下的新版选的也是稳定版都被推送了。正式版/测试版/调试版更新一定不能混。并且更新有检测版本号相同吗？」）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/utils/misc/update_checker_release.dart:1254-1256`（`isUpdateVersionNewer` 的 debug/beta 分支）
- **[x] ① 已修复** — `hibiki/lib/src/utils/misc/update_checker_release.dart` `isUpdateVersionNewer`（提交 PENDING）

  **根因**：`isUpdateVersionNewer(remote, local, channel)` 在 debug/beta 通道里，当远端/本地**基版本相同**（`_compareBaseVersion==0`）时有两条错误早退：
  - `if (localPrerelease == null) return true;` — 本地是正式版（如 `1.0.1`，无预发布段）时，把**同基**的预发布远端（如 `1.0.1-debug.6208`）判成更新。这违反 semver（`1.0.1-debug.x < 1.0.1`，预发布**早于**正式版）且把调试包回灌到正式版装机=混推。
  - `if (!_prereleaseBelongsToChannel(localPrerelease, channel)) return true;` — 本地是**别通道**预发布（如 `1.0.1-beta.x`，当前通道=debug）时，把同基的 debug 远端判成更新=跨通道混推。

  这两条同时也是「不检测版本号相同」的根：同基同序号在某些通道组合下不会落到序号严格比较，被早退成 `true`。

  **复现（纯函数实测，根因修复前）**：
  - `isUpdateVersionNewer("1.0.1-debug.6208", "1.0.1", debug)` → `true`（正式装机被同基 debug 推送）。
  - `isUpdateVersionNewer("1.0.1-debug.6208", "1.0.1-beta.6096", debug)` → `true`（beta 装机被同基 debug 跨通道推送）。
  - 配合 debug 通道每几分钟出一版（仓库实测 `v1.0.1-debug.6203/6204/6206/6208/...`），表现为「一直推送」。

  **修复**：基版本相同时**严格只在「本地也是本通道预发布」且「远端本通道序号严格更大」**才算更新；本地是正式版、或本地是别通道预发布、或序号相同/更小 → 一律 `false`。把两条 `return true` 改成 `return false`。跨通道升级走「基版本递增」（`baseCompare > 0`）这条正路，不靠同基回灌，三通道严格隔离；同基同号统一落到序号比较返回 `false`，根除「不检测版本号相同」。stable 通道走 `isVersionNewer`（既有正确的「正式版胜过同基预发布」非对称逻辑），不变。

  **版本比较口径**：自更新比的是 **tag 归一后的语义版本**（`normalizeReleaseVersionTag` 剥前导 `v` 与 `+build` 元数据，如 `v1.0.1-debug.6208+cdff223` → `1.0.1-debug.6208`），与本地 `PackageInfo.version`（`build-name`，正式版=`1.0.1`、debug 版=`1.0.1-debug.<seq>`）比较。Android `versionCode`（CI `git rev-list --count`）**不参与**自更新比较。

- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/version_comparison_test.dart`（提交 PENDING）

  新增 BUG-480 用例组（最强可落地层=纯函数 `isUpdateVersionNewer` 直测）：
  - 同基正式装机不被 debug/beta 预发布推送（混推根因，断言 `isFalse`）。
  - debug 通道不推送到同基 beta 装机 / beta 通道不推送到同基 debug 装机（跨通道隔离）。
  - 同通道序号递进仍为真更新（不误伤正常 debug→debug / beta→beta 升级）。
  - 同基同序号（含带 `+build` 元数据）必判 `isFalse`（拒绝同版本）；stable 同版本号 `isFalse`。
  - 基版本递增的跨通道 opt-in 仍更新（正路保留）。

  同时把既有 `version_comparison_test.dart` 里编码旧（错误）意图的 `selected prerelease channels can move from same-base stable`（断言同基正式版可被本通道预发布推送=`isTrue`）改为新隔离契约；`update_checker_release_selection_test.dart` 三个用 formal `currentVersion: '0.5.1'` 的资产选择用例改用更低的 formal 基版本 `0.5.0`（让更新合法、资产选择覆盖不变）。

- **备注**：integration owner 落地（worktree 分支 `fix-1025-update-channel`，未 push 未合并）。stable 通道路径与 release/manifest 过滤（`releaseMatchesUpdateChannel`）本就正确隔离，无需改；本修只动版本「是否更新」的语义判定。
