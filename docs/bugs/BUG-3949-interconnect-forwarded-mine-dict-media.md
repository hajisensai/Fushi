## BUG-3949 · 经互联主机制卡，词典插图变空框
- **报告**：2026-11-01（用户：应用内反馈 PDgaHL5qmj）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/sync/forwarded_mine_materialize.dart:62` `_materializeDictionaryMedia` 只落客户端带来的字节；客户端（`fushi/lib/src/anki/forwarded_mine_codec.dart:46`）只能从本机词典取字节，查的是主机词典时取不到 → 主机写卡时缓存未命中，`packages/fushi_anki/lib/src/anki_note_composer.dart:651` `degradeUnresolvedDictionaryMedia` 把 `<img>` 换成空 alt、摘掉链接。`/api/mine` 路由会先 `writeDictionaryMediaCache`，`/api/mine/forward` 漏了这步。
- **[x] ① 已修复** — f2de14b6e9（主机按词典名 + 相对路径从自己的词典补齐缓存）；顺带 ac0c821e4a（视频遥控清洗丢 filename 导致字段被空串 replaceAll 打乱）
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/forwarded_mine_materialize_test.dart`、`fushi/test/media/video/video_remote_binding_support_test.dart`
- **备注**：制卡主机与查词主机不是同一台时仍补不上；未真机复测。
