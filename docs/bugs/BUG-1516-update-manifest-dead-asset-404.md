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

  根因链：`merge_manifest` 的设计是「跨平台并集 + 每平台保留自己最高 seq 的资产」，好让
  某个平台停更时客户端不至于 `selectUpdateReleaseForCurrentPlatform` 返回 null。但
  rolling release 会**按平台 prune 旧资产**（`release.yml` / `release-desktop.yml`）。两者
  之间没有任何一致性检查，于是一旦某平台长期不发版：清单里那条留存条目指向的文件被删掉，
  而清单还在广告它 —— 客户端唯一的应用内动作就是下载一个必然 404 的地址，且无自愈路径。
  这不是 hibiki 族独有的洞，`latest-debug-fushi.json` 同构，任一平台停更够久都会踩同一条。

- **[x] ① 已修复** — `tool/merge_update_manifest.py`：`merge_manifest` 新增
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

- **备注**：**代码修复只堵住「以后不再产生死条目」，救不回已经发出去的清单**——
  `latest-debug.json` 是已发布数据，只有 CI 重发或人工改写才会变。所以：
  1. 用户当前那台机器仍会 404，唯一即时恢复手段是手动装当前包
     `fushi-1.4.0-debug.10405-windows-setup.exe`（实测 206 可下）。注意它是 `app.fushi.reader`，
     与老包 `app.hibiki.reader` 并存安装，不是原地升级。
  2. **是否要重发 hibiki 族清单把老客户端引到本体安装包，属于对外发布决策，未做**——
     它会直接改变在野客户端的自更新行为，需要用户拍板。
