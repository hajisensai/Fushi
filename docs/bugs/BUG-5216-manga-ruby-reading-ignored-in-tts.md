## BUG-5216 · manga-ruby-reading-ignored-in-tts
- **报告**：2026-11-22（用户：漫画朗读 / 漫画有声剧制作应按页面印着的注音念，如「CRYCHIC（クライシック）」「春日影（はるひかげ）」）
- **真实性**：✅ 真 bug。① 漫画朗读 `fushi/lib/src/media/manga/reader/manga_read_aloud_plan.dart:70` 把注音块整块丢掉、合成只念底本；② 注音判定 `manga_overlay_html.dart` 的 `_mangaRubyGap` 要求底本含汉字，拉丁字母底本（CRYCHIC）上的注音根本不被认出，成了独立一句「クライシック」；③ 漫画有声剧 `packages/fushi_engine/lib/tts/manga_audio/manga_audio_validate.dart` `resolveMangaLineText` 把注音块当普通块拼进台词（AI 标注时也不知道哪块是注音），合成成「CRYCHICクライシック」或单独念注音。
- **[x] ① 已修复** — 新增 `packages/fushi_engine/lib/media/manga/manga_ruby.dart`：认注音块（底本含汉字 / 拉丁字母 / 数字），按行框把注音定位到底本的具体字（拉丁按整词），给出「显示用底本、合成用读音」。朗读（`MangaBlockSentence.spoken` → `planMangaPageReadAloud`）、有声剧（`resolveMangaLineTexts` → `mangaLineTexts.spoken`）、AI 标注提示词（`ruby-of:N` 标记）、手工标注（注音块并进底本那句）都用它。只用页面印着的注音，不推断读音（黑名单「自动注音」不涉及）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/manga/manga_ruby_test.dart`（拉丁底本、多行底本、逐字注音、重叠合并、lines_coords、假名底本不误判、有声剧台词四种组合）；`fushi/test/media/manga/reader/manga_read_aloud_plan_test.dart`「页面印着的注音」。
- **备注**：OCR 开了「忽略振假名」时注音在识别阶段就被丢掉，无从参考（用户主动选的取舍，不改）；注音与底本被 OCR 合进同一块的情况（块内注音行）不在本修复范围内。已出过音频的有声剧句子会进制作台「读法改了」清单，可一键重生成。
