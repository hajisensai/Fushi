## BUG-2062 · 字幕工作台作用域开关独占一行：挂在 AppBar.bottom 上，标题行右半边全空
- **报告**：2026-09-03（用户：截图 QQ_1788367188399.png，「本集和整个合集应该和字幕标题同行才对。中间空了好多」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/subtitle_workbench_page.dart:233`
  把「本集 / 整个合集」`SegmentedButton` 塞进 `AppBar.bottom` 的 `PreferredSize(Size.fromHeight(56))`，
  于是标题行右侧整条空着、开关自己又占满一行，标题与面板之间凭空多一截留白。
  实测（1400x900 宿主）：标题与开关的垂直中心差 **52px**。
- **[x] ① 已修复** — 开关移进 `AppBar.actions`（`Padding` + `Center`，避免 actions 的
  `CrossAxisAlignment.stretch` 把它拉到 toolbar 满高），`bottom` 去掉。
- **[x] ② 已加自动化测试** — `fushi/test/pages/subtitle_workbench_page_test.dart`
  「作用域开关与标题同一行：不再挂 AppBar.bottom 多占一行」：断言 `AppBar.bottom == null`
  **且**标题与开关垂直中心差 < 8px。后一条是实质判据——挂 bottom 时两者也都在 AppBar 里，
  只按「在不在 AppBar 里」判会恒真。变异实测：退回 bottom → `bottom` 断言红；
  单独屏蔽它后 dy 断言实测 52.0，同样红。
- **合入前审查追加修复（窄屏 AppBar 溢出）**：`AppBar.actions` **不给子级任何宽度上界**，
  带文字标签的 `SegmentedButton` 按自身固有宽度摊开，宽度随译文长度走。360x780（常见手机竖屏）
  实测（测试字体 Ahem，比真机宽约 50%）：zh 220.8px / ru 474.6px / de 502.8px / en 559.2px /
  fr 643.8px。zh 只是把标题压到 44px（看着像「窄但没坏」），en/de/fr/ru 四种语言当场
  `RenderFlex overflowed by 211 / 155 / 296 / 127 pixels on the right`、标题宽度直接归零。
  只按中文验会整批漏掉。按屏宽设一个阈值挡不住——「放不放得下」同时取决于宽度、语言和字体，
  一个常量在任一维度上都必然选错；改为**开关只放图标、文案落 `ButtonSegment.tooltip`**，
  三个变量一起消失（图标宽度是常量）。
- **[x] ③ 窄屏已加自动化测试** — 同一文件「窄屏 360x780 AppBar 不溢出、标题留得住宽度」
  按 zh-CN / en / de / fr / ru **逐语言参数化**（只跑 zh 照不到，见上）。三条断言：
  `takeException() == null`（先取异常再量几何——溢出时子级仍会被摆到越界位置，只量宽度会读到
  一个「合理」的数字）、开关右边界不越 AppBar、标题拿到 `min(自然宽度, AppBar 宽 40%)`。
  第三条的两侧来源独立：左边是这一次 AppBar 布局的结果，右边是拿 `RenderParagraph` 已解析好的
  span 另跑一次**无界** `TextPainter`。既不用常量（`字幕` 自然宽度本来就只有 44px，常量判据会
  把「没被挤」误判成「被挤了」），也不用严格等于自然宽度（Ahem 下 `Subtitles` 是 198px，窄屏
  本来就该省略号收尾，那是在测字体不是测布局）。
  变异实测：把 `label:` 加回两个 `ButtonSegment` → en/de/fr/ru 四条红（报的正是上面四个溢出像素数），
  zh 仍绿——这正好证明逐语言参数化不是装饰。
- **备注**：既有用例原来靠 `find.text(t.video_subtitle_scope_collection)` 点开关，
  改纯图标后该 `Text` 不再存在，已改用 `find.byTooltip(同一条 i18n key)`——仍锚在同一个
  key 上，改名会连带这里一起红。
