## BUG-3780 · TTS 朗读把傍点 ruby（`・・` / `﹅`）当读音，着重的词整个读丢
- **报告**：2026-10-25（Discord 用户问 TTS 是否按作者标的 ruby 读人名 / 词；核对时发现）
- **真实性**：✅ 真 bug。TTS 朗读与有声书制作都经 `buildTtsBookPlan` → `splitTtsText` → `native/fushi_compute/src/parse/tts_split.rs` 切句，ruby 底本整体换成 `<rt>` 读音合成（作者标的读音确实被采用）。但 ruby 过滤（`tts_split.rs` 修复前 `:108-116`）只排除重叠 / 越界 / 空区间 / 读音全空白 / 超长，出版社用 ruby 画的傍点（`<ruby>本当<rt>・・</rt></ruby>`、`﹅`、`●`）也被收下，合成文本里「本当」变成「・・」，引擎读成停顿或不读。
- **[x] ① 已修复** — ruby 过滤加 `is_emphasis_only`：读音里一个字母 / 数字（含假名、漢字）都没有的 ruby 不收，底本按原文合成。
- **[x] ② 已加自动化测试** — `native/fushi_compute/src/parse/tts_split.rs` 单测 `emphasis_dot_ruby_keeps_base_text`（傍点 ruby 保留底本；義訓「明日→あした」、片假名长音读音照常换）。
- **备注**：有声书对齐 / 歌词 cue 的读音轨（`audiobook_alignment_service.dart`、`lyrics_cue_text.dart`）同样直接吃 `chapterPlainTextWithRuby` 的 ruby，未在本条处理。
