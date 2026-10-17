## BUG-3340 · 库页工具行按钮组胶囊比搜索框高
- **报告**：2026-10-14（用户：书架「搜索库」行，右侧齿轮 / 多选 / 排序按钮组胶囊比左边搜索框高一截，桌面与手机都如此）
- **真实性**：✅ 真 bug。设计意图两边同高：`LibraryToolbar._trailingPill` 与 `LibrarySearchField` 都取 `librarySearchFieldHeight`（MD3 40，`fushi/lib/src/pages/implementations/library_filter_dropdown.dart`）。但 `FushiFloatingToolbarSurface`（`fushi/lib/src/utils/components/fushi_floating_chrome.dart`）只把 `height` 当 `minHeight`，胶囊里的图标按钮命中盒 44（`tag_filter_bar.dart` `_tagBarAction` 的 pinActions 形态）把胶囊撑到 44，截图 2× 下 80px 对 88px。同库的 `FushiPageChromeCapsule` 早已是定高（BUG-2977），只有这个胶囊还是「至少」，所以凡是与别的控件并排的悬浮胶囊等高都只是巧合。
- **[x] ① 已修复** — `FushiFloatingToolbarSurface` 的高度改为定值（`SizedBox(height: extent)`，内容按「高 − 竖向内边距」的上限排，按钮命中盒收进胶囊而不是撑高它）；作用于所有调用点：库页工具行、页头悬浮动作组、库页页签胶囊、合集详情页签胶囊。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_floating_chrome_test.dart`「FushiFloatingToolbarSurface 高度是定值」组：40 高搜索框 + 内含 44 命中盒按钮的胶囊并排必须等高；缺省高恒为 56、与内容高度无关。
- **备注**：书架搜索框本身正被其它 agent 重做，修复落在共享胶囊上，不依赖书架页的具体结构。
