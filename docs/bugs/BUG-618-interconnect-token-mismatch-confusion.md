## BUG-618 · 互联访问令牌与桌面端不一致（per-peer token·非 bug 待确认）

- **报告**：2026-07-08（用户：TODO-1330 子问题④「这个访问令牌，和我实际电脑上的访问令牌也不一样啊」）
- **真实性**：❌ 非 bug / 按设计如此（暂无法复现「不一致=坏」；等用户确认对比的是哪两个值）。
  - 桌面端「服务器令牌」显示的是 host 共享令牌 `SyncRepository.getServerPassword()`（key `sync_server_password`，`sync_repository.dart:500`）。
  - client 端令牌输入框显示的是 `getHibikiClientToken()`（key `sync_hibiki_client_token`，`sync_repository.dart:637`）。v2 配对成功后这里存的是 host 按本设备签发的 **per-peer token**（`hibiki_sync_server.dart:734 _issuePeerTokenOrFallback` → `generateToken()`，落 `hibiki_paired_peers` 表），**与共享令牌本就不同**。
  - 二者都能鉴权：server `_validateAuth`（`hibiki_sync_server.dart:361`）常量时间比对共享 `_token` **或**任一未吊销 per-peer token。所以「令牌不一致」是 per-peer 令牌模型的正常现象，不是坏。
  - 用户之所以怀疑令牌，很可能是被 BUG-616 连累：测试连接因 TLS 漏指纹而红，误以为「令牌不对才连不上」。BUG-616 修好后，per-peer token 正常通过测试连接。
- **[ ] ① 无需代码修复** — 属设计行为。若要消除困惑，可选后续 UX（本次未做，避免过度设计）：client 令牌框对已配对设备只读展示「已通过配对自动获取」而非可编辑明文；或桌面端注明「配对设备各自持独立令牌」。需用户确认是否要做。
- **[ ] ② 无需测试** — per-peer token 双向鉴权已有 `hibiki/test/sync/hibiki_sync_server_peer_token_test.dart` 覆盖（仍绿）。
- **备注（需用户提供更多信息才能定性）**：请用户明确对比的是哪两个值——(a) 桌面「服务器令牌」vs 手机令牌框，属预期不同（各设备独立 per-peer token），无需一致；(b) 若用户是手动把桌面令牌粘进手机却仍连不上，则那是 BUG-616（TLS 指纹）导致，修复后共享令牌也能连。目前无证据表明存在「取错 key / 取错 server 凭据」的真 bug。
