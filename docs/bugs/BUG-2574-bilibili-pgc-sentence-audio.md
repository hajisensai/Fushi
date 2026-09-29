## BUG-2574 · B 站浏览器制卡丢失句子音频（番剧主世界取流 + CDN 防盗链 Referer）
- **报告**：2026-09-16（用户：浏览器扩展制卡时 B 站番剧页（`https://www.bilibili.com/bangumi/play/ep815751`）
  出的卡有封面、有例句，`SentenceAudio` 恒为空，且不报错不提示）；2026-09-17 追报（**普通稿件**也失败，
  日志 `Anki.mineImmersion.bilibili` → `required audio missing (ffmpeg exit -858797304; …
  stderr=Error opening input files: Server returned 403 Forbidden (access denied))`。同一分钟里那条
  `ffmpeg launch failed: The system cannot find the file specified` 是 debug 构建没拷 ffmpeg 的独立问题，
  不是本条的故障点）。
- **汇总说明**：本条原为两条独立立案 —— **BUG-2574**（B 站番剧（大会员）浏览器制卡没有句子音频）与
  **BUG-2575**（B 站制卡句子音频被 CDN 403：ffmpeg 没带防盗链 Referer）。两者是**同一条链上的两处
  独立故障点**（「番剧根本没去裁」与「去裁了但 CDN 拒了」），2026-09-17 按用户要求汇总成**一个 BUG 单**：
  `docs/bugs/BUG-2575-*.md` 已并入本文件、索引收成一条，代码与测试里的 `BUG-2575` 引用同步改为
  `BUG-2574`。
- **真实性**：✅ 真 bug（沿真实代码路径定位到两处根因，非复现实验）
  - **故障点① 番剧根本没有可裁源 → 静默出「无句子音频」的卡**
    - **根因 A（静默失败，即用户这一例）**：`tools/browser-extension/subtitle-providers.js:94`
      `fushiBilibiliRef()` 只匹配 `/\/video\/(BV[0-9A-Za-z]{10})/`。番剧页是 `/bangumi/play/ep…`，
      没有 bvid → 返回 null → `fushiClipSource()` 返回 null → `bridge-shim.js:70` 只在
      `mode === 'immediate'` 时带 `clipSourceKind`，于是 mine 消息里压根没有这个字段 →
      `app_model.dart` 的 bilibili 段整个不进，落到通用兜底
      （`audioExpected = payload.clipBytes != null` = false）→ **卡照常创建，无音频、不报错、不提示**。
      `tools/browser-extension/clip-source.test.js:81` 还把「番剧返回 null」当成正确行为写成了断言
      ——是设计缺口，不是回归。
    - **根因 B（同类，但是报错路径）**：`fushi/lib/src/mining/bilibili_clip_miner.dart:250`
      匿名 GET `x/player/playurl`，不带 SESSDATA / buvid3、不做 wbi 签名 → 需要登录的稿件
      `code ≠ 0` 或 `dash.audio` 为空 → `StateError` →「bilibili 视频流解析失败，未制卡」。
      按用户要求本次**只改番剧**：普通稿件（含大会员专享稿件）保持原路径一行不动。
    - **三条实测事实（决定方案选型，2026-09-16 对本机网络实跑）**：
      1. `api.bilibili.com/x/player/playurl` 响应 `Access-Control-Allow-Origin: https://www.bilibili.com`
         + `Access-Control-Allow-Credentials: true` —— 只放行**页面自己的源**。故服务端（无 Origin）
         与扩展 SW（`chrome-extension` 源）都读不到响应体，只有页面主世界能取。
      2. 番剧页 `https://www.bilibili.com/bangumi/play/ep815751` 的 CSP 响应头为空 →
         `chrome.scripting.executeScript({ world: 'MAIN' })` 注入不会被拦（因此不必新增
         manifest 声明的 bridge 文件，也就不用同步 assets 镜像的新文件）。
      3. `pgc/player/web/playurl?ep_id=815751&fnval=4048&fourk=1` 匿名即 `code:0`，
         顶层键是 **`result`**（稿件是 `data`），`result.dash.audio[]` 3 条（`30280` 带宽最高）。
  - **故障点② 去裁了但 B 站 CDN 403 —— ffmpeg 没带防盗链 Referer**
    - **根因**：`packages/fushi_engine/lib/utils/misc/desktop_audio_clipper.dart` 的
      `buildFfmpegRemoteInputArgs()` 只下发 `-user_agent` / `-reconnect` 系列，**从不发 `Referer`**。
      B 站的 DASH 直链是防盗链的：ffmpeg 打开 `https://<bili-cdn>/….m4s?…` 时不带 Referer，
      CDN 直接回 403，ffmpeg 连输入都打不开 → `_resolveAudioPath` 拿不到音频 →
      `requireAudio: true` 成立 → 整张卡失败，而用户只看到一句「制卡失败」。
    - **实测（2026-09-17 对本机网络实跑）**：
      1. 番剧 `ep_id=815751` 的音轨 `https://cn-hbyc-ct-01-02.bilivideo.com/upgcxcode/…30280.m4s`：
         curl 不带 Referer → **403**；带 `-e https://www.bilibili.com/` → **206**。
      2. 用仓库自带的 `third_party/ffmpeg-min/windows/ffmpeg.exe` 端到端复现并验证：
         不带 → `Error opening input files: Server returned 403 Forbidden (access denied)`
         （与用户日志逐字一致）；带 `-referer https://www.bilibili.com/` → 裁出
         25369 字节 / `duration=3.017604` 的 aac（ffprobe 验过）。
      3. **别被宽松节点骗**：稿件 `BV1GJ411x7h7` 的直链落在 `*.mcdn.bilivideo.cn:8082`，
         裸 GET 也 206。那是「部分节点宽松」，不是「B 站不需要 Referer」——同一接口
         重新解析一次就可能落到严格节点上（实测正是两种 host 都出现过）。
    - 顺带查清两个干扰项（都不是根因，但会误导诊断）：
      · `AppData\Local\Fushi\ffmpeg.exe` 与 `third_party/ffmpeg-min/windows/ffmpeg.exe`
        **md5 相同**，是同一个 n7.1.5 构建，网络协议是编进去的（`--enable-protocol=…https,tls`）。
      · 该二进制在**进程带 `http_proxy` 环境变量**时对 https 输入报 `Protocol not found`
        （http 正常）；清掉代理即正常。用户侧日志是 403 而非该错误，说明其进程没有走这条路
        ——但排查同类「Protocol not found」时值得先查代理。
