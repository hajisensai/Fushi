## BUG-1943 · 字幕振假名被当成正文与文字同级
- **报告**：2026-08-29（用户：字幕列表的振假名没正常显示，变成和文字一个层级了）
- **真实性**：✅ 真 bug。两条采集路径都把读音当成了正文：
  - `tools/browser-extension/content.js` 的 `fushiSubtitleTextNow` 用 `n.textContent` 取字幕
    DOM——真实 DOM 的 `textContent` **包含** `<rt>`（`<ruby>熱<rt>ねつ</rt></ruby>`.textContent
    === `熱ねつ`），于是 cue.text 直接变成「熱ねつさまし」；
  - `tools/browser-extension/subtitle-adapters.js` 的 `stripCueTags` 用 `/<[^>]*>/g` 只删标签、
    **保留内容**，VTT/TTML/SRT 路径同样把 `<rt>` 的读音拼进正文。
  这是 app 侧 `packages/fushi_audio/lib/src/parsers/strip_html_tags.dart`（BUG-1161）修过的同一
  形状在扩展侧的孪生：`<rt>`/`<rp>`/`<rtc>` 的内容都不是正文，只有 ruby base 是。被污染的不止
  显示——查词、制卡 sentence、字幕匹配吃的都是这份 cue.text。
- **[x] ① 已修复** — 三段：
  - 采集（DOM）：`content.js` 新增 `fushiCollectCueSegments` / `fushiSubtitleSegmentsNow`，按
    节点结构切成「正文段 + 可选读音」，`<rt>`/`<rp>`/`<rtc>` 不进正文（含被拆平的孤立 `<rt>`）。
  - 采集（字符串）：`subtitle-adapters.js` 新增 `splitCueRuby`，`stripCueTags` 改为先整段剔除
    注音再删标签；正则判据逐条对齐 Dart 那份（隐式闭合、不许跨 `<`、自闭合 `<rt/>` 退回旧行为）。
  - 渲染：新增 `tools/browser-extension/ruby-render.js`，**字幕列表与视频覆盖层共用**，有
    `cue.ruby` 就画真正的 `<ruby><rt>`（振假名回到正文上方），CSS 给含 ruby 的行放宽行框。
  两条不变式：段拼接恒等于 `stripCueTags` 的正文（畸形注音整行退回单段），段与 cue.text 对不上
  时不挂 ruby（逐字扩长被切行后 cue.text 只是后缀，照挂会把振假名标到别的字上）。
- **[x] ② 已加自动化测试** — `tools/browser-extension/subtitle-ruby.test.js`（字符串路径 + 渲染，
  10 条）+ `universal-subtitle-providers.test.js` 新增 4 条（DOM 采集、孤立 `<rt>`、无注音不挂
  数据、切行错位不挂）。变异实测 6/6 被抓：不剔除读音、段与正文可漂开、DOM 采样把读音当正文、
  无注音也挂数据、错位照挂、渲染把读音拼成同级文字。
- **备注**：点振假名不会查到读音——`vendor/selection.js` 的 `getCharacterAtPoint` 命中 `<rt>`
  时经 `resolveRubyBase` 重定向到 ruby base，这条路径本来就在，无需改动。
