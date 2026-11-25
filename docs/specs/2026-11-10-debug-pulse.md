# 调试版流水线（debug pulse）

更新中心「应用新版」域里给 **debug 通道用户** 看：自己装的是哪个调试版、后面出了哪些包、
每个包含哪些 PR、哪些 PR 已合进 develop 但还没进包、自己平台的包正在构建 / 被顶掉 / 失败。
能力来自所有者的本地看板 Fushi Pulse（`D:\FushiPulse`，私有），但计算挪到 CI：
客户端没有 GitHub token，匿名 API 一小时 60 次、国内直连 api.github.com 不通。

## 数据通道

- CI 算好一份 JSON，推到 `update-manifest` 孤儿分支的 `debug-pulse-fushi.json`——和
  `latest-debug-fushi.json` 同一分支、同一条 raw + 镜像通道，国内可达。生成器
  `tool/gen_debug_pulse.py`（单测 `tool/gen_debug_pulse_test.py`，由 `ci-config-gate.yml` 跑），
  生成 + 推送脚本 `tool/publish_debug_pulse.sh`。
- **不占 CI 排队位**：没有独立 workflow、不新增 job / runner、不 `gh workflow run` 派发，只在
  `release.yml` / `release-desktop.yml` 已有的 job 里加步骤，且只在 develop 的 push（= debug 通道）上跑：
  - 开头：`release.yml` 的 `build` job、`release-desktop.yml` 的 `windows` job，checkout 后立刻刷新一次——
    此刻本 run 在构建中、被顶掉的旧 run 已 cancelled、新合的 PR 显示「还没进包」；
  - 收尾：`publish-android` / `publish` job 里紧跟 `publish_update_manifest.sh`（`if: always()`，失败也刷新），
    反映出包结果；`build` job 失败时 `publish-android` 整个被跳过，`build` 末尾另有一步 `failure()` 补刷。
  - 每步 `continue-on-error: true` + `timeout-minutes: 3`，生成 / 推送失败绝不让发布变红。
- 这些 job 都是 `fetch-depth: 0`，seq 与 first-parent 链全用本地 git 算（一次 `rev-list --parents`
  在内存里算出 first-parent 链上每个提交的计数，不逐个 `rev-list --count`）；只有 release 资产、
  发布 run / job 状态、PR 元数据走 API。PR 元数据以分支上一版文件为缓存，只补新 PR。
- 发布 run 内刷新时本 run 自身必然还在跑，所以对「没包」的平台按该 run 的 job（及已结束的 step）
  细化状态：平台 job 或 publish 里已有失败 step → `failed`，仍在跑 → `building`。
- 两条 workflow 会并发写同一文件：推送被拒就重取远端 tip、只重放这一个文件再推，最后一次覆盖
  （每次都是全量重算）；绝不改动分支上的其它文件，不建 release / tag，不碰任何发布通道。

## JSON（schema 1）

```jsonc
{
  "schema": 1,
  "generatedAt": "2026-11-10T08:00:00Z",
  "repo": "hajisensai/Fushi",
  "develop": { "sha": "<40>", "seq": 25050 },
  "builds": [                       // 滚动 release 上仍在的调试版，seq 降序，最多 30 个
    {
      "seq": 25034,
      "version": "3.3.0",
      "sha": "<40>|null",           // 解析不出时 null，此时 prs/direct 为空、unknown=true
      "unknown": false,
      "publishedAt": "ISO",          // 该 seq 资产里最新的 updated_at
      "testflight": true,            // 有 iOS 包且该 seq 的 release-desktop run 里 testflight job 成功（读实际 job 结果，不复刻上传节律；为 true 后经上一份文件缓存）
      "baseSeq": 25010,              // 内容是相对哪个 seq 算的；null = 找不到前一个
      "prs": [3101, 3100],           // first-parent 链上的 PR，新到旧
      "direct": [{ "sha": "<40>", "subject": "..." }],  // 直推 develop 的提交
      "truncated": false,
      "platforms": {                 // 四个键恒在：android / windows / macos / ios
        "android": { "state": "ok" },
        "windows": { "state": "superseded", "url": "<run html_url>" }
      }
    }
  ],
  "pending": {                       // develop 尖端比最新包新时才有，否则 null
    "headSha": "<40>",
    "headSeq": 25048,
    "prs": [3101],
    "direct": [],
    "truncated": false,
    "platforms": { "android": { "state": "building", "url": "..." }, "...": {} }
  },
  "prs": {                           // 上面引用到的每个 PR 一条
    "3101": {
      "number": 3101,
      "title": "feat(server): redesign the admin WebUI",
      "author": "samutw",
      "mergedAt": "ISO|null",
      "additions": 830,
      "deletions": 285,
      "labels": ["server"]
    }
  }
}
```

平台 `state` 值域（生成器算好，客户端不再看 run 列表）：

| state | 含义 |
|---|---|
| `ok` | 滚动 release 上有这个平台的包 |
| `queued` | 对应发布 run 排队 / 等待中 |
| `building` | 对应发布 run 正在跑 |
| `built` | run 成功但包还不在 release 上（上传中 / 被 prune） |
| `failed` | run 失败 / 超时 |
| `superseded` | run 被后来的 push 取消（「被顶掉」） |
| `none` | 没包也没找到 run |

`url` 可选，是对应 run 的 `html_url`。平台↔workflow：`release.yml` → android；
`release-desktop.yml` → windows / macos / ios。

seq ↔ sha：`seq = git rev-list --count <sha> + RELEASE_SEQUENCE_FLOOR`（真值在 `tool/release_sequence.sh`）。
资产名 `fushi-<ver>-debug.<seq>[-<sha7>]-<平台>`。

## 客户端

- 只在更新通道为 debug 时拉取、显示；放在更新中心「应用新版」域列表上方。
- 不放下载按钮：更新走应用内检查更新（已有）。只显示**本机平台**的出包状态。
- 「我装的版本」自动取本机 `currentReleaseSequence`，不让用户选。
- PR 标题去掉 conventional-commit 前缀，按 feat / fix / perf / 其他 分类。
- 不显示正式版 / 预发布网格（「查看更新日志」页已有）。
