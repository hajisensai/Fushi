## BUG-3092 · isKanaOnlyText 拒收〜…等读音常见符号、却放行 espeak-ng 读不了的・与小片假名扩展
- **报告**：2026-10-09（审查 `90c8ab16` 时发现）
- **真实性**：✅ 真 bug。`isKanaOnlyText`（`fushi/lib/src/utils/misc/desktop_tts.dart:148-149`，修前）：
  - 读音里常见的 `〜`（U+301C）、`～`、`…`、`‥`、`「」` 不在白名单，含它们的纯假名读音被拒，espeak-ng 兜底不触发；
  - 反过来 `0x30A0–0x30FF` 整段收进了中点 `・`（U+30FB），`0x31F0–0x31FF` 片假名音标扩展也收；espeak-ng 1.51（`-v ja -q -x` 音素输出实测）把它们念成英语 "Japanese letter" / "Chinese letter"。
- **[x] ① 已修复**（见本分支提交）— 按 espeak-ng 实测重定白名单：收 `〜 ～ … ‥ 「」『』 ｡｢｣､･` 与假名本体（含 `ー ｰ ゝゞヽヾ`）；拒 `・` 与 U+31F0–31FF。ASCII `~` 仍拒（espeak-ng 念 "tilde"）。
- **[x] ② 已加自动化测试** — `fushi/test/utils/desktop_tts_linux_test.dart` 的「isKanaOnlyText 符号」组。
- **备注**：实测方法：逐码位 `espeak-ng -v ja -b 1 -q -x "か<字符>"`，输出含 `(en)` 即判读不了。`ん` 后接 `ー`/`〜` 时 espeak-ng 也会出 "Japanese letter"，属上下文怪癖，`ー` 原本就收，未据此拒收。
