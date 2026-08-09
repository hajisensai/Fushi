## BUG-1481 · fushi 与 hibiki 共用同一套发布通道，hibiki 自更新被结构性阻断
- **报告**：2026-08-09（用户：「fushi-* 的更新应该单起一个 rolling 了吧。hibiki 那个让他留着单独的」）
- **真实性**：✅ 真 bug，三层独立机制叠加，其中第 3 层使 hibiki 自更新**不可能成功**
- **[x] ① 已修复** — manifest 文件名与 rolling tag 改为 `f(产品族, 通道)`；历史名冻结给
  hibiki 族，fushi 侧让路（见「修复」）
- **[x] ② 已加自动化测试** — `fushi/test/tools/update_manifest_product_split_test.dart`
  （CI 脚本 / workflow / 客户端常量三侧同族）、
  `fushi/test/utils/misc/platform_updater_product_test.dart`（挑包永不跨族）、
  `fushi/test/tools/update_manifest_publish_race_test.dart`（跑真脚本，读回的文件名由客户端常量推导＝跨侧钉死）
- **备注**：迁移期两个产品族（`app.hibiki.reader` 老包/桥包 / `app.fushi.reader` 新包）
  并行发布，却共用同一条发布通道的全部基础设施。

### 前提事实（先核实再推理）

- 两族**不是两个仓库**：`hajisensai/hibiki` 已重命名为 `hajisensai/Fushi`，
  `raw.githubusercontent.com` 跟随重命名（实测老名字拉 manifest 返回 200）。
  所以两族共用同一条 `update-manifest` 分支、同一套 release tag、同一个清单文件。
- `releaseSequence` = `git rev-list --count HEAD`（`release.yml:103`），不是 pubspec 的
  `+build`。bridge 分支 10190、develop 10320，develop 持续领先 → 桥包永远是低 seq 那一族。
  （本文档初版把 `+build` 的 1209 当成 seq，写成「差一个数量级」，那是错的；结论方向不变。）

### 三层问题（自下而上，第 3 层是致命的）

**① rolling tag 共享 → 资产混在一起**

`debug-rolling` 上同时挂 `fushi-*` 与 `hibiki-*`。实测该 tag 现有资产全部是 `fushi-*`，
而 release 标题却是「Hibiki debug」。老包若真去这个 tag 取，拿到的是 fushi 包。

**② prune 只按平台分组，不按产品族 → 必然互删**

`.github/workflows/release.yml` 的 prune：候选集用 `case "$name" in *.apk)` 划分，只区分
平台，随后 `sort -rn -u` 取 top `KEEP_SEQS=3` 个 seq。两族 seq 恒有高低之分，top3 恒为
develop 那一族，**桥包的 apk 每次 fushi 构建都会被判为 stale 删除**。注释里 TODO-1131 已
识别过「平台之间互删」并按平台收窄了作用域，但没预见到产品族这一维。

**③ manifest 文件共享 + 单调 seq 守卫 → 低 seq 那一族永远写不进去（致命）**

客户端不读 release tag，读的是 git 分支 `update-manifest` 上的固定文件
（`update_checker_release.dart` 的 `manifestUrlsForChannel`）。两族构建写的是**同一个文件**。

而 `tool/merge_update_manifest.py` 有 TODO-1173 的**单调守卫**：`existing_seq > release_sequence`
时顶层 `tag`/`version`/`releaseSequence` 保持不动，低 seq 的 run 只能刷新自己的平台槽（而槽
本身也按 seq 择优，同样输）。于是顶层永远停在高 seq 那一族的版本与 tag 上。

**这一层对 stable 同样成立，而 stable 才是真实用户所在的通道**——
`update_checker_release.dart` 的 `_fetchChannelRelease*` 里，stable **也是优先读**
`latest-stable.json`（BUG-846「谁后用谁」需要顶层 seq），只有三个镜像全 fetch 失败才回退
`releases/latest` 的 302。所以「发一个 Latest 就能推给老用户」不成立：只要 fushi 写过这个
文件，老 Hibiki 客户端读到的就是 fushi 的版本号、tag 和资产清单，**自动更新不可能成功**，
阻断在 CI 层，客户端过滤修得再对也没用。

