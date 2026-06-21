## BUG-368 · 分页模式鼠标正文横向拖动无法翻页(桌面)
- **报告**：2026-06-21（用户：阅读器翻页模式竖排+横排都没法用鼠标翻页，想「改成和手机一样的操作」）
- **真实性**：✅ 真 bug（设计缺陷，非回归）。根因 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` 的注入 JS：
  - 分页模式下桌面**没有「点击翻页」功能**（`onTap` 只切 chrome / 划词查词，见 `reader_hibiki_page.dart` onTap handler ~2509）。
  - 鼠标拖动翻页被 `_hoshiReaderMouseDragStartAllowed`（~1853）的 caret-range 门控挡住：拖动起点落在正文（`_hoshiReaderCaretRangeAtPoint` 命中）→ `_hoshiReaderMouseNativeTextStart=true` → `pointermove`（~2075）里移动 >6px 就放弃手势交还原生选区，**永不回传 onSwipe**。正文铺满视口 ⇒ 鼠标几乎只能在空白边距拖动才翻页 ⇒ 实际「翻不了页」。
  - 不对称：**触摸路径**（`touchend → _gestureEnd → onSwipe`，~1983）在正文上横滑就能翻页（触摸不走 caret 门控），鼠标却不行 → 「鼠标 ≠ 手机」。
  - 注：任务给的「reader-shelf DropTarget 吃掉鼠标事件」假设**已证伪**——desktop_drop Windows 实现只用 `RegisterDragDrop`+`IDropTarget`（OLE 文件拖放），不 subclass 窗口、不处理 `WM_MOUSEWHEEL`/`WM_LBUTTON`，无法吃滚轮/点击；`[hibiki-drop][reader-shelf]` 日志只在真有 OLE 文件拖入时 fire，与翻页无关。
- **[x] ① 已修复** — `reader_hibiki_page.dart` `pointermove` 的 `_hoshiReaderMouseNativeTextStart` 分支：分页模式（`!hoshiContinuousMode`）下先用 `_hoshiReaderMouseDragResolvePageDirection`（与触摸横滑同款「横向占优且达滑动阈值」判据）判定本次拖动是否已构成明确横向翻页手势——是则把手势从「原生选词」转为「拖动翻页」（清原生选区、接管 pointer、`pointerup` 经 `_finishHoshiReaderMouseDrag` 回传 `onSwipe`）；否则保持原行为（竖向/短拖交还原生选区，划词查词不受影响）。让鼠标横滑在正文上翻页，与触摸对齐。提交于分支 `todo-629-656-reader-flip`（合并后取并入 develop 的实际哈希）。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_mouse_paging_boundary_guard_static_test.dart`（源码守卫：`pointermove` native-text 分支须在分页模式 resolve 翻页方向、接管为 claimed 拖动、清原生选区，且短/竖拖仍回退原生选词；onSwipe 仍只从 pointerup 发一次）。headless WebView 不可用，按项目范式用注入 JS 源码守卫；红→绿已验（撤修复 → 守卫红）。
- **备注**：UX 决策点（已升级 PM，未擅自实现）：是否再加**桌面「左右半屏点击翻页」**（标准 ebook 阅读器交互，比横滑/滚轮更接近「和手机一样」），但会与现有「点击切 chrome / 划词查词」语义冲突，需 PM 定左右分屏比例、中段是否切 chrome、与 `highlightOnTap`/`tapEmptyToHideChrome` 的关系。滚轮翻页 JS 本身健全（`onSwipe`，~2250），未改；若真机仍滚轮翻不动，怀疑 WebView2 在不可滚动分页页面不派发 `wheel`（fork 只把 `PointerScrollEvent` 转 `setScrollDelta`），需真机确认后另立 bug。**需真机复测**：Windows/桌面分页模式横滑翻页、竖排+横排、划词查词不被误转翻页。