- **[x] ① 已修复** — 两处故障点各自修根因，随本笔汇总提交落地（develop 顶端 2026-09-17；原两笔
  `82794dc7a`（番剧主世界取流）/ `4756acb6c`（CDN Referer）已按「同一故障链汇总成一单」压成一笔）
  - **子A 番剧**：新建 `bilibili-pgc` 这条可裁源，音轨由**扩展在页面主世界里解析**后回传响应体，
    服务端只挑流，凭据不出浏览器。
    - `subtitle-providers.js`：`fushiBilibiliRef()` 认 `/bangumi/play/ep(\d+)` →
      `{ kind: 'bilibili-pgc', id: epId }`；稿件页路径与 `part` 语义一字未改。
    - `background.js`：新增 `fushiResolveBilibiliPgcPlayurl()`（`executeScript` + `world:'MAIN'` +
      `credentials:'include'`，8s 超时），mine 分支把它挂在 `clipSourcePlayurlBody` 上转发；
      **解析不到就连 `clipSourceKind` 一起不发** —— 服务端落到通用兜底，与改动前番剧页行为逐字一致。
    - `immersion_mine_payload.dart`：新增 `clipSourcePlayurlBody`（可选，老扩展不发即 null）。
    - `bilibili_clip_miner.dart`：`parseBilibiliPgcPlayurlResponse()`（`result`/`data` 两个键都认，
      挑流逻辑与稿件共用 `_playStreamsFrom`）+ `buildPgcRequest()`（只挑流，一行网络请求都不发）。
    - `app_model.dart`：番剧与稿件**合并进同一段**（`isBilibiliPgc`），只分音轨来路——
      拆成两段会把 `requireAudio` / 零窗前置门 / `web_shot.jpg` 这些不变式各抄一份然后走偏。
  - **子B 防盗链 Referer**：`buildFfmpegRemoteInputArgs()` 增发 `-referer`（仅 B 站 host）
    - 新增纯函数 `isBilibiliCdnHost()`（host 后缀认 `bilivideo.com` / `bilivideo.cn` /
      `acgvideo.com` / `hdslb.com`，外加 `upos-*.akamaized.net`——Akamai 是共享域名，
      只认 B 站那条前缀，免得给别人的 Akamai 地址也挂 B 站 Referer）
      与 `ffmpegRefererForRemoteInput()`（非远端 / 非 B 站 / 畸形 URL → null）；
      常量 `kBilibiliCdnReferer = 'https://www.bilibili.com/'`。
    - `-referer` 与 `-user_agent` 一样放在 `-i` 之前（http(s) 协议的**输入选项**，
      放后面不生效），且在 `-tls_pin_sha256` 之后、`-reconnect` 之前。
    - **判据落在 URL 的宿主上，不在调用方上**：防盗链是「谁家 CDN」的属性，按 host 判定后
      任何入口（制卡句子音频、抽帧、导出）拿到 B 站直链都自动带上，不必给
      `ImmersionMiningRequest` 加一个只有一处会填的字段，也不必每个调用点记得传。
      非 B 站流（googlevideo 等）参数与改动前逐字一致。
