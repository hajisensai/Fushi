## BUG-4130 · 网易云艺人简介 <h> 标记原样画出、摘要只露信息框键名
- **报告**：2026-11-06（用户：截图反馈，网易云插件外文艺人 Polyphia 的艺人页）——简介里 `<h>History </h>` 这种标记原样画在正文里；头部三行摘要只露出「Origin / Plano, Texas, US / Genres」这些信息框键名。
- **真实性**：✅ 真 bug。插件原样转交平台文本（网易云外文艺人简介是从百科搬来的，段落标题写成 `<h>…</h>`，夹 `<br>` / `&amp;`），页面直接当纯文本画：
  - 艺人页头部摘要 `fushi/lib/src/pages/implementations/music/music_plugin_detail_pages.dart:825-832`（develop fd09429392）`Text(bio, maxLines: 3)`——原文整段、截前三行，正好是信息框；
  - 「详情」页签 `music_plugin_detail_pages.dart:958-964` `SelectableText(desc)` / `SelectableText(s.text)`——标记原样画出；
  - 专辑 / 歌单简介 `music_plugin_detail_pages.dart:507-508` `_ExpandableText(description)`——同上。
- **[x] ① 已修复** — 新增纯函数解析层 `fushi/lib/src/media/music/plugin/music_plugin_intro_text.dart`：`parseMusicIntro` 把 `<h>` 解析成小标题块、`<br>`/`<p>` 转换行、剥其余标签、一次扫描解码常见实体（不二次解码），段落按空行切分；详情页签按块排版（小标题用 `FushiSectionTitle.group`）；专辑 / 歌单简介用 `musicIntroPlainText`（块间保留空行，纯文本简介段间空行不丢）；头部摘要用 `musicIntroSummary` 取第一条以句末标点收尾的行（信息框的键 / 值不是句子；不靠行长魔数，中文短句同样认）。提交：6cf4b9aa6a（PR #2963 初版）+ 审查修复提交（见 PR #2963）。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/plugin/music_plugin_intro_text_test.dart`：真实网易云形状的简介解析出「正文 / 小标题 / 正文」且无 `<`；`br/p` 换行与分段；实体只解一次（`&amp;lt;` → `&lt;`）；纯文本段间空行保留；摘要跳过信息框、中文短句不被跳过、`U.S.` 缩写不算句末。
- **备注**：未在真 app 里看像素（PR 作者注明本机调试实例未起来）。
