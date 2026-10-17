## BUG-2977 · M3E 浮动页头标题胶囊下半截被裁、返回圆底部被切
- **报告**：2026-10-06（用户转述协作者 shishamo：「← 搜索字幕」「← 作品资料」等子页的标题胶囊底边是一条直线、下圆角消失，返回圆底部也略被切；「很多地方都有相同的问题」，字幕 / 资源搜索页同样）
- **真实性**：✅ 真 bug。胶囊统一高从 48 升到 56（`kFushiFloatingToolbarCompactExtent`）后，三处容器 / 胶囊自身的高度账没跟上：
  - `fushi/lib/src/utils/components/fushi_floating_page_chrome.dart` `FushiPageChromeCapsule.build`：外层 `minHeight: 56` + 内层又一层 `minHeight: 56`，`FushiPageChromeTitle` 再给 Pill 竖向 `padding 6×2` → 标题胶囊实高 **68**。
  - `fushi/lib/src/utils/components/glass/fushi_glass_bars.dart` `FushiAppBar._buildFloating`：工具栏 `toolbarHeight` 56，Flutter `AppBar` 默认 `ClipRect(Clip.hardEdge)` 把工具栏裁在 56 内 → 68 高的标题胶囊下 12px 被一刀切平；返回圆（正好 56）的悬浮投影（向下 3 + 模糊 8）也被裁掉，看起来底部被切。所有走 `FushiAppBar` 的子页（搜索字幕 / 资源搜索 / 作品资料 / 订阅 / 设置子页等）全中。
  - 同文件大标题收起行 `collapsedHeight` 仍是 48 时代的 52，外层 `ClipRect`；`fushi_material_components.dart` `FushiToolScaffold` 工具条行高同为 52 → 同样截胶囊、压扁返回圆。
- **[x] ① 已修复** — 胶囊恒为 `kFushiPageChromeExtent`（定高 + 只取横向 padding + 竖向居中）；标题行单行省略、`forceStrutHeight` 固定行高，调用方 TextStyle 行高撑不开；悬浮 `FushiAppBar` 工具栏不裁（`Clip.none`），并在正文滚离顶部时于栏下沿铺 `FushiTopFadeScrim` 渐隐，去掉「头部下沿硬切线」；收起标题行高 = 胶囊 + 8、展开不低于收起；工具条行高 = 胶囊高。提交见 git log（fix(chrome): BUG-2977）。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/floating_title_capsule_clip_test.dart`（胶囊高 = 56 且完整落在 AppBar 内、返回圆 56 方、大行高 / 副标题撑不高、AppBar 工具栏 ClipRect 为 `Clip.none`）。
- **备注**：未跑测试 / analyze（用户 10-06 指示跳过，人肉热重启验证）。对话框形态（`FushiDialogFrame`，如 Jimaku 字幕对话框 / 资源搜索对话框）不用浮动胶囊页头，不在本修复范围。
