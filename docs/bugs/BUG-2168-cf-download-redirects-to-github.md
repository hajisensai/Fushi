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
- **[x] ① 已修复** — 止血：手动重跑镜像 run 34004621520，Windows/Android×3/iOS 已进 R2，线上复验 `x-fushi-mirror: r2` + 200。根因：镜像的「资产已就位」判据改接 update-manifest 分支的正式版清单（`latest-stable-fushi.json`，由上传完成的那个 job 写，也是 Worker 判定下载槽位的权威），；清单没指向本 tag、或清单登记的资产在 release 上还找不到，就跳过不镜像。
  **唤醒通道（复审改正）**：第一版靠 `push` 到 update-manifest 分支来「清单写入时再触发一次」，实测那是**死代码**——两条独立原因任一成立就够：① GitHub 对 push 事件是从被推送的那个 ref 读 `.github/workflows/` 决定跑什么，而 update-manifest 是只放 6 个 JSON 的孤儿分支，上面没有 workflow 文件；② 清单是用 `GITHUB_TOKEN` 推的，而 GITHUB_TOKEN 的 push 不级联新 run。实测收口：该分支每天被推几十次，`actions/runs?branch=update-manifest` 的 `total_count` 至今为 **0**。照那一版合入，净效果不是「镜不全就红」而是**自动镜像永久静默停摆且全程绿灯**（每个新正式版都跳过，published 那趟必然早到、而第二趟永远不会来），比现状更隐蔽。改成 `tool/publish_update_manifest.sh` 推完**正式版**清单后显式 `gh workflow run mirror-releases.yml -f assert_complete=true`——workflow_dispatch 是 GITHUB_TOKEN 无级联规则的明文例外，是唯一能自动接上的通道；dispatch 失败会打 `::error`（不阻塞发布，但不静默）。同时 `assert_complete` 让自动唤醒**过就位门**：不区分的话它和人工补救一样绕过门，下游那条完整性断言 `if (fs.existsSync("expected-assets.txt"))` 永远拿不到输入，「镜不全就红」在实际会发生的每一条路径上都不成立。并撤掉 `ref: ${{ github.event.repository.default_branch }}`：它只为服务那条死触发器而加，却让 release 路径签出 main 的 tip 而不是被打 tag 的 commit；develop 领先 main 273 个提交时，从 develop 手动 dispatch 还会因为 main 上没有判据脚本直接 ENOENT 打红。另加陈旧兜底：release published 已超 6 小时而清单仍未登记它的资产，直接 `exit 1` 报 `Mirror readiness stalled`——「本次不镜像」不能是可以静默绿到天荒地老的状态，「三天只镜到 bridge 包却报 success」正是这么躺过来的。判据本体在 `tool/r2_mirror_readiness.mjs`。另加完整性断言：清单登记又没超单文件上限的资产必须全进这批，缺一个就让 job 红，不再产出「成功但没用」的镜像。
- **[x] ② 已加自动化测试** — `tool/r2_mirror_readiness.test.mjs`（5 条，含 v2.2.4 的真实翻车形态：published 早到、清单还停在 v2.2.3 → 判不就位）；`fushi/test/build/r2_mirror_budget_guard_test.dart` 新增一条守卫钉住：那条死的 push 触发器**不得**回来、`assert_complete` 输入在场、清单脚本里有显式 `gh workflow run mirror-releases.yml`、Checkout **不得**钉默认分支、判据脚本调用与完整性断言、以及陈旧兜底在场。变异实测三条：把死触发器加回去 / 把唤醒改成别的 workflow / 去掉陈旧兜底，各自报对应的 reason。
- **备注**：遗留缺口——`fushi-2.2.4-macos.zip`（335 MB）和 debug apk（442 MB）超过 `MAX_ASSET_MB: 300`（wrangler `r2 object put` 单次上传上限），仍只能从 GitHub 下，Worker 会 302 过去。修复后它们至少会在 job summary 和 warning 里显式列出，不再隐身。要真正镜像需要走 S3 兼容 multipart 上传，未做。
  另一处体验问题未修：下载页顶部即使实际被 302 到 GitHub，仍显示「正在使用 Cloudflare 镜像」——用户就是这么发现问题的。属 fushi.moe 仓库 `DownloadPage.vue`。
