# Android 应用外查词

系统文本选择菜单继续使用标准 `Intent.ACTION_PROCESS_TEXT`。外部应用也可显式调用 `app.fushi.reader.PopupDictFlutterActivity`，传入 `Intent.EXTRA_PROCESS_TEXT`（`text/plain`）。

可选参数：

| Intent extra | 类型 | 缺省 | 含义 |
| --- | --- | --- | --- |
| `charIndex` | Int | -1 | 点击位置在完整原文内的 UTF-16 下标；不提供时沿用整段查询。 |
| `sourceTextCollapsed` | Boolean | false | 本次请求是否先折叠顶部原文；用户仍可用工具栏按钮展开。 |

`sourceTextCollapsed` 只控制展示。完整原文、点击位置和制卡上下文照常传递，不应为了隐藏原文而截断文本。该参数同时支持冷启动和窗口热复用；每个新请求独立解析，不提供参数时恢复默认展开，不继承上一次请求的折叠状态。展开后原文最多使用工具栏下可用空间的三分之一，超出部分在原文区域内独立滚动；下方词典释义保留自己的滚动区域。

此参数是 Intent extra，不是 URL 查询参数或持久化设置。

应用内词典页与嵌入式词典（双屏伴屏）同样把原文放进限高视口（`BoundedSourceLookupViewport`），上限为可用高度的二分之一，超出部分在原文区域内独立滚动；下方结果区始终是固定大小的区域，不随原文滚动改变尺寸。

```kotlin
val lookup = Intent(Intent.ACTION_PROCESS_TEXT).apply {
    setClassName("app.fushi.reader", "app.fushi.reader.PopupDictFlutterActivity")
    type = "text/plain"
    putExtra(Intent.EXTRA_PROCESS_TEXT, sourceText)
    putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
    putExtra("charIndex", tappedUtf16Index)
    putExtra("sourceTextCollapsed", true)
}
startActivity(lookup)
```
