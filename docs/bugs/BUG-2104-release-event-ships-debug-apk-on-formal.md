## BUG-2104 · 手动发 GitHub Release 会把 debug APK 捎带上正式版
- **报告**：2026-09-03（发 v2.2.4 正式版时实测中招，不是用户报告）
- **真实性**：✅ 真 bug，**线上实测**。v2.2.4 的资产表与已发布的 `latest-stable-fushi.json` 里都多出一条 `fushi-2.2.4-07662d7-debug.apk`。
- **根因**：`.github/workflows/release.yml`
  - `:135` `BUILD_DEBUG_APK=true` 是**初值**；
  - `push)`（`:155`）、`workflow_dispatch` 的 `debug)`（`:166`）/ `beta)`（`:176`）/ `formal)`（`:188`）**四条分支各自显式设成 false**；
  - **只有 `release)` 分支漏了** ⇒ 留在默认 `true`，构建出 `fushi-<ver>-<sha>-debug.apk`；
  - 而该分支的上传 glob 是 `FILES="fushi/build/release-artifacts/fushi-*.apk"`（`:206`），顺手把它扫进 release 资产表，`publish_update_manifest.sh` 又照资产表写进清单。

  **`release` 事件正是本仓文档里正式版的一等路径**（BUG-869 的注释写明「手动发布的非 prerelease GitHub Release **就是**正式版」），所以这条必然复发——v2.1.1 侥幸没中，只因为它走的是 `workflow_dispatch channel=formal`（那条设了 false）。
- **影响**：**不致命**。两批已出货客户端都按文件名把 `-debug.apk` 排除在 stable/beta 之外——
  - 在野快照：`fushi/test/utils/misc/formal_asset_naming_legacy_contract_test.dart` 的 `legacyIsDebugApkAsset` / `legacyMatchesStableChannel`；
  - 当前客户端：`fushi/lib/src/utils/misc/platform_updater.dart:224-231` 的 `_isDebugApkAsset`，`stable || beta => !_isDebugApkAsset(name)`。

  所以没有任何设备会选中它。实际代价是三条：正式版页面上多一个 debug 构建可供手动下载、白烧一次 debug APK 构建、已发布清单里多一条无用条目。
- **[x] ① 已修复** — `release)` 分支补 `BUILD_DEBUG_APK=false`，与其余四条分支一致。
- **[x] ② 已加自动化测试** — `fushi/test/build/release_workflow_diagnostics_guard_test.dart` 新增守卫：**每条终端通道分支都必须显式设 `BUILD_DEBUG_APK`**，不许继承初值。
  - 判据故意钉「每条都显式赋值」而不是「`release)` 里有 false」——后者只堵这一条腿，下一个新增的通道分支照样继承默认值。
  - 实现踩过一个坑并已修：`workflow_dispatch)` 里有**嵌套** `case "$CHANNEL" in`，按「第一个 `esac`」找外层收口会命中内层那个、把 `release)` 排除在窗口外（第一版就是这么红的，报「release) 不见了」）。现在 `esac` 与 `;;` 都**按缩进配对**，并带分支体窗口下界自校验。
- **备注**：v2.2.4 这个已发布的正式版**没有回头去删**那个 debug 资产——删了会让已发布的 `latest-stable-fushi.json` 里留一条指向不存在文件的条目，制造不一致，而收益只是页面整洁；既然两批客户端都证明会忽略它，就让它留着，从下一版起不再产生。
