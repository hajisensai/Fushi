# 复习远程刷卡（互联客户端在 host 的复习上刷卡）

日期：2026-11-01　状态：已实现（v1）

## 1. 目标

已配对的互联客户端（典型：手机连电脑）**不下载卡组**，直接在 host 的复习（Fushi SRS）上刷卡：
排队、FSRS / RWKV 排程、模板渲染全在 host 的 Rust 内核与 `SrsDbStore` 里做，客户端只显示 host 推来的卡面、
把「评分 + 用时」交回去。每张卡跨网络一个来回，媒体按需拉。

它是**附加模式**，不替代复习同步 v2（`2026-10-25-srs-sync-v2-design.md`）：

| | 完整同步（v2） | 远程刷卡（本文） |
|---|---|---|
| 客户端存什么 | 完整操作日志 + 全部媒体 | 只缓存看过的卡的媒体 |
| host 不在线 | 照常离线刷，回头再合 | 刷不了（明确报错，不吞答案） |
| 适合 | 主力设备 | 空间小的手机、临时设备 |

评分落在 host 的操作日志里，之后照常经 v2 同步到其它设备（含这台客户端，如果它也开着同步）。

## 2. 协议

全部挂在互联 host（`FushiSyncServer`）上，鉴权与其它互联端点相同（配对 token，HTTPS 时按配对指纹钉证书）。
host 在 `GET /api/capabilities` 声明 `srsRemoteReviewV1: true`；复习模块关着时不声明、端点 404。

| 端点 | 体 | 回包 |
|---|---|---|
| `POST /api/srs/review/decks` | `{}` | `{profile, decks: [{id, name, depth, new, learn, review}]}` |
| `POST /api/srs/review/next` | `{profile, deck, exclude: [cardId]}` | `{profile, counts, cards: [卡, 卡?]}` |
| `POST /api/srs/review/answer` | `{profile, request, deck, card, base, rating, durationMs}` | `{profile, logId, counts, cards: [...]}` |
| `POST /api/srs/review/undo` | `{profile, card, log}` | `{profile, ok, card?}` |
| `GET /api/srs/review/media/<名字>` | — | 媒体字节 |

**卡**：`{id, base, question, answer, css, isEmpty, fields, definitions, fushiCard, deckName, plan: [4 个排程结果], nowMs, today, rwkv}`。
`cards` 一次给「下一张 + 再下一张」（`SrsStudyState.next` / `after`），第二张就是客户端的预取。

### 2.1 正确性要点

1. **幂等**：`answer.request` 由客户端生成（每次作答一个，重发不变）。host 按它缓存最近 256 次作答的回包，
   重发直接回原回包，不再写第二条复习日志。缓存在内存：host 进程在「写完日志、回包丢了」与「客户端重发」之间
   重启才会漏掉，此时客户端拿到的是下一条的 `stale`（见 2），不会重复记账。
2. **陈旧卡**：卡带 `base` = 出卡时该卡的 `lastLogId`。作答时 host 现读卡片缓存行比对，不一致（别的设备 /
   host 自己刚复习过这张、卡被删 / 挂起）回 `409 {error: "stale"}`，客户端丢掉这张、重新取下一张。
3. **配置切换**：每个回包带 host 当前 profile uid，请求带客户端上次看到的。host 期间切换了 profile → `409
   {error: "profile_changed"}`，客户端回到牌组列表，不把答案记进另一份配置。
4. **作答时刻**：排程与日志都用 host 收到作答的时刻（与本机复习「在评分这一刻重算」同一口径，见
   `SrsDbStore.answerAndStudy`）；局域网 / 隧道的往返是毫秒到几百毫秒，对学习步无影响。`durationMs` 用客户端
   计的值，两端都截到 `kSrsMaxAnswerDurationMs`。
5. **撤销**：只撤本会话自己记下的日志（`SrsDbStore.undo`），它已不是该卡最后一条有效日志时回 `ok: false`，
   与本机复习页的撤销同一语义。
6. **间隔文案**：host 只给排程结果（`plan`）与 `nowMs` / `today`，单位文案由客户端按自己的界面语言出。

### 2.2 媒体

卡面引用的媒体名是内容哈希（`SrsMediaStore.contentName`），同名即同内容、永不变，所以客户端缓存按名字存即可：
`<临时目录>/srs_remote_media/<hostId>/`。客户端在显示卡之前把这张卡（与预取那张）引用的媒体拉进缓存，
卡面仍经原来的 `SrsMediaStore` 读本地文件（远程页把 `srsMediaStoreProvider` 覆盖成缓存目录），
卡面渲染、`[sound:]` 播放、图片拦截一行不改。漏拉的（卡面脚本动态引用）在 `load` 时按需补拉。

## 3. 分层

- `packages/fushi_engine/lib/srs/srs_remote_review.dart`：`SrsRemoteReviewService`（纯 Dart，读 `SrsDbStore`，
  无头服务端也能挂）——出卡、作答、撤销、幂等缓存、陈旧判定、卡的线格式。
- `FushiSyncServer`：路由 + 能力声明，按请求经 `srsRemoteReviewProvider` 现取服务（模块开关即时生效）。
- `fushi/lib/src/sync/interconnect_host_client.dart`：从视频遥控客户端抽出的「绑定一台已配对 host」传输
  （候选地址、凭据、证书钉扎、明文降级拒绝）；视频遥控与远程刷卡共用。
- `fushi/lib/src/srs/srs_remote_review_client.dart`：客户端协议 + 媒体缓存。
- `fushi/lib/src/pages/implementations/srs/srs_remote_review_page.dart`：选电脑 → 选牌组 → 刷卡。

不新增 FFI：host 侧每次作答仍是 `SrsDbStore.answerAndStudy` 的一次 `apply` 命令（排队同一次完成）。

## 4. v1 不做

卡面查词、复习中编辑笔记 / AI 字段、卡面缩放、手势自定义、自定义学习、按 RWKV 的「等待打分」态
（host 那边 RWKV 未就绪时 `cards` 为空、`counts` 照给，客户端显示「暂时没有卡」）。入口在牌组列表「⋯」。
