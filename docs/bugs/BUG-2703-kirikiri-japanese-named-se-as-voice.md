## BUG-2703 · KiriKiri 日文命名的 SE 被当作语音候选配对（喫茶ステラ）
- **报告**：2026-09-26（排查 BUG-2702 时在同一真机会话观察到）
- **真实性**：✅ 现象真（消费端判据已沿代码核实），⚠️ 对真卡的影响未在 E2E 中取证。原版 `CafeStella.exe` 序章中 `%TEMP%\fushi_gal_voice` 除角色语音外还落了 `カーテン／開ける３.ogg`、`■きらきらした感じ２.ogg`、`【システム】決定３.ogg`、`【システム】カーソル１.ogg`（均为合法 Ogg）。native 侧是有意放宽（`hook/adapters/kirikiri_adapter.inc` `IsVoiceStorageName` 注释、BUG-2115「SE/BGM 收敛交给下游」），而消费端只有两道按名字的过滤：扩展名（`.opus` 等被排除）与 `isGalNonVoiceBasename`（`fushi/lib/src/mining/gal_voice_dump_index.dart` 的 `^(bgm|se|sys|amb|env|title|logo|movie|jingle)` 英文前缀）。日文 / 符号开头的 SE 名全部通过，worker 还会给台词前 1.5 s 内打开的 SE 打上该句 textseq（`hook/voice_resource_pairing.h` `ResolveFollowingSelectedText`），于是该 SE 可能与角色语音一起被拼进卡片。
- **[ ] ① 未修复** — 不做按文件名 / 标题的特判（违反「只做引擎级适配」）。候选的引擎级信号待取证后再选：KAG 语音与 SE 走不同的 `WaveSoundBuffer` 通道、或存储所在归档（`voice.xp3` 之类）——需先在多个 KiriKiri 样本上记录完整存储名与播放通道再定。
- **[ ] ② 未加自动化测试** —
- **备注**：样本与证据见 BUG-2702 同一会话。
