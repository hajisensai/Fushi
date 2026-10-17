## BUG-3503 · iOS 竖排翻页：有声书当前句窄条越出页尾、画进下一页页顶
- **报告**：2026-10-17（用户：iOS 竖排翻页，句子没读完时翻到下一页，页顶对应位置露出上一页高亮的一小截；同日追加：窄条两端不贴字、句末标点后像多出一截）
- **真实性**：✅ 真 bug。Apple 正文开了 `hanging-punctuation: allow-end`（`fushi/lib/src/reader/reader_content_styles.dart:584`），行尾「、」「。」挂到分栏外；窄条层（`fushi/lib/src/reader/reader_selection_scripts.dart` 的 `lanes()`）按字形盒画，条越出栏尾。翻页模式各页是 body 多列的一栏，竖排各页同一横坐标、横排同一纵坐标，越出量大于列间距（22px）时那截落进下一页页顶。iOS 26.5 模拟器 Safari + 生产 CSS/引擎复现：字号 44px 时整列窄条 0–748（栏高 714），下一页页顶露出 12px 带圆角的残条；Blink 不支持 hanging-punctuation，所以只在 Apple 端出现。
- **[x] ① 已修复** — `lanes()` 在翻页多列时按 body 的 column-width / column-gap 求每段所在栏，窄条沿行方向收进本栏、并条不跨栏（`columnFrame`，`reader_selection_scripts.dart:965`）；滚动 / VN 没有分栏不受影响。同时按用户追加反馈，片段首尾的全角标点按墨迹收边（收尾标点取字格前 0.6、起头标点取后 0.6，已被 vpal/palt 压窄的不收，`punctInk`，`reader_selection_scripts.dart:884`）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/highlight_lanes_harness.mjs`（经 `highlight_lanes_test.dart` 跑）：翻页四种页面里用 nowrap 文字溢出栏尾，断言窄条不越栏（修前四页全红，越栏 410 / 619px）；句末「。」窄条止于墨迹。
- **备注**：
  - 验证：iOS 26.5 模拟器 Safari 跑生产引擎页（非 app 内）——竖排翻页修前 / 修后截图对比、滚动模式窄条与修前逐像素一致（仅标点收边处不同）、横排翻页只差悬挂「、。」那几条的栏尾。VN 在模拟器探针页里没有活动 cue，由 Chrome harness 的 VN 页覆盖。
  - 悬挂到栏外的「、」「。」本身也会被 body 的 clip-path 裁掉看不见（与本修复无关，未改）。
  - 用户说的「句与句之间被顶开」另有原因，未在本条修：WebKit 里给句子包 `<span class="fushi-sentence-audio-cue">` 会改变同一行后续字的位置（模拟器最小页实测：给「置かれ」包一层 span，本行后续字整体移 11px，第二行也变），即句子包裹本身改了排版，需另开任务（方向：不改 DOM 的 Range 高亮）。
  - 本机 headless shell 下 `highlight_lanes_test` 竖排 6 页的「lane overlaps furigana ink」在未改代码上同样失败，属既有问题，非本次引入。
