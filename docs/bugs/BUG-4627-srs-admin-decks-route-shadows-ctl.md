## BUG-4627 · srs-admin-decks-route-shadows-ctl
- **报告**：2026-11-15（CI：develop e6c4ec1d5fe 起各 PR 的 Build Android APK 里 `packages/fushi_server/test/admin_srs_ctl_test.dart` 两条红——`:222` 期望 409 实得 404、`:414` 期望 75 个牌组实得 0）
- **真实性**：✅ 真 bug（两个各自绿的 PR 合在一起才出现）。#3301 在 `packages/fushi_server/lib/src/admin/admin_srs.dart` 的 `AdminSrs.route` 里新加了 `GET /api/admin/srs/decks?profile=`（WebUI 制卡牌组框的建议，只回全名列表，没点名 / 没提供都回 404）；#3284 带来的 ctl 内容端点 `AdminSrsCtl`（`admin_srs_ctl.dart`，engine `srs_ctl_routes.dart:112`）早已占了同一路径，语义是「没点名且一份可用就是它、几份 409、没提供 404」并回带计数的牌组。`admin_api.dart:148-155` 先问 `srs.route` 再问 `srsCtl.route`，于是新路由把 ctl 端点整个遮住：不点名的请求回 404、`ctl srs` 的牌组读取拿到的是字符串列表。
- **[x] ① 已修复** — 删掉 `AdminSrs` 里重复的 `decks` 路由和 `AdminSrs.deckNames`；WebUI 牌组建议改读 ctl 端点的 `decks[].name`（同为 `父::子` 全名）。一条路径只留一个处理者。
- **[x] ② 已加自动化测试** — 原有的 `admin_srs_ctl_test.dart`（`profile：一份都没有 409…`、`ctl srs 读：牌组/搜索/…`）即回归测试，修复前在 CI 红、修复后绿；`admin_srs_test.dart` 的「牌组建议：没提供的 profile → 404」现在走 ctl 端点仍成立。删掉只测 `AdminSrs.deckNames` 的 `server_srs_mining_test.dart` 用例（函数已删）。
- **备注**：#3284 的 PR CI 在合并前是全绿的，因为当时 develop 还没有 #3301；冲突只在两者都进 develop 后出现。
