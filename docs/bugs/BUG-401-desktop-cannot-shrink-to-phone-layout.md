## BUG-401 · 桌面窗口缩不进手机底栏布局

- **报告**：2026-06-22（用户：TODO-714）
- **真实性**：✅ 真 bug。三层叠加，断点读到的不是真实物理宽：
  - **断点读被放大的逻辑宽**：首页布局判据 `HomePage` 的 `LayoutBuilder`（`hibiki/lib/src/pages/implementations/home_page.dart:440` 一带）、`DesktopContentLayout`（`hibiki/lib/src/utils/misc/platform_utils.dart` 内）、`HibikiPageHeader` 的 `narrowWindow`（`hibiki/lib/src/utils/components/hibiki_material_components.dart:1590` 一带）都在 `HibikiAppUiScale` 缩放器**内层**取 `constraints.maxWidth` / `MediaQuery.sizeOf().width`。缩放器把子树按虚拟画布 `realViewport / scale` 布局（`hibiki/lib/src/utils/app_ui_scale.dart:107` `canvas = view / s`），所以内层读到的是被放大的逻辑宽，不是真实窗口宽。
  - **桌面自动缩放下限 0.88 → 逻辑宽虚高**：`automaticScaleForViewport` 桌面 `minAutoScale=0.88`（`app_ui_scale.dart:68`），逻辑宽最多被放大 `1/0.88≈1.136×`。真实窗口约 560–590px 时逻辑宽被抬到 607–636 落进 medium 带 → 仍走侧栏（nav-rail），手机底栏（compact）布局够不着；真实 ~820px 时逻辑宽 ~842 落进 expanded（应为 medium）。
  - **最小窗口宽锁 480 以上**：`DesktopWindowPlacement.minimumSize` 原 `Size(960, 640)`（`hibiki/lib/src/startup/desktop_window_placement.dart:19`），桌面窗口根本拖不到能进 compact 的真实宽度。
- **[x] ① 已修复** — 提交 `见分支 fix-714-responsive HEAD（合并 develop 后以入库哈希为准）`
  - 断点收敛进纯函数：`platform_utils.dart` 新增 `windowSizeClassForWidth(double width)`（单一阈值真相源）与 `windowSizeClassReal(double logicalWidth, double appUiScale)`（`realW = logicalWidth * appUiScale`，scale 非有限/非正时退化为恒等）。`windowSizeClassOf` / `windowSizeClassFromContext` 改为委托 `windowSizeClassForWidth`，行为不变（旧调用方/旧测试恒等回归）。
  - 三个缩放器**内层**调用点改用真实宽：
    - `home_page.dart` 首页 `LayoutBuilder`（底栏↔侧栏）→ `windowSizeClassReal(constraints.maxWidth, HibikiAppUiScale.of(context))`。
    - `platform_utils.dart` `DesktopContentLayout.build`（书架/视频/词典/设置 body）→ 同上。
    - `hibiki_material_components.dart` `HibikiPageHeader.narrowWindow` → `windowSizeClassReal(MediaQuery.sizeOf(context).width, HibikiAppUiScale.of(context))`。
  - 放开最小窗口宽：`DesktopWindowPlacement.minimumSize` `Size(960, 640)` → `Size(480, 640)`，让真实窗口能拖到 <600 进 compact。
  - **未碰** Neutralizer 之下已吃真实宽的 reader/video/词典路径（它们用 `kHibikiSettingsWideThreshold` + 被 Neutralizer 中和回真实宽，本就对）；**未改** `app_ui_scale.dart` 的 `_scaleMediaQuery` / `canvas`（改了会连坐 WebView/弹窗坐标，见该文件 `app_ui_scale.dart:13` 警告）。
- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/platform_layout_test.dart` + `hibiki/test/utils/misc/responsive_breakpoint_real_width_test.dart`（提交 `见分支 fix-714-responsive HEAD`）
  - 纯函数（最硬）：`windowSizeClassReal` scale=1 全档恒等回归；`(600, 0.88)` → compact（修前逻辑宽读法落 medium）、`(960, 0.88)` → expanded、`(480,1.0)` → compact、`(1280,1.0)` → expanded、`(762,1.05)≈800` → medium；非有限/非正 scale 退化恒等；`windowSizeClassForWidth` 阈值锁定。
  - widget 行为：用 `tester.view.physicalSize` 构造真实物理宽 + 真 `HibikiAppUiScale`（桌面自动缩放）复现生产判据 `LayoutBuilder`，断言真实 480/560px 走底栏（compact）、真实 1280px 走侧栏（nav-rail）。560 是关键判别带——修前逻辑宽放大到 >600 误判 medium。
  - `hibiki/test/startup/desktop_window_placement_test.dart`「small work areas」用例随 minimumSize 下调更新：800px 宽工作区首屏默认从 800（被旧 960 最小宽钳满）改为 656（82% 默认比例），居中 left 72。
- **备注**：B 项放开最小窗口宽改了原生 `window_manager` 的 `setMinimumSize` 路径，桌面真机拖窗进底栏布局留用户复测；正常设备不回退（桌面 ≥1280 真实宽仍 expanded、平板 ~800 仍 medium）。
