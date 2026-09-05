## BUG-2155 · 音标标签框撑爆卡头：60dvw 视口上限 + 单行不换行，窄卡上把封面顶出视口
- **报告**：2026-09-05（用户转述用户反馈：换成维基音标词典后「更离谱了，图图都顶没了」，附 `first` 卡截图，标签框里十几条音标挤成一条横贯整卡的黑带）
- **真实性**：✅ 真 bug。headless 渲染复现：用真实 `LapisNoteType.css` + popup.js 真实产出的字段 HTML（17 条音标），
  在 820px 卡宽下修复前 `.def-header` 整个横向溢出——词头框左边被切掉、`.dh-image` 被顶出视口。
- **根因（三条独立成因，缺一条都还会犯）**，全在 `packages/fushi_anki/lib/src/lapis_note_type.dart`：
  1. `.tags` 给 `#pitch-tags` 的是 `max-width: 60dvw`（`:1443`）——一个**视口**相对的上限，
     塞进 `max-width: 820px` 的 `.def-header`（`:1465-1474`）里毫无意义：宽屏上 60dvw 比整个卡头还宽。
  2. `.tags` 的 `white-space: nowrap`（`:1445`）是给「一个短标签」设计的。音标词典一个词能给十几条，
     只能靠 `text-overflow: ellipsis` 截掉大半，或者在窄卡上直接把行撑出去。
  3. `.dh-vocab` 是 flex item 且没写 `min-width`（`:1476-1482`），默认 `auto` = 不小于内容最小尺寸；
     标签框是个 inline-block，宽度就是内容宽，于是这一列的最小宽度顶穿卡头，右边的 `.dh-image` 被压成 0。
- **为什么日语卡一直没事**：日语声调只有 `[1]`、`[3]` 这种一两个短标签，三条成因都不触发。
- **[x] ① 已修复** — 三处对症：`.dh-vocab { min-width: 0 }`；`#pitch-tags { max-width: 100%; white-space: normal }`；
  `#pitch-tags` 的列表改成 `display: inline-flex; flex-wrap: wrap`。
  最后一条**必须是 flex 而不是让行内流换行**：制卡侧产出的 `<li>…</li><li>…</li>` 之间一个空白都没有，
  行内流的换行点来自空白，没有空白就没有换行机会；flex 的换行点在 item 边界，不依赖空白。
  同时 `#pitch-tags li { white-space: nowrap }`，保证不会从某条音标中间断成 `[/fɜː` + `st/]`。
- **[x] ② 已加自动化测试** — `fushi/test/anki/lapis_pitch_tag_list_markup_test.dart` 三条新用例，
  分别钉 flex-wrap 列表、容器相对的 `max-width: 100%` + `white-space: normal`、`.dh-vocab` 的 `min-width: 0`。
- **回归证据**：日语短标签那档（2 个标签 + 封面）修复前后 **headless 渲染逐像素零差异**
  （`ImageChops.difference(...).getbbox()` 为 `None`）——常见路径一个像素都没动。
- **备注**：同一张卡上还叠着 BUG-2151（`<ol>` 标记契约）与 BUG-2152（同一发音重复两遍）。三条都已修。
  遗留一个**没修**的观感问题：popup.js 给每条音标外面统一套 `[...]`，而维基音标词典的值本身就带
  `/…/` 或 `[…]`，于是渲染成 `[/fɜːst/]`、甚至 `[[fəɹst]]` 双层方括号。要不要改成「值已自带定界符就不再套」
  需要用户拍板，未动。
