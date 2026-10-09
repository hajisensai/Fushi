# Kiku 卡片模板夹具

`front.html` / `back.html` 原样取自 [youyoumu/kiku](https://github.com/youyoumu/kiku)
`packages/note/template/`（提交 `2a7b295006f5b86dd34cc0c119601820178bef56`），MIT License，
Copyright (c) 2025 youyoumu。

`release-front.html` / `release-back.html` 来自官方
[Kiku_v2.1.0.apkg](https://github.com/youyoumu/kiku/releases/download/v2.1.0/Kiku_v2.1.0.apkg)，
用 Anki 导入隔离 collection 后读取 Mining 模板，未修改模板内容。

`v1-back.html` 原样取自上游 tag `v1.10.2` 的 `packages/note/template/back.html`，
覆盖旧版隐藏 div 数据源；上述文件同为 MIT License。

**源模板不等于发行模板**：构建脚本 `packages/note/script/generate-template.ts`
会把 `<!-- SSR_TEMPLATE -->` 替换成 `renderToString` 输出。`PictureSection.tsx`
的服务器渲染分支明确输出 `{{Picture}}`，发行版背面因此有两处可见裸引用，
但 hydration 后只提取 `<img>`。只用源码模板作夹具会漏掉这个假阳性。

用途：`test/synchronized_clip_template_test.dart` 断言 Kiku 不能承载音画同步片段（BUG-2869、BUG-2923）。
