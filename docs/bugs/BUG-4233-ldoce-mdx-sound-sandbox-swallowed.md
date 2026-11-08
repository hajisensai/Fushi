## BUG-4233 · LDOCE5++ MDX 内置发音点了不响（沙箱里词典脚本吞掉 sound:// 点击）
- **报告**：2026-11-07（用户：「LDOCE5++ V 2-15 这个 mdx 的内置音频好像播放不了了」）
- **真实性**：✅ 真 bug。词条发音是 `<a class="speaker …" href="sound://media/english/breProns/ld5_000.mp3">`，词条自带 `LM5Switch.js`。
  带脚本释义自 34eaa2e44d（2026-10-23）起跑在沙箱 iframe 里，沙箱辅助脚本 `DICT_SANDBOX_HELPER_JS`
  （`fushi/assets/popup/popup.js` 原 3584 行）只在 document **冒泡**阶段监听点击、`defaultPrevented` 即放弃。
  `LM5Switch.js` 的 `checkPlatform` 在 Windows WebView2（`windows nt` + `chrome` UA）给 `.lm5ppbody` 加 `desktop chrome`，
  `isOnlinePron()` 为真 → `onlinePronSetup()` 在 `.ldoceEntry` 上委托接管 `a.speaker[href$="mp3"]`，改去请求
  ldoceonline.com（沙箱 CSP 禁网络，必失败）并 `return false`（preventDefault + stopPropagation）——
  sound:// 永远到不了父页面的 `playWordAudio`，发音整个哑掉。
- **[x] ① 已修复** — sound: 链接改在 window **捕获**阶段接住（早于词典脚本的任何监听），只 preventDefault 不拦传播；
  冒泡阶段监听跳过 sound: 链接以免重复上报。sound:// 是 MDict 约定由宿主从 MDD 取字节播放的协议，沙箱里的词典脚本本来就播不了，
  宿主独占它是正确契约。非 sound 链接仍尊重词典脚本的 preventDefault。三份 popup.js（app / 两份扩展 vendor）同步。
- **[x] ② 已加自动化测试** — `test/js/dict_sandbox_sound_link.test.mjs`（jsdom 真实事件传播，词条 HTML 取自真实 mdx，
  按 LM5Switch.js 语义复刻委托 + return false）；修复前首条用例红、修复后 4/4 绿。
- **备注**：未在真机 / Windows app 里点真实词条复测（需导入 1.3 GB 的 mdd）。LM5Switch 的在线发音分支在 Windows 上还会删掉
  `.spx` 例句发音，属词典脚本自身行为，不在本修复范围。
