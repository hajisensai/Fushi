## BUG-4278 · 明文互联地址未核对 hostId 就带 token 发出（单地址组与竞速失败时）
- **报告**：2026-11-10（用户：互联审查 V-B4）
- **真实性**：✅ 真 bug。
  - `fushi/lib/src/sync/interconnect_peer_addresses.dart:231`（基准 94317ab6295）`_rankGroup`：`if (group.length < 2 || hostId == null) return group;`——单地址组从不 ping 核对。一条明文 http 行标着 hostId A、带着 A 的 token，地址换网后背后是另一台 Fushi host 时，post transport 照样用 Basic 把 A 的 token 发过去。
  - 同文件 `:252-255`：多地址组竞速没有胜者时原样返回整组，消费方逐个试候选，同样把 token 发给没核对过身份的明文地址。
  - 新测试 `interconnect_plaintext_identity_test.dart` 在修复前红：真服务器收到 `Basic aGliaWtpOnNlY3JldA==`；查词 client 返回 null 而不是抛不可达。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：
