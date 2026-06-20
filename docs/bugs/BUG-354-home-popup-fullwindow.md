## BUG-354 · 首页查词弹窗被结果子区域clamp跳不出搜索框/页边距(嵌套层坐标系不一致偏移)
- **报告**：2026-06-20（TODO-617 M0 地基；用户希望首页/嵌套查词弹窗能像 yomitan 那样飘出当前小窗）
- **真实性**：✅ 真 bug。双层根因（沿真实代码路径验真）：
  1. **被子区域 clamp + 物理裁剪**：旧实现把查词弹窗栈挂在 `_buildSearchResultBody` 的
     `Expanded > HibikiAppUiScaleNeutralizer > LayoutBuilder > Stack(_resultStackKey)` 内
     （`hibiki/lib/src/pages/implementations/home_dictionary_page.dart:672-722`）。`screen` 取自该结果子区域
     `LayoutBuilder` 约束（被 `DesktopContentLayout` 的 1040 限宽 + padding 收窄，
     `hibiki/lib/src/utils/misc/platform_utils.dart:92-105,147-177`），`calcPopupPosition`
     （`dictionary_popup_layer.dart:31-43,83-87`）按子区域 `screen` clamp，弹窗跳不出搜索框上方/页边距外；
     宿主 `Stack` 默认 `Clip.hardEdge`，超出子区域的弹窗/屏外热槽被裁。
  2. **嵌套层坐标系不一致（潜伏偏移）**：嵌套层经 `popupWordScreenRect`(localToGlobal) 算的是
     **绝对屏幕坐标**（`dictionary_popup_layer.dart:258-270` + `dictionary_page_mixin.dart:288,327-347`），
     却配子区域局部 `screen`/`Positioned` → 嵌套弹窗整体偏移约「页头+搜索框+padding」高度（顶层因
     selectionRect 也是 Stack 局部坐标而自洽）。
- **[x] ① 已修复** — 照搬 `VideoHibikiPage` 的根 Overlay 范式把弹窗栈提到**全窗根 Overlay**、统一坐标系到真实屏幕空间：
  `home_dictionary_page.dart` 新增 `_syncPopupOverlay()`/`_buildPopupOverlay()`（`Overlay.maybeOf(context, rootOverlay: true)`
  + `OverlayEntry` + 内套 `HibikiAppUiScaleNeutralizer` + `Stack(clipBehavior: Clip.none)`，`screen`=中和后整窗
  LayoutBuilder 约束）；dismiss 遮罩/搜索期占位卡/各嵌套层移到该 overlay；`dispose()` 摘 entry + `deactivate()/activate()`
  翻 `_overlayInert`（销毁期空渲染，照搬 video BUG-121）。坐标系统一：顶层结果 WebView 选区经 `_resultWordScreenRect`
  →`popupWordScreenRect`(屏幕坐标)，源文本条 `SourceLookupTextPanel` 新增 `globalCoordinates: true`
  （`clipboard_lookup_text_panel.dart` `_localRectOf` 两角 localToGlobal 回报屏幕坐标），嵌套层仍走 `popupWordScreenRect`
  不变。提层后 screen=整窗、Positioned 原点=屏幕左上、所有 selectionRect=屏幕坐标三者同系，弹窗能飘出结果子区域到整窗、定位自洽。
  提交：见本轮 commit。video 走根 Overlay 已全窗（`video_hibiki_page.dart:2888-2971`）本轮不改；reader 各自 screen 来源不动。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/home_dictionary_popup_overlay_test.dart`（新）：
  根 Overlay+中和器弹窗按屏幕坐标跨缩放贴词（含 y=40 顶部位置证明跳出子区域）/去中和器对照红/
  `SourceLookupTextPanel(globalCoordinates:true)` 回报屏幕坐标（panel 推离原点证非 0 起点局部坐标）/
  源码守卫（rootOverlay+OverlayEntry+中和器+Clip.none+_overlayInert+deactivate+popupWordScreenRect+globalCoordinates）/
  mixin 嵌套仍用 popupWordScreenRect 契约不变。既有 `calcPopupPosition` 纯函数守卫
  （`dictionary_popup_layer_test.dart` 等）+`video_lookup_popup_overlay_test.dart`+`popup_word_screen_rect_test.dart`
  不回退；更新陈腐静态守卫 `desktop_clipboard_click_lookup_static_test.dart`（localRect→screenRect）。
  `test/pages/`+`test/reader/` 全量 1600 绿。
- **备注**：M0 地基，TODO-617 的 M1+（Ctrl+C 注入抓前台选区 / 按住语义 / 托盘唤回）待用户答 2 决策后续。仅改首页表面；
  reader/video 查词弹窗定位不变（各自 screen 来源）。真机待用户验：首页查词弹窗能飘出搜索框子区域到整窗，reader/video 不变。
