## BUG-1481 · fushi 与 hibiki 共用一条 debug rolling 通道，hibiki 自更新被结构性阻断
- **报告**：2026-08-09（用户：「fushi-* 的更新应该单起一个 rolling 了吧。hibiki 那个让他留着单独的」）
- **真实性**：✅ 真 bug，三层独立机制叠加，其中第 3 层使 hibiki 自更新**不可能成功**
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：迁移期两个产品族（`app.hibiki.reader` 老包 / `app.fushi.reader` 新包）
  并行发布，却共用同一条 debug 发布通道的全部三件基础设施。

### 三层问题（自下而上，第 3 层是致命的）

**① rolling tag 共享 → 资产混在一起**

`debug-rolling` 上同时挂 `fushi-*` 与 `hibiki-*`。实测该 tag 现有资产全部是
`fushi-*`（`fushi-1.4.0-debug.10304/10306/10309/10311-*`），而 release 标题却是
「Hibiki debug」。老包若真去这个 tag 取，拿到的是 fushi 包——安装成第二个空 app。

**② prune 只按平台分组，不按产品族 → 必然互删**

`.github/workflows/release.yml:604-627`：候选集用 `case "$name" in *.apk)` 划分，
只区分平台。随后 `sort -rn -u` 取 top `KEEP_SEQS=3` 个 seq。两族 seq 差一个数量级
（fushi ≈ 10311，bridge = 1209），top3 恒为 fushi，**hibiki 的 apk 每次 fushi 构建
都会被判为 stale 删除**。注释里 TODO-1131 已经识别过「平台之间互删」并按平台收窄了
作用域，但没预见到产品族这一维。

**③ manifest 文件共享 + 单调 seq 守卫 → hibiki 永远写不进去（致命）**

客户端不读 release tag，读的是 git 分支 `update-manifest` 上的固定文件：
`update_checker_release.dart:1506` →
`https://raw.githubusercontent.com/<repo>/update-manifest/latest-debug.json`。
两族构建写的是**同一个文件**。

而 `tool/merge_update_manifest.py` 有 TODO-1173 的**单调守卫**：顶层
`tag`/`version`/`releaseSequence` 永不后退，低 seq 的 run 只能刷新自己的平台槽。
bridge 的 seq 1209 远低于 fushi 的 10311 → **顶层永远停在 fushi 的版本与 tag 上**。

后果：hibiki 客户端读到的是 fushi 的版本号和 tag，再叠加已修好的产品族过滤
（`561ea2174`，只认 `hibiki-*`），它会在 fushi 的 release 里找不到任何自家资产。
**无论客户端过滤怎么修，hibiki 的自动更新都不可能成功**——阻断在 CI 层。

### 附带发现：fushi 侧没有产品族过滤

`fushi/lib/src/utils/misc/platform_updater.dart` 里**没有** `ReleaseProduct` /
`assetBelongsToProduct`——上一轮只在 bridge 侧加了（`561ea2174`）。所以风险是双向的：
fushi 客户端同样会拉到 `hibiki-*`。分通道后这条自然消失（各自的 manifest 只列自己的
资产），比在两侧各加一份过滤更彻底。

### 修复方向（未实施）

按用户指示：**fushi 起新的，hibiki 留着原来的**（老包在野，动它的通道等于断更）。

1. `hibiki` 侧（bridge 分支的 workflow 副本）：`debug-rolling` +
   `latest-debug.json` 全部保持不变，一行不改。
2. `fushi` 侧（develop）：
   - `release.yml:248` 与 `release-desktop.yml:201/816/1324/1798` 的
     `ROLLING_DEBUG_TAG=debug-rolling` → 新 tag（如 `fushi-debug-rolling`）
   - manifest 目标文件名分族（如 `latest-debug-fushi.json`）
   - 客户端 `update_checker_release.dart:1506/1508` 的 manifest URL 同步改
3. 两侧 seq 从此互不相干，单调守卫与 prune 都退化成单产品情形，
   ②③ 一并消失，无需给 prune 增加产品族维度。

**已装的 fushi debug 客户端会断更一次**（旧包仍读旧 URL），需手动装一次新包。
当前 debug 通道只有开发者自己在用，代价可接受；但改动落地那一版必须手动分发。

### 为什么不选「给 prune 和 manifest 都加产品族维度」

那是在共享基础设施上继续叠特例：prune 要加一维，manifest 要加一维，单调守卫要按族
分别维护 seq，客户端还要继续靠过滤兜底。分通道是把两个本就独立的发布流真正分开，
之后每条通道内部都退回到「只有一个产品」的简单情形。
