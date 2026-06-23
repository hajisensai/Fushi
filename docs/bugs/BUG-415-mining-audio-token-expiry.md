## BUG-415 · 制卡音频静默丢(复用查词缓存的过期token URL)
- **报告**：2026-06-24（用户：）
- **真实性**：✅ 真 bug。远端查词制卡时卡片落空 `[sound:]`，但同一词查词点 ♪ 能正常播放出声。
- **根因**：远端 host 给词音频文件 URL 签一个 **5 分钟过期**的 token
  （`hibiki/lib/src/sync/hibiki_sync_server.dart` `_pruneAudioTokens`，约 :1267-1272）。
  - 查词播放：`assets/popup/popup.js` 点 ♪ → `resolveCachedAudioUrl` → `fetchAudioUrl`
    → host 返 `url=/api/lookup/audio/file?id=<id>`（token 存内存）→ 立即播，token 新鲜成功。
  - 制卡：`buildMinePayload`（`assets/popup/popup.js` 约 :1087-1088）原本也走
    `resolveCachedAudioUrl`，**命中播放缓存后直接返回旧 URL，不重新 fetch**；制卡可能
    发生在播放很久之后 → token 已被 prune → repo `_addRemoteAudio`
    （`packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart:514`，AnkiConnect 同
    `ankiconnect/ankiconnect_repository.dart:793`）裸 `HttpClient` GET 拿到 404 →
    `:542` 静默返 null → 卡片落空 `[sound:]`。
  - 唯一差异 = token 过期 + 制卡复用旧 URL（auth 免、URL 同形、payload.audio 非空均排除）。
- **[x] ① 已修复** —
  - 主修：`assets/popup/popup.js` `buildMinePayload` 制卡取音频路径 **绕过播放缓存**，
    改直接 `await fetchAudioUrl(expression, audioReading)`（重新经 `resolveWordAudio`
    handler 让 host 重签新鲜 token 的 URL），写进 `payload.audio`；fresh 失败才回退缓存值，
    不比原来更差。播放路径（`createAudioButton` / `resolveCachedAudioUrl`）**未动**。
  - 叠加防御：`hibiki/lib/src/sync/hibiki_sync_server.dart` `_handleAudioFile`（约 :432-444）
    成功命中 token 时 `token.createdAt = _now()` 刷新时间戳，重置 5 分钟窗口，使「正在被
    访问」的音频 token 不会在使用途中（播放→制卡之间）被 prune（`_RemoteAudioToken.createdAt`
    由 `final` 改可变）。惠及播放与制卡。
- **[x] ② 已加自动化测试** —
  - 行为级（popup.js，Node 真执行）：`hibiki/test/utils/misc/popup_asset_behavior_test.js`
    新增 `testMiningResolvesFreshAudioEvenWhenCacheHoldsSameWord`——先播放同词（缓存 token #1），
    再制卡，断言制卡发**第二次** `resolveWordAudio`（fresh，token #2），卡片携新 URL。
    撤主修（制卡复用缓存）→ 只 1 次 resolve → 转红（已实测）。
  - 源码守卫（进 CI）：`hibiki/test/pages/popup_mine_audio_fresh_resolve_static_test.dart`——
    静态扫描 popup.js 锁定制卡分支调 `fetchAudioUrl` 且不复用 `resolveCachedAudioUrl`，
    播放分支仍用 `resolveCachedAudioUrl`；并用 Node 跑上面的 harness（无 node 时 skip）。
  - 服务端续期（进 CI）：`hibiki/test/sync/hibiki_sync_server_audio_token_refresh_test.dart`——
    可控时钟时间旅行：t=0 签发 → t=4min 访问（命中续期）→ t=8min 再访问仍 200；
    另一例「从不访问的 token 5min 后仍被 prune（404）」证明续期非永生。撤续期 → 第一例转红（已实测）。
- **备注**：句子音频是另一条独立路（本地 sasayakiAudioPath / 普通 EPUB 无 audioFiles 时本就
  null），未动。worktree `todo-766-mining-audio`。
