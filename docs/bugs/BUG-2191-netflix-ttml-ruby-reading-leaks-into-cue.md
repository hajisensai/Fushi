## BUG-2191 · 网飞 TTML 振假名读音混进字幕正文与制卡句子
- **报告**：2026-09-06（顺带发现：用户同一张网飞卡 `Sentence` 字段实录「雛宮の地下牢ちかろう は<b>ネズミ</b>や虫が這は い回って」——「ちかろう」「は」是振假名读音）
- **真实性**：✅ 真 bug。Netflix 日文轨是 IMSC 1.1 TTML，注音用 `<span tts:ruby="container|base|text|delimiter">`，不是 HTML `<ruby>/<rt>`。`tools/browser-extension/subtitle-adapters.js` `parseTtml` 只走 `stripCueTags`（其 `RUBY_ANNOTATION` 只认 `<rt>/<rp>/<rtc>`），读音 span 只剥标签留内容 → 读音拼进 `cue.text`，查词、制卡 sentence、字幕匹配一起被污染（与 BUG-1161 / DOM 采样侧 `fushiCollectCueSegments` 已修过的同一类问题，漏了 TTML 这一路）。
- **[x] ① 已修复** — `subtitle-adapters.js` 新增 `ttmlRubyToHtml`：按标签流把 `tts:ruby="text"` → `<rt>`、`delimiter` → `<rp>`、`container` → `<ruby>`、`base` 解包，注音单元收尾后紧跟的行内空白（Netflix 用它在注音 span 间断词）一并吃掉；`parseTtml` 先翻译再 `stripCueTags`，并按 `splitCueRuby` 挂 `cue.ruby` 分段（面板/覆盖层能画真振假名，同 textTracks 收割路径）。畸形/无 `tts:ruby` 输入原样返回。三镜像已同步。
- **[x] ② 已加自动化测试** — `tools/browser-extension/subtitle-adapters.test.js`：BUG-2191 三例（container 形态 + delimiter + 断词空格 → 正文纯净且 ruby 分段正确；裸 base/text 对；畸形输入不吃正文）。
- **备注**：仅扩展侧 TTML 解析器；app 内 WebView 网页播放器若日后接 Netflix 轨需复用同一翻译。
