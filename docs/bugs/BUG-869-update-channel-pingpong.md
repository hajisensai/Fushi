## BUG-869 · 调试版与正式版来回更新

- **报告**：2026-07-17（用户：调试版本会互相更新到正式、调试版，来回更新）
- **真实性**：✅ 真 bug。仅影响 beta/debug 通道用户（stable 通道合集只含 stable，见不到预发布，不受影响）。根因是同基版本跨轨判定自相矛盾，`hibiki/lib/src/utils/misc/update_checker_release.dart`：
  - **方向①**（BUG-846）`isUpdateVersionNewer` 同基分支 `if (remotePrerelease == null) return localPrerelease != null;`：装着 `1.2.0-debug.7920` 的用户被判「同基正式版 `1.2.0` 是更新」（semver 里正式版 > 同基预发布）→ 升到正式版。
  - **方向②**（BUG-457/821）`effectiveCurrentVersionForUpdateChannel` 把无后缀的正式版安装 `1.2.0` + versionCode **伪造成** `1.2.0-debug.<正式版seq>` → 远端 `1.2.0-debug.7920`（seq 7920 > 正式版 seq）又被判更新 → 装回调试版 → 回到方向①，无限来回。
  - 两方向各自被测试断言为「正确」，但合起来就是乒乓；`_compareReleaseRecency` 排序「预发布轨优先」与判据「正式版优先」也互相矛盾，无收敛守卫。
  - 关键事实：CI 出的 beta/debug 包 versionName **本就带** `-debug.<seq>` 后缀（`release.yml` 的 `--build-name`），只有正式版是纯 `X.Y.Z`。所以那个「无后缀就当预发布还原」的伪造在生产里几乎只命中真正的正式版安装，硬把它标成预发布轨。
- **[x] ① 已修复** — 根因修复：更新判据改为用户指定的「谁后构建谁赢」——按 release sequence（`git rev-list --count HEAD`，三通道同一把尺）做 `(基版本, 序号)` 全序比较，唯一最大值即目标，天然无来回。`update_checker_release.dart`：
  - `isUpdateVersionNewer` 同基分支改为按 seq 比（`_releaseSeqOf`：预发布串尾号 / manifest 顶层 releaseSequence / versionCode 反解）；两侧 seq 已知比先后，任一未知则保守不更新（同基不 churn）。删除 semver「正式版>预发布」与 `_sameChannelTrack`/`_channelTrackRank` 分支。
  - `effectiveCurrentVersionForUpdateChannel`（伪造串，病根）删除，换成 `currentReleaseSequence`（只提取本机序号、**不改轨道标签**），经 `scheduleCheck`/`_check`/`selectUpdateReleaseForCurrentPlatform` 透传。
  - 正式版通道也读 `latest-stable.json`（CI 早已发布，顶层带 `releaseSequence`）拿正式版序号；`buildReleaseFromManifest` 透出顶层 `releaseSequence`；`manifestUrlsForChannel(stable)` / `kStableManifestUrl` 接线；读不到（手动 GitHub Release 未发 manifest）回退 302，同基保守。
  - `_compareReleaseRecency` 排序改按同一 seq，消除排序/判据不一致。
  - 提交哈希：见本分支 commit（fix(update): BUG-869 …）。
- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/version_comparison_test.dart`：新增 `currentReleaseSequence + 谁后用谁 乒乓根治` 组（序号提取 + 同基「谁后用谁」双向 + 序号未知保守）+ 选择器级**乒乓收敛守卫**（装 stable 升到更晚 debug；装 debug 后不被同基更早正式版拉回→ 返 null 收敛）；跨轨同基/BUG-846 同基断言按新序号语义重写。`hibiki/test/utils/misc/update_checker_manifest_test.dart`：stable 走 manifest + `buildReleaseFromManifest` 透出顶层 `releaseSequence` 守卫。`test/utils/misc/` + `test/settings/` 全绿（812+）。
- **备注**：CI 加固——让手动 GitHub Release 发正式版时也产出 `latest-stable.json`（覆盖 302 无序号边界），随本 PR 一并做。行为变更：同基跨轨在「谁后用谁」下按序号比（放宽 BUG-480 case B 的跨轨互斥，合集门仍保证 beta 用户看不到 debug 轨）。待真机验收：beta/debug 设备连续「检查更新」确认收敛、不再正式↔调试来回。
