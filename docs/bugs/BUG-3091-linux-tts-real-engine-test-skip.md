## BUG-3091 · Linux 真引擎 TTS 测试只判 open_jtalk 在 PATH，缺辞书或声音时误红
- **报告**：2026-10-09（审查 `90c8ab16` 时发现）
- **真实性**：✅ 真 bug（测试本身）。`fushi/test/utils/desktop_tts_linux_test.dart:114`（修前）的 skip 判据只看 `command -v open_jtalk`；装了可执行文件但没装辞书 / 声音时生产路径根本不会调用 open_jtalk（`resolveOpenJTalkAssets` 返回 null），汉字文本也不会交给 espeak-ng，`ttsToFileDesktop` 返回 null，用例红。
- **[x] ① 已修复**（见本分支提交）— 抽出 `resolveSystemOpenJTalkAssets()`（生产 `_ttsLinux` 与测试共用同一判据），skip 条件改为「open_jtalk 在 PATH 且 `resolveSystemOpenJTalkAssets() != null`」。
- **[x] ② 已加自动化测试** — 即该用例本身；本机装齐 open-jtalk + naist-jdic + nitech 声音后实跑通过。
- **备注**：
