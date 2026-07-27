## BUG-1186 · AppBar 动作折叠判据读整窗宽，分栏/受限宽容器里永不折叠
- **报告**：2026-07-28（用户：PR#495 审查遗留建议）
- **真实性**：✅ 真 bug（判据错源，非视觉主观问题）。根因
  `hibiki/lib/src/utils/components/hibiki_material_components.dart:1126`（修复前）——
  `narrowAwareAppBarActions` 用 `MediaQuery.sizeOf(context).width` 拿**整个窗口**的宽度
  判「是不是窄屏」，而它要回答的问题是「这条 AppBar 塞不塞得下这些动作按钮」。二者只在
  「页面独占整窗」时碰巧相等；页面嵌进分栏 / 受限宽容器 / 对话框时整窗很宽而本行很窄，
  判据永远判为「宽」，BUG-1184 折叠机制整个不触发，合集名 / 书名照样被一排图标挤没。
  这与 PR#495 在 `HibikiToolScaffold`（同文件，原 `MediaQuery.sizeOf(context).width * 0.48`）
  亲手修掉的是同一类错误——那边已改用 `LayoutBuilder` 的局部约束，这里漏了。
- **[x] ① 已修复** — 判据改取该 AppBar 自己拿到的约束宽：
  `narrowAwareAppBarActions` 去掉 `BuildContext` 参数（改后已无用途），改为必填
  `availableWidth`；**故意不给默认值**，没有「取不到就退回整窗宽」的后路，这个 bug 就走不回来。
  两个调用点（`media_collection_detail_page.dart`、`media_collection_grid_detail_page.dart`）
  把 `AppBar` 包进 `PreferredSize(kToolbarHeight) + LayoutBuilder`，下发 `constraints.maxWidth`
  ——`kToolbarHeight` 正是 `AppBar` 无 `bottom` 时的默认 `preferredSize`，Scaffold 仍自行叠加
  状态栏 padding，与直接挂 `AppBar` 行为一致。
  判据比的是**逻辑像素**：动作按钮固有宽（`IconButton` 48）同样是逻辑像素，「几个按钮塞得下」
  是逻辑坐标系里的几何问题，不需要像 `windowSizeClassReal` 那样按 UI 缩放还原物理宽。
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/narrow_screen_overflow_test.dart`
  「AppBar 动作折叠」组按真实调用形态搭台（`Scaffold` + `PreferredSize` + `LayoutBuilder`），
  三条用例：窄窗窄行折叠、**宽窗（1200）窄行（360）仍折叠**（钉住本 bug，改回
  `MediaQuery.sizeOf` 即红）、宽窗宽行（700）逐个平铺（宽屏零行为变化的反向用例）。
  用例同时断言 `LayoutBuilder` 观测到的宽度，证明喂进判据的确实是局部宽。
- **备注**：负向验证已做——把判据回退成 `MediaQuery.sizeOf(context).width` 后，
  「宽窗窄行」用例转红且仅该条红（另两条仍绿，说明它精确锚定本 bug）；还原后全绿。
