## BUG-2636 · 游戏串流侧栏查词不能制卡
- **报告**：2026-09-23（用户：「侧边栏查词不能制卡修复一下」）
- **真实性**：✅ 真 bug（代码路径验真，未在真机复现用户原始会话）。沿「侧栏点词 → `DictionaryPopupLayer` 的 `+` → `GameStreamPage._mine` → `POST /api/game-stream/mine` → 主机 `FushiGameStreamMiningAdapter.mine`」一路查到四处缺陷，任一处都会表现为「点了制卡没成」：
  1. **请求体上限**：`packages/fushi_engine/lib/sync/game_stream/game_stream_service.dart` 的 `_readObject` 对所有串流请求一律 512 KiB 封顶。popup.js 的制卡载荷含每部词典渲染后的 `glossary` HTML、`singleGlossaries`、`glossaryFirst`、`frequenciesHtml`、`dictionaryMedia` 描述（`fushi/assets/popup/popup.js` 组 payload 处），多词典时常规超限 → 400 → 手机只显示「主机制卡失败」。
  2. **字段白名单对错了键**：`fushi/lib/src/sync/game_stream_mining.dart` 旧白名单只认 `term/meaning/definitions/pitch/frequency` 这套从未有人发送的旧名，popup 真实发的 `reading/furiganaPlain/pitchPositions/pitchCategories/frequenciesHtml/freqHarmonicRank/glossaryFirst/singleGlossaries/dictionaryMedia/audio` 全部被丢，卡片缺读音 / 音调 / 频率 / 单词音频 / 外字。
  3. **单词音频引用在主机上不可用**：手机侧 popup 的 `audio` 是手机本地物化文件或主机签发的短命 token URL，主机拿不到。
  4. **没接查重、重复被报成失败**：串流页 `DictionaryPopupLayer` 只传了 `onMineEntry`，没有 `onDuplicateCheck`（按钮永远是「+」）；主机回 `detail:duplicate` 时页面一律 `MineResult.error`；失败原因全部压成 `host_error`，手机上看不出是缺截图、缺语音还是 Anki 不可用。
- **[x] ① 已修复** — 制卡路径读体上限提到 8 MiB（其余控制请求仍 512 KiB）；主机白名单改为 popup.js 实际字段集合 `kGameStreamHostMineFieldKeys`（句子 / 牌组 / noteId / 截图仍只由主机决定，`audio` 仅收 http(s) 与 `data:audio/`）；`fushi_sync_server/game_stream.part.dart` 在进服务前把 token / 手机本地音频引用重解析为主机侧自包含 `data:` URI（复用 `RemoteLookupRoutes.resolveMineWordAudio` 与主机音频源）；串流页接主机 `/api/duplicate` 查重、重复回 `MineResult.duplicate`、失败按 `GameStreamMineDetail` 码本地化文案。提交 `ad4c4bd04cb`。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/game_stream_launch_settings_test.dart`（700 KiB 制卡体被接受并原样送达 onMine）、`fushi/test/sync/game_stream_android_features_test.dart`（popup 全字段放行、句子/牌组/noteId 拒收、手机本地音频路径丢弃、`term` 兼容映射）。
- **备注**：真机端到端（Android 查词 → Windows 主机真卡 + 截图 + 句音）未在本次执行，需按 `docs/specs/2026-09-22-fushi-game-stream.md` 的 LAN 夹具复测。
