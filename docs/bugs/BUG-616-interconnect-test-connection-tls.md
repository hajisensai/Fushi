## BUG-616 · 互联测试连接对已配对 https host 恒失败（漏传钉扎指纹）

- **报告**：2026-07-08（用户：TODO-1330 子问题①「刚绑定的内网 hibiki 互联，点击测试连接还是连接失败」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/sync/hibiki_client_sync_backend.dart:1233`（`testConnection` 构造 `WebDavOps` 时**未传 `pinnedFingerprint`**）+ 调用方 `hibiki/lib/src/sync/sync_settings_schema/interconnect.part.dart` 的 `_testAll`（未把 `u.fingerprintSha256` 传下去）。
  新版 host 首次启用 hosting 默认开 TLS（`sync_repository.dart:493 applyFirstHostingTlsDefault`），刚配对的地址就是 `https://` + 自签证书（指纹经 TOFU 落进 `HibikiClientUrl.fingerprintSha256`）。真正的 sync 走 `_pinnedReachabilityProbe`（同文件:65）用 pinned client 可达；但「测试连接」按钮用裸 `WebDavOps`（无指纹）→ 自签 TLS 握手被拒 → 把**其实能连**的 host 误报「连接失败」。这与 sync 能用但测试连接红的表象完全吻合。
- **[x] ① 已修复** — `testConnection` 增加可选 `String? fingerprint` 参数并传给 `WebDavOps(pinnedFingerprint:)`；`_testAll` 传 `fingerprint: u.fingerprintSha256`。指纹非空 → pinned client（仅接受指纹相等的自签证书），null → 明文 http 老路径不变。见分支 `todo1330-interconnect-pairing`。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/interconnect_test_connection_tls_test.dart`（真实自签 HTTPS server 端到端：带指纹→通、漏指纹→握手失败回归守卫、指纹对 token 错→鉴权失败）+ 源码守卫 `hibiki/test/sync/interconnect_pairing_fixes_guard_test.dart`（`_testAll` 必须传 `fingerprint: u.fingerprintSha256`）。
- **备注**：明文 http 老 host（无指纹）行为零变化。修复后 per-peer token 也能正常通过测试连接（见 BUG-618）。
