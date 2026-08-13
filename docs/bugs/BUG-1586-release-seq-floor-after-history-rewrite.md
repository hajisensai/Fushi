## BUG-1586 · 历史重写让发布序号倒退，全部已装用户永久收不到更新
- **报告**：2026-08-13（用户：本机 Fushi 1.4.0-debug.10405 一直提示已是最新／新包装不上，"怎么会说降级"）
- **真实性**：✅ 真 bug。根因 `tool/release_sequence.sh`（本次新增前：六处 workflow 各写一份 `RELEASE_SEQUENCE=$(git rev-list --count HEAD)`，见 `.github/workflows/release.yml:103`、`main.yml:53`、`release-desktop.yml:89/715/1225/1701`）。
  - 序号取自 `git rev-list --count HEAD`，该值只在「历史只增不减」时单调。2026-08-12 03:37 `origin/develop` 被强推成重写后的历史：同一条提交 `dc328530c`(count 10546) → `139c30dba`(count 9466)，作者时间一致、SHA 全变，`origin/develop` reflog 连着三次 `forced-update`。当前 develop `62d5d8679` count = 9473。
  - 而彼时已发布并装到用户机器上的最大序号是 **10405**（`fushi-debug-rolling` 的 `fushi-1.4.0-debug.10405-*`，出自旧历史 `48978772a`）。
  - 序号倒退同时锁死三处**正确的**单调比较：
    1. `fushi/android/app/build.gradle:92` `versionCode = 1e9 + 100*seq + abiOffset` → 比已装的低 93,200，系统安装器拒装；
    2. `fushi/lib/src/utils/misc/update_checker_release.dart:1706/1731` 按 `releaseSequence` 全序比较 → 判远端「不比本机新」，客户端只显示 `update_already_latest`；
    3. `tool/merge_update_manifest.py:161` "Never downgrades the advertised top-level release" → 新包写不进清单。
  - 实测后果：`update-manifest` 孤儿分支的 `latest-debug-fushi.json` 自 08-11 08:03 起被钉死在 `releaseSequence: 10405`，等于本机装的那一版；#795~#807 十个已合 PR 对所有已装用户不可达。
- **[x] ① 已修复** — `tool/release_sequence.sh` 新增：序号 = 提交计数 + 一次性地板 `RELEASE_SEQUENCE_FLOOR=2000`（同 `versionCodeBase=1e9` 的既有手法），六处 workflow 统一改成 `RELEASE_SEQUENCE=$(bash tool/release_sequence.sh)`；`tool/check_release_policy.ps1` 的共享算式断言跟着改，并新增 `Forbid-Pattern` 禁止再写裸 `RELEASE_SEQUENCE=$(git rev-list`。修后 develop 序号 = 9473+2000 = 11473 > 10546，桥包分支 9114+2000 = 11114 同样越过。**没有放宽上面三处守卫中的任何一处**——它们拒绝更小的序号是对的。
- **[x] ② 已加自动化测试** — `fushi/test/build/release_sequence_floor_guard_test.dart`（5 条）：地板可解析、当前分支序号越过历史最大值 10546、workflow 无绕过地板的裸赋值、守卫非空转反向锚。两条关键断言均做过变异实测（地板改 100 → 红；main.yml 改回裸赋值 → 红）。`tool/check_release_policy.ps1` 也做了同样的注入/还原实测。
- **备注**：
  - 变异实测第一轮**没抓住**地板变异——原实现拿 `git rev-parse --is-shallow-repository` 当跳过闸门，而本机 `.git/shallow` 是历史遗留标记，导致该断言永久静默跳过。已改成按「计数 < 1000 视为截断 checkout」跳过，CI 默认浅 checkout 仍不会假红。
  - 本次修复**不**自动补发任何包：`release.yml` 的 push 触发自 2026-08-07 起因 Fushi 改名过渡期整块注释，发版仍需手动 `workflow_dispatch`。
  - 同期发现但不属本 bug：`v1.4.0-beta.9473` 是半成品发布（只有 ipa+zip），因为同 run 的 windows job 构建失败 → `Publish mirror update manifest` 步骤报 `No files matched fushi-*-windows-setup.exe` 而挂。Windows 构建红另查。
