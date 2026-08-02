## BUG-1438 · 右键/上下文菜单不吃界面大小：漫画菜单错位 + 阅读器菜单双重缩放

- **报告**：2026-08-02（用户：「漫画里面等，好多地方的右键没有吃界面大小」）
- **真实性**：✅ 真 bug，且是**两个方向相反**的缺陷共用一个根因模型（见下）。

### 根因：中和器两侧的坐标空间被混用

生产拓扑是两层缩放，改这块必须同时理解：

1. 全局 `HibikiAppUiScale` 挂在 `MaterialApp.builder`（`hibiki/lib/main.dart:1630`），
   用 `FittedBox(BoxFit.fill)` 把整棵子树渲染进一个**缩放画布**（尺寸 = 真实视口 / scale）
   再拉满屏。**根 Navigator / 根 Overlay 都在它之内**（`app_ui_scale.dart:112-122`）
   → Overlay 本地坐标 = 画布空间，且画布→屏幕这一跳会把其中一切按 scale 放大一次。
2. 阅读器 / 漫画 / PDF / 视频页在**路由层**再套 `HibikiAppUiScaleNeutralizer`
   （`app_ui_scale.dart:139-174`），把页面子树净缩放还原成 1.0（让 WebView / Texture 按
   原生密度渲染）→ 页面内部的坐标与 `MediaQuery.size` 都是**真实屏幕**空间。

菜单（`showMenu` 的 PopupMenuRoute、根 `OverlayEntry`、SelectionOverlay 的 toolbar）
挂在根 Overlay，也就是**中和器之外**。`InheritedTheme.capture` 捕获不到中和器
（它是 LayoutBuilder+FittedBox，不是 InheritedTheme），实测 scale=2 下「页面中和 / 不中和」
菜单渲染结果逐像素相同。由此两条规则不可互抄：

| 位置 | 是否已跟随界面大小 | 代码该怎么写 |
|---|---|---|
| 中和器**内**（页面 chrome / 底栏） | 否（净缩放=1） | 必须手动 `× appUiScale` |
| 中和器**外**（菜单 / 根 Overlay 浮层） | **是**（画布自带） | 尺寸写常量；坐标须 `Overlay.globalToLocal` |

**缺陷 A — 锚点：真实坐标当画布坐标（菜单跑位）**
`manga_hibiki_page.dart` `_showReaderContextMenu`：JS 报的 `clientX/clientY` 是真实屏幕坐标，
被直接当 `RelativeRect` 喂给 `showMenu`；边界还用了 `MediaQuery.of(context).size`（中和层内
= 真实视口，比 `overlay.size` 大 scale 倍）。菜单实际渲染在「点击点 × scale」——125% 时右键
点 (800,600) 菜单跑到 (1000,750)，越靠右下偏得越远；50% 则缩向左上。
同型：`hibiki_material_components.dart` 日志面板 `_buildContextMenu` 的
`TextSelectionToolbarAnchors.primaryAnchor`。

**缺陷 B — 尺寸：菜单被乘了两次 scale（scale²）**
`reader_hibiki_page.dart` 的 `_readerImageMenuScale = normalize(_readerChromeScale)` 把
chrome 的缩放口径套到了菜单上（图片右键 / 文字选区右键 / 移动端选区操作条三处）。该 getter
自己的注释甚至写着「不在阅读器中和后的 chrome 子树内」——既然不在，就已经吃过一次缩放。
**实测**：同样写 `fontSize: 14 * menuScale`，scale=2 时 chrome 文字渲染 40px，菜单 80px。

顺带修：选区操作条 `selectionBottom = selectionTop + r['height']` 把 Overlay 画布空间的
`selectionTop` 和 WebView 真实像素的 `height` 相加（混量纲），改为两角各过一次换算。

- **[x] ① 已修复** — commit 见下。改动：
  - `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart` `_showReaderContextMenu`：
    锚点经 `overlay.globalToLocal`，边界改 `Offset.zero & overlay.size`。
  - `hibiki/lib/src/pages/implementations/reader_hibiki/chrome.part.dart`：三处菜单/操作条
    去掉全部 `* menuScale`（尺寸写常量）；选区矩形两角各做一次坐标换算。
  - `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`：删除
    `_readerImageMenuScale` getter（双重缩放根源），原位留反向注释防复发。
  - `hibiki/lib/src/utils/components/hibiki_material_components.dart`：日志面板 toolbar
    锚点经 `Overlay.globalToLocal`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/context_menu_ui_scale_guard_test.dart`（9 条）：
  - **不变式 A（真渲染 + 真右键手势）**：scale=0.5/1.0/2.0 下菜单矩形到点击点的间隙
    < `24 × scale`（实测 4.0 / 8.1 / 16.1，恰为菜单自身 padding × scale）。
  - **不变式 B（真渲染）**：scale=2 的菜单文字高度恰为 scale=1 的 **2 倍**（线性，非平方）。
  - **两条变异对照**（防恒真假绿）：不做换算时偏移 >200（实测 302）；手动乘 menuScale 时
    比值变成 **4 倍**（scale²）。
  - **三条源码守卫**把生产代码钉在范式上，并已**变异实测**：三处分别改回旧写法后，
    5 个守卫用例全红，反向还原后复绿。
  - 既有 `reader_image_actions_guard_static_test.dart` /
    `reader_text_context_menu_scale_guard_test.dart` 原本断言「必须乘 menuScale」，方向是反的，
    已随本次修复反转并注明原因。
- **备注**：
  - 用户原话「好多地方」已核到 5 处（漫画右键、阅读器图片右键、阅读器文字选区右键、
    阅读器移动端选区操作条、日志面板选区工具条）。全仓其余 `showMenu` 站点（视频 / 合集网格 /
    合集详情 / 标签管理 / 插画查看器 / 关系图 / 词典弹窗 WebView）逐个核过，**均已正确**。
  - `VideoHibikiPage.neutralized` 的 `_videoUiScale` 用于**页内**顶底栏，在中和器内，
    是正确的，不要顺手删。
  - **附带发现（未在本轮修，非右键问题）**：`reader_pdf_page.dart` 的 Scaffold 带 AppBar，
    而 `buildDictionary()` 直接放在 body 的 Stack 里，其坐标空间原点是 body 左上角，但
    `_screenRectForChar`（`reader_pdf_page.dart:401-416`）报的是全局屏幕矩形 → PDF 查词弹窗
    恒定偏下约 AppBar+状态栏高度，与界面缩放无关。漫画页对这个契约有明文注释
    （`manga_hibiki_page.dart` 「buildDictionary() 绝不嵌进有 padding/偏移/滚动的子树」），
    EPUB 阅读器也是无 AppBar 全出血 Stack，**只有 PDF 违约**。建议另开一条跟进。
  - 真机复测（Windows 调界面大小后漫画/阅读器右键贴住鼠标、菜单字号与底栏一致）待用户。
