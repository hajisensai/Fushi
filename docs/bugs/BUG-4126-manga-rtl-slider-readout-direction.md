## BUG-4126 · 漫画右开本底部进度栏当前页 / 总页数与已读高亮方向反了
- **报告**：2026-11-05（用户：应用内反馈 oOre-vefJy，Android；「阅读方向从右到左，底下进度栏最右边应该是当前页码，最左边总页码」，截图 16 / 199）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/reader/manga_reader_chrome.dart` `MangaReaderBottomBar._buildRow`（develop 9eae475329，1503 行起）：滑块在 RTL 下已按 `mangaSliderPosition` 镜像（第 1 页在物理右端），但两枚读数恒按 LTR 摆——当前页在左、总页数在右，与页序反向；同时滑块控件本身仍是 LTR（1618 行 `value: position.clamp(...)` 直接吃物理位置），已读高亮从物理左端长到把手，实际画的是「未读」那段。
- **[x] ① 已修复** — RTL 时当前页读数挪到右端、总页数挪到左端；滑块控件包 `Directionality.rtl` 并吃逻辑页号（物理位置的镜像），已读高亮从右端（第 1 页）长到把手，拖动 / 方向键方向由控件自己镜像。气泡、跳转刻度、章节钮仍按物理位置算，不变。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_reader_bottom_bar_test.dart`「读数与已读轨道跟页序同向（rtl=false/true）」：读数左右顺序、Slider 吃逻辑页号、Slider 所处 Directionality。
- **备注**：未在真机复测（底栏是 Flutter 层控件，与 paginated / 双页 / 条漫模式无关）。
