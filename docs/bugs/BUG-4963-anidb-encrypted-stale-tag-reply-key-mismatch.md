## BUG-4963 · AniDB 加密会话里迟到的旧 tag 回包被误判成 Key 不一致，哈希识别整轮停用
- **报告**：2026-11-21（用户：拍板台 pr3541 审查发现，PR #3541 已合入 develop）
- **真实性**：✅ 真 bug。`AnidbDatagramTransport._onEvent`（`packages/fushi_engine/lib/media/video/metadata/anidb_udp_file_client.dart`，修前 1113-1127）在 ENCRYPT 会话里收到用正确 Key 加密、但 tag 不是当前请求的迟到回包（前一个 FILE 两次超时后服务端才回）时，解密成功却因 `!_answers(text)` 把同一份密文再按明文 `utf8.decode`；密文几乎不可能是合法 UTF-8，`text` 被覆盖成 null，落进「Key 不一致」分支抛 `AnidbUdpFailure.encryption`，客户端从此终止，哈希识别整轮停用。
- **[x] ① 已修复** — 新增 `_readDatagram`（同文件 1133 起）：会话密钥能解开就只认解密结果，不再按明文重读；解不开才按明文认（服务端解密前出错的 6xx / 会话被踢仍回明文）。两种都认不出才判 Key 不一致；认得出但 tag 不对的迟到回包直接丢弃接着等（1122）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/anidb_udp_file_client_test.dart`「a late reply to an earlier tag under the right key is skipped, not mistaken for a key mismatch (pr3541)」：真实 loopback UDP，服务端每次先回一个同 Key 加密的旧 tag 回包再回当前回包，连续两次 exchange 都拿到当前回包。修前该用例红（抛 `AnidbUdpException(encryption)`），修后绿。
- **备注**：Key 真不一致的快速失败仍由「undecryptable AniDB reply under a cipher fails fast as encryption」覆盖。
