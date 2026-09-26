## BUG-2705 · KiriKiri EmbedKrkrZ 台词被双写并拼上当前循环音效标签（千恋＊万花）
- **报告**：2026-09-26（按用户「文本 / 音频 / 内嵌查词 / 点击不推进」四条验收时发现）
- **真实性**：✅ 真 bug，真机复现。千恋＊万花光盘版原版 `SenrenBanka.exe`（KiriKiri Z，SHA-256 `5b9cdea0a8c5b22cfb1a7df2ecb2e01484a190dce31b2cd6d6b101b178645727`）经 Fushi 启动并选定 `EmbedKrkrZ`（`ENHVXN-8@2198`）线程后，宿主收到的每一句都是「台词台词■自動車（車内／走行）」。循环音效开始时同一线程先单独发出 `■自動車（車内／走行）`，之后每句都是 `P P T`。块级折叠（`native/galgame_hook/include/luna_text_selector.h` `LunaNormalizedTextLength`）要求整串无剩余成对，`P P T` 一条都折不了，原样入环。
- **[x] ① 已修复** — 提交 `b247f10fcdc`：`LunaPairedTailTracker` 按线程记住最近一条「开头不是成对块」的独立事件；后续事件恰好以它结尾、且去尾后能完整成对时才剥掉并折叠。只作用于已做成对折叠的 hook 面（`EmbedKrkrZ` / `typemoon`），`injector_main.cpp` `LunaOutput` 先算 thread_id 再在 `g_lunaSelectCs` 下调用。不看文本内容 / 游戏名 / 哈希；合法叠句（「わかったわかった、もう行くよ」）照旧原样。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/luna_text_replay_test.cpp`（返回码 60–70：尾巴先独立出现、`P P T` 折成 P、成对行不覆盖尾巴、合法叠句不动、线程隔离、非折叠 hook 面不受影响、换音效后旧尾巴不再剥、新尾巴生效）。
- **备注**：
  - 修复后同一原始路径真机：共享内存里 `EmbedKrkrZ` 行为 `『お客さん』` / `「……ぁ？」` / `「お客さんってば」`；宿主台词 `「志那都荘まで行って欲しいんですけど」`、`「あー……すみません。アタシはここいらに詳しくないんですよ」`，后者 `audio=matched/game_resource`。
  - 已知限制：若 helper 在音效已开始循环后才附着、没见到独立的 `T`，这一段不会剥，直到下一次音效切换。独立的 `T` 行本身仍会作为一行出现在台词列表里。
  - x86 CTest 118/118、x64 114/114。
