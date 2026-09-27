## BUG-2730 · B 站网页制卡 PCDN 节点 403：按 host 推 Referer 追不上域名轮换
- **报告**：2026-09-27（用户：浏览器扩展在 B 站《关于我转生变成史莱姆这档事 第四季》第 18 话制卡失败，
  `required audio missing`；预检显示 Fushi 取的音轨 `…-1-30280.m4s` 在 `upos-sz-*` 节点上无 Referer 403、
  带 Referer 206）。
- **真实性**：✅ 真 bug（本机网络实测 + 仓库 ffmpeg 端到端复现）
  - BUG-2574 已给 ffmpeg 加 `-referer`，但判据是 **URL 宿主白名单**
    （`packages/fushi_engine/lib/utils/misc/desktop_audio_clipper.dart:56` `isBilibiliCdnHost`：
    `bilivideo.com` / `bilivideo.cn` / `acgvideo.com` / `hdslb.com` / `upos-*.akamaized.net`）。
  - 2026-09-27 对 `BV1GJ411x7h7` 连解析三次 playurl，音轨主链接落在三类节点：`*.mcdn.bilivideo.cn:8082`、
    `upos-sz-*.bilivideo.com`、以及 **PCDN `b-<id>.edge.mountaintoys.cn:4483`**。逐个 curl：
    除 mcdn 外全部「无 Referer 403 / 带 Referer 206」；PCDN 域名不在白名单 → ffmpeg 不带 Referer。
  - 端到端：`third_party/ffmpeg-min/windows/ffmpeg.exe` 以 Fushi 的 UA 裁该 PCDN 链接，
    不带 `-referer` → `Server returned 403 Forbidden (access denied)`（与用户日志逐字一致）；
    带上 → 退出 0、49672 字节。
  - 根因：B 站制卡链路（`fushi/lib/src/models/app_model.dart` bilibili 段）明知来源是 B 站，却不声明
    防盗链头，把「要不要 Referer」交给 ffmpeg 一侧按 host 猜；PCDN 域名会轮换，白名单结构上追不全。
  - 截图里「固定选最高码率 30280」不是故障点：带上 Referer 后所有节点（含 upos）都 206，无需换档。
- **[x] ① 已修复** — 流解析层显式声明防盗链头，随请求下发：
  - `fushi/lib/src/mining/bilibili_clip_miner.dart:196` 新增 `kBilibiliMediaHttpHeaders`
    （`Referer: https://www.bilibili.com/`，复用引擎常量 `kBilibiliCdnReferer`），
    `BilibiliClipRequest.httpHeaders` 默认即它，稿件与番剧两条构造都带；更正类注释里已被实测推翻的
    「不需要 Referer」。
  - `fushi/lib/src/models/app_model.dart:9428` `mediaSourceHttpHeaders: bi.httpHeaders`，走 BUG-2625 的
    请求头通道（调用方 Referer 优先于 host 推断）。
  - 白名单补 `mountaintoys.cn`，仅作其他入口的兜底。
- **[x] ② 已加自动化测试** —
  - `fushi/test/mining/bilibili_clip_miner_test.dart`：两条构造都带 Referer；用白名单外的假 PCDN 域名走
    `buildFfmpegRemoteInputArgs`，断言仍出 `-referer`（证明不再依赖 host 猜测）。
  - `fushi/test/mining/remote_mining_bilibili_branch_guard_test.dart`：bilibili 段必须下发
    `mediaSourceHttpHeaders: bi.httpHeaders`。
  - `fushi/test/utils/desktop_audio_clipper_url_input_test.dart`：`isBilibiliCdnHost` 认 mountaintoys。
- **备注**：未在真 app + 浏览器扩展里重跑用户那一集（番剧 PGC 需登录态）；修复点在 ffmpeg 参数层，
  已用同一 ffmpeg 二进制对真实 PCDN / upos 链接端到端验证。
