## BUG-1516 · 更新清单保留已被 prune 的资产条目，客户端下载必 404
- **报告**：2026-08-11（用户：截图，Windows 1.3.1-debug.10156，调试版通道）

  ```
  下载失败: HttpException: download failed (404):
  https://github.com/hajisensai/hibiki/releases/download/debug-rolling/hibiki-1.3.2-debug.10182-windows-setup.exe
  ```

- **真实性**：✅ 真 bug，根因 `tool/merge_update_manifest.py:161`（`merge_manifest` 的跨平台资产并集无存活性校验）。

  实测取证（2026-08-11）：
  - 用户报错那条 URL：`curl -o /dev/null -w %{http_code}` → **404**。
  - 对照当前本体安装包 `fushi-1.4.0-debug.10405-windows-setup.exe` → **206**（存活）。
  - `gh release view debug-rolling` 现存资产里**没有**任何 `1.3.2-debug.10182` 文件，只剩
    `fushi-1.4.0-debug.10306/10311/10332` 与一个 `hibiki-1.3.3-debug.10192` 的 apk。
  - 老客户端读的 `latest-debug.json`（hibiki 族清单，见 `update_checker_release.dart` 的
    `kFushiManifestSuffix` / BUG-1481）**自相矛盾**：顶层 `version: 1.3.3-debug.10192`、
    `releaseSequence: 10192`，而 `assets` 里 Windows 那条仍是
    `hibiki-1.3.2-debug.10182-windows-setup.exe`。

  根因**两层**，第一版只写到了浅的那层，补齐如下。

  **浅层（谁把 URL 变成死链）**：`merge_manifest` 的设计是「跨平台并集 + 每平台保留自己
  最高 seq 的资产」，好让某个平台停更时客户端不至于 `selectUpdateReleaseForCurrentPlatform`
  返回 null。但 rolling release 会**按平台 prune 旧资产**（`release.yml` /
  `release-desktop.yml`），两者之间没有任何一致性检查。于是某平台一旦长期不发版：清单里那条
  留存条目指向的文件被删掉、清单还在广告它 → 必 404。这不是 hibiki 族独有，
  `latest-debug-fushi.json` 同构。

  **深层（Windows 的 hibiki 族为什么会「长期不发版」）**：这不是疏漏，是 BUG-1481 的拆族
  副作用，且它砍掉的是**桌面端唯一的迁移路径**。

  - 桥（`bridge/auto-migrate-download`）是 **Android 专属**：`migration_page.dart:22`
    「仅 Android 挂入口（跨包名迁移只存在于 Android；桌面端数据可直接搬）」。
  - 桌面端**不需要**桥，因为它换包名靠安装器覆盖安装：`platform_updater.dart` 的
    `AndroidUpdater.selectAsset` 注释写死「桌面不做这层提升：Windows/macOS 换包名靠安装器
    覆盖安装，Phase 5 有意如此」。`WindowsUpdater.selectAsset` 传的是 `ReleaseProduct.any`
    （不提升成 `.own`），所以 **Hibiki 的 Windows 客户端本来就会选中并安装
    `fushi-*-windows-setup.exe`** —— 那一次覆盖安装就是桌面端的「迁移」。
  - BUG-1481 为了让 Android 不被塞跨包名 APK（安卓装不上，`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）
    把清单**按整个文件**拆族。Android 侧完全正确；但桌面侧需要的恰恰相反。拆族后
    `latest-debug.json` 再也收不到任何 Fushi 资产，Windows 槽位冻在拆族前的
    `hibiki-1.3.2-debug.10182-windows-setup.exe`，随后被 prune 删掉。

  即：**产品族隔离应当是「按平台资产」而不是「按整份清单」**——Android 要隔离，桌面要放行。
  拆族时按文件一刀切，把 Windows/macOS 的 Hibiki 用户的唯一迁移路径一起切掉了。

- **[x] ①a 已修复（止血：不再广告死链）** — `tool/merge_update_manifest.py`：`merge_manifest` 新增
  `live_asset_names` 参数，**留存**条目与 release 当前实际资产名取交集，已被 prune 的直接丢弃
  （本次上传的 incoming 资产永不参与过滤，避免存活快照早于上传导致自删）。
  `tool/publish_update_manifest.sh` 用 `gh release view --json assets` 取当前资产名喂进去。
  语义上 `None`（取不到）与空集（release 真的没有资产）严格区分：前者**关闭过滤**，
  fail-open —— 让一次 `gh` 抖动删光所有留存资产，比这个 bug 本身严重得多。
  丢掉槽位后客户端表现为「你的平台没有可用版本」，是诚实的落空，好过必 404 的下载。
  提交：`（见本轮提交哈希）`

- **[x] ② 已加自动化测试** —
  - `fushi/test/tools/update_manifest_publish_race_test.dart`：两条端到端守卫，离线驱动**真**
    `publish_update_manifest.sh`（新增 `MANIFEST_LIVE_ASSETS_OVERRIDE` 测试缝，与既有
    `MANIFEST_REMOTE_OVERRIDE` 同范式）。① 复现用户那条形状：desktop 发过一次后停更、
    资产被 prune，Android 继续发 → 清单不得再含那条 exe；② fail-open：存活列表取不到时
    必须放行全部留存资产。这一层在 flutter test 门内。
  - `tool/merge_update_manifest_test.py`：5 条纯函数用例（丢弃已 prune / 保留仍存活 /
    incoming 不被陈旧快照误删 / `None` 关闭过滤 / 空集清空留存）。
  - 变异实测：把过滤条件写死成 `False` 后，Dart 端 ①（`218:5`）当场红；反向替换还原后 12 条全绿。

- **[ ] ①b 未修复（真正恢复迁移路径）** — 让 hibiki 族清单继续收到 Fushi 的**桌面**资产
  （withhold APK，放行 `-windows-setup.exe` / `-macos.zip`），即把产品族隔离从「按整份清单」
  改成「按平台资产」。

  ⚠️ 不能简单地把桌面产物同时写进两份清单：`merge_manifest` 的单调 seq 守卫会把顶层
  metadata 一起抬到 Fushi 的 seq（当前 10405），于是 **Android** 的 hibiki 客户端会读到
  顶层 1.4.0-debug.10405、而唯一能选的 APK 还是桥的 10192 —— 那正是 BUG-1481 修掉的
  跨族错位。所以镜像写入必须是「**只贡献资产、绝不动顶层**」的模式（新增
  `MANIFEST_ASSETS_ONLY` 之类的开关），顶层留给桥自己。

  形态不止一种（只镜像 Windows/macOS？连 seq 一起对齐？给桥单独出 Windows 包？），且一改
  就直接改变在野客户端收到的东西，**待用户拍板后再做**。

- **备注**：**代码修复只堵住「以后不再产生死条目」，救不回已经发出去的清单**——
  `latest-debug.json` 是已发布数据，只有 CI 重发或人工改写才会变。用户当前那台机器仍会
  404，即时恢复手段是手动装 `fushi-1.4.0-debug.10405-windows-setup.exe`（实测 206 可下）；
  在桌面端这本来就等价于「自更新迁移」——安装器覆盖安装，正是 Phase 5 设计的路径。
