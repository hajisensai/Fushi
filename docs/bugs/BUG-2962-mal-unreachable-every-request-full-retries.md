## BUG-2962 · Jikan停摆时每条MAL请求都吃满3次超时，整套下载核对卡一两个小时
- **报告**：2026-10-06（本机用 fushi_server 的 AI 下视频试「一口气下载全部哆啦A梦剧场版」：api.jikan.moe 直连 / 代理都无应答，会话在「正在找系列」停了 30 分钟以上不出结果）
- **真实性**：✅ 真 bug。`MalVideoMetadataRequestGate`（`packages/fushi_engine/lib/media/video/metadata/mal_video_metadata_provider.dart`）是全进程共用的串行闸门，超时 / 连接失败按「瞬时故障」每条请求首发 + 2 次重试（transport 15 s 超时 + 2 s / 4 s 退避），实测一条 `anime/38530/full` 约 2.5 分钟才失败。上游整个不可达时闸门对此没有任何状态，下一条请求照样从头吃满三次超时；整套下载联网补全要逐部回资料源核对几十部作品（发现搜索 `Future.wait` 等所有来源，MAL 那一路必等），于是一两个小时，且全局队列里其它 MAL 请求一起被堵。
- **[x] ① 已修复** — 闸门新增「上游不可达」状态 `unreachableCooldown`（默认 2 分钟）：一条请求重试用尽仍是无状态码的网络失败（超时 / 连接层）即标记不可达，冷却内新请求不碰网络立即以同类 `VideoMetadataNetworkException` 失败（缓存命中照常），到期或任一请求成功即恢复。5xx 有应答、不算不可达。与既有 429 全局冷却同构，不是加延时 / 吞错。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/mal_video_metadata_provider_test.dart` 两条 BUG-2962（重试用尽后冷却内不再发请求、期满恢复；5xx 不触发）。
- **备注**：Jikan 本身停摆是外部问题；本修复只让「停摆」的代价从每条 2.5 分钟降到一次。