### 修复

根因是**文件名/tag 的键少了一维**：只按 `channel` 分，两个产品族撞进同一个命名空间。
修复即把键补全成 `f(产品族, 通道)`，而不是在共享基础设施上继续叠特例（给 prune 加一维、
给单调守卫按族分别维护 seq、客户端再靠过滤兜底）。分族之后，每条通道内部都退回到「只有
一个产品」的简单情形，②③ 一并消失。

归属判据是**「在野客户端认哪个名字，那个名字就归它」**：历史名
`latest-<channel>.json` / `debug-rolling` 冻结给 hibiki 族——已发布的 Hibiki 客户端
（v1.2.0 及更早）把那些 URL 编译进了包里，改不动；fushi 从未发过 stable/beta，让路成本为零。
**所以桥包侧一行未改**（已核实 bridge 分支的脚本仍写 `latest-stable.json`、仍用
`debug-rolling`），改的全在 develop：

- `tool/publish_update_manifest.sh`：`MANIFEST_PRODUCT_SUFFIX="-fushi"`，三个通道的清单名
  统一带后缀。
- `.github/workflows/release.yml` + `release-desktop.yml`（共 5 处）：
  `ROLLING_DEBUG_TAG=fushi-debug-rolling`。
- `fushi/lib/src/utils/misc/update_checker_release.dart`：新增 `kFushiManifestSuffix`，
  6 个清单 URL 常量按它拼。
- `fushi/lib/src/utils/misc/platform_updater.dart`：新增 `assetBelongsToThisProduct` 白名单，
  过滤点放在 `_downloadable()`——这是三个平台 `selectAsset` 把原始 asset map 变成候选的唯一
  漏斗，在漏斗上过滤则新增平台自动继承，也没有「某个调用点忘了传参」的空档。

- `tool/check_release_policy.ps1`：原本硬断言字面量 `ROLLING_DEBUG_TAG=debug-rolling`，
  改 tag 后它会让**发布工作流第一步就失败**（这条守卫是 CI step 1，Dart 定向测试与目录
  枚举型守卫都扫不到 `.ps1`，是第一轮漏网的原因）。改成校验不变式本身：必须是固定
  字面量（TODO-1049 的「不再每次 push 堆一个 prerelease」）、必须以 `debug-rolling`
  结尾、两个 workflow 必须取同一个值（原字面量顺带保证了这点，换成模式后要显式补上，
  否则同一 commit 的 Android 与桌面产物会落到两个不同 release）、且不得是无前缀的
  `debug-rolling`（BUG-1481 本身）。

桥包侧对称的那半（Android 自更新绝不选 `fushi-*`）已在 `561ea2174` 落地。

### 副作用与残余风险

- **已装的 fushi debug 客户端会断更一次**（旧包仍读 `latest-debug.json`，而该文件此后由
  桥包写），需手动装一次新包。当前 debug 通道只有开发者自己在用，代价可接受。
- **在野的 v1.2.0 客户端的 302 回退路径修不了**：它编译进去的回退是 `releases/latest`，
  且那一版没有产品族过滤。只要 fushi 的正式版被标成 Latest，manifest 拿不到的那部分老用户
  就会拿到 `fushi-*` 资产（Android 跨包名装不上，桌面会被覆盖安装）。这不是代码能修的——
  **迁移窗口内 fushi 正式版不要占 Latest**，等老用户迁移完再说。
- 分族只解决「两族互相干扰」。老用户真正收到桥包，仍需把桥包作为正式版发布到 stable
  （发布动作属用户）。

### 为什么不选「给 prune 和 manifest 都加产品族维度」

那是在共享基础设施上继续叠特例：prune 要加一维，manifest 要加一维，单调守卫要按族分别
维护 seq，客户端还要继续靠过滤兜底。分通道是把两个本就独立的发布流真正分开。
