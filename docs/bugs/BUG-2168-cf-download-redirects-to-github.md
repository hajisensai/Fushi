## BUG-2168 · 下载页选 Cloudflare 镜像却被 302 到 GitHub
- **报告**：2026-09-06（用户：选 CF 下载，fushi.moe 直接转成 GitHub）
- **真实性**：✅ 真 bug，线上实测复现。`https://fushi.moe/releases/latest/windows` 返回 `302` + `x-fushi-mirror: github`，`?src=r2` 返回 `404 not mirrored` —— **R2 桶里根本没有 v2.2.4 的本体安装包**。Worker 行为本身正确（`edge/src/downloads.ts` `serveAsset()`：R2 未命中就回源 GitHub），错的是镜像流程从没把这批包放进去。
  根因在 `.github/workflows/mirror-releases.yml` 的触发时机：`on: release: published` 只表示 release 条目建好了，跟资产传没传完无关。v2.2.4 的实测时间线——
  | 时刻 | 事件 |
  |---|---|
  | 13:14:41 | release published，镜像 run 33759979845 启动 |
  | 12:12–12:56 | 此时 release 上只有 3 个 `bridge-2.1.1-*.apk` |
  | 13:44:05 | Android 本体包才上传 |
  | 14:52:45 | Windows / macOS / iOS 包才上传 |
  镜像于是把 3 个无关的 bridge apk 当成全集传进 R2，并且**报 success**（旧逻辑只要求「有 ≥1 个限额内资产」），没有任何告警。fushi.moe 的「Cloudflare 镜像」因此从 9-03 起整整三天都在 302 去 GitHub，直到用户报上来。
- **[x] ① 已修复** — 止血：手动重跑镜像 run 34004621520，Windows/Android×3/iOS 已进 R2，线上复验 `x-fushi-mirror: r2` + 200。根因：镜像的「资产已就位」判据改接 update-manifest 分支的正式版清单（`latest-stable-fushi.json`，由上传完成的那个 job 写，也是 Worker 判定下载槽位的权威），并新增 `push: branches:[update-manifest] paths:[latest-stable-fushi.json]` 触发；清单没指向本 tag、或清单登记的资产在 release 上还找不到，就跳过不镜像。判据本体在 `tool/r2_mirror_readiness.mjs`。另加完整性断言：清单登记又没超单文件上限的资产必须全进这批，缺一个就让 job 红，不再产出「成功但没用」的镜像。
- **[x] ② 已加自动化测试** — `tool/r2_mirror_readiness.test.mjs`（5 条，含 v2.2.4 的真实翻车形态：published 早到、清单还停在 v2.2.3 → 判不就位）；`fushi/test/build/r2_mirror_budget_guard_test.dart` 新增一条守卫钉住触发器、默认分支 checkout、判据脚本调用与完整性断言（已做变异实测：删掉断言文案守卫即红）。
- **备注**：遗留缺口——`fushi-2.2.4-macos.zip`（335 MB）和 debug apk（442 MB）超过 `MAX_ASSET_MB: 300`（wrangler `r2 object put` 单次上传上限），仍只能从 GitHub 下，Worker 会 302 过去。修复后它们至少会在 job summary 和 warning 里显式列出，不再隐身。要真正镜像需要走 S3 兼容 multipart 上传，未做。
  另一处体验问题未修：下载页顶部即使实际被 302 到 GitHub，仍显示「正在使用 Cloudflare 镜像」——用户就是这么发现问题的。属 fushi.moe 仓库 `DownloadPage.vue`。
