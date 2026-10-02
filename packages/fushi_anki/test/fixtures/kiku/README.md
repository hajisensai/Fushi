# Kiku 卡片模板夹具

`front.html` / `back.html` 原样取自 [youyoumu/kiku](https://github.com/youyoumu/kiku)
`packages/note/template/`（提交 `2a7b295006f5b86dd34cc0c119601820178bef56`），MIT License，
Copyright (c) 2025 youyoumu。

构建时 `<!-- SSR_TEMPLATE -->` 会被替换成以空字段骨架 `renderToString` 出的标记，不含
`{{字段}}`，所以源模板与装进 Anki 的模板在「哪些字段被原样渲染」上一致。

用途：`test/synchronized_clip_template_test.dart` 断言 Kiku 不能承载音画同步片段（BUG-2869）。
