## BUG-4962 · 关掉 host 的「用这台服务器查词典」后，游戏串流 / 视频遥控查词恒无结果
- **报告**：2026-11-16（用户：核查服务器词典与游戏是否配合时发现）
- **真实性**：✅ 真 bug（#3147 引入的回归）。`FushiRemoteLookupClient._postLookup`（`fushi/lib/src/sync/fushi_remote_lookup_client.dart` 的 `candidateFilter`）对所有词典端点都按 `FushiClientUrl.lookupEnabled` 与可达性跳过筛候选，包括绑定会话的客户端：游戏串流 `InterconnectGameStreamDictionaryLookup`（`fushi/lib/src/sync/game_stream_client.dart`，`onlyCandidate: peer`）与视频遥控 `video_remote_page.dart` 的 `_createLookup`。被筛空后传输层按「未配对 / 未启用」返回无结果，一次请求都不发，界面上点词无反应。这两道筛是「从已配对 host 里挑词典来源」的语义，绑定会话没有来源可挑，被查的内容就在那台 host 上播放，必须由它回答。复现：探针测试中开关开 = 1 次请求有结果，开关关 = 0 次请求无结果。
- **[x] ① 已修复** — `_postLookup` 只在未绑定 host（`_onlyCandidate == null`）时套用 `lookupEnabled` 与可达性跳过筛选；普通查词的来源选择不变。
- **[x] ② 已加自动化测试** — `fushi/test/sync/bound_session_lookup_switch_test.dart`：串流 / 遥控在开关关时仍各发 1 次请求并拿到结果；普通查词对关了开关的 host 仍 0 次请求。
- **备注**：未在真机上跑完整的游戏串流会话（需要 Windows 主机采集游戏 + 接收端）；测试走的是真实查词客户端与真实传输层候选筛选。同一调查发现的「串流 / 遥控不带接收端配置的词典选择」是产品取舍，另交拍板，不在本修复内。