- **[x] ② 已加自动化测试**
  - **子A** —
    - `tools/browser-extension/clip-source.test.js`：番剧页现断言为 `bilibili-pgc` 档且**不带 part**；
      新增「`ss` 季页仍返回 null」「稿件页仍带数字 part」两条防回归（node，32/32 绿）。
    - `fushi/test/mining/bilibili_clip_miner_test.dart`：新增 `parseBilibiliPgcPlayurlResponse`
      3 例（顶层键 `result` 取最高码率 / `data` 兼容 / 非 0 code·空 audio·畸形 JSON 一律 null）
      + `buildPgcRequest` 3 例（**不打网络**：注入的 `fetchJson` 直接抛，证明音轨来自回传体；
      无可裁音轨即抛；标题缺失为 null）。
    - `fushi/test/sync/immersion_mine_payload_test.dart`：`clipSourcePlayurlBody` 解析与缺省 2 例。
    - `fushi/test/mining/remote_mining_bilibili_branch_guard_test.dart`：新增「番剧必须与稿件同走
      这一段」守卫（钉 `isBilibiliPgc` + `buildPgcRequest`，防被拆成独立分支或退回匿名 playurl）。
    - `fushi/test/mining/immersion_capture_video_test.dart`：该守卫用
      `if (payload.clipSourceKind == 'bilibili'` 切段，条件改写后锚点失效，改为按判据本身定位
      （写法会变、判据不会变）。
  - **子B** — `fushi/test/utils/desktop_audio_clipper_url_input_test.dart` 新增
    `buildFfmpegRemoteInputArgs 防盗链 Referer` 组：
    - 5 个 B 站 host（含 :8082 端口、老 `acgvideo.com`、`upos-*.akamaized.net`）都带
      `-referer` 且值等于 `kBilibiliCdnReferer`；
    - googlevideo / 普通 CDN 不带 `-referer`；本地路径仍为空表（零网络开关）；
    - `isBilibiliCdnHost`：大小写不敏感、`notbilivideo.com`（后缀必须过点）与
      `someone.akamaized.net`（共享 CDN 非 upos- 前缀）判 false、空串 false；
    - 畸形 URL 不抛异常也不带 referer；
    - `buildFfmpegClipArgs` 的 `-referer` 下标小于 `-i`（钉住「必须在输入选项里」）。
- **备注**：
  - **两处故障点的暴露顺序**：子A 落地后才暴露子B（之前番剧走不到裁剪）；普通稿件是否命中子B
    取决于解析落到哪个 CDN 节点。本次汇总正因两者是同一条链上的两处故障点。
  - **未做真机验证**：番剧页需要登录态 + 大会员，本机只能在未登录下验接口形状。服务端解析与
    请求组装已离线单测覆盖；浏览器侧 `executeScript(MAIN)` 这条注入路径本身没有可离线断言的缝
    （要真页面），故只做到「解析失败即回落」的容错。子B 已实测到「接口形状 + ffmpeg 端到端
    （真实 CDN、真实 403→206 反转）」，但**未**在 app 内点一次制卡（同样缺登录态 + 大会员）。
  - **失败时的行为是刻意保持不变的**：番剧解析不到 → 连 kind 都不发 → 照常出「解码帧 + 例句」的卡、
    没有句子音频、不报错。这是用户在 grilling 轮次里对 Q4 的明确选择（保持现状、最小化改动），
    不是遗漏；若将来要改成显式提示，应作为独立条目。
  - **已知未覆盖**：`/bangumi/play/ss<id>` 季页 URL 里没有 ep_id（当前集只存在于页面内部变量，
    隔离世界读不到）→ 仍返回 null，维持现状。
  - 大会员专享的**普通稿件**（`/video/BV…`）本次按用户要求不动，仍会走根因 B 那条报错路径，
    需要时另开一条。
  - 若将来 B 站换成需要其它头（例如带 `SESSDATA` 的 cookie）才放行，子B 的位置
    （`ffmpegRefererForRemoteInput`）就是加 `-headers` 的地方；目前实测不需要。
