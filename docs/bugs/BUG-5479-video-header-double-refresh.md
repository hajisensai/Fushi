## BUG-5479 · 视频库页头点「刷新」后并排出现两颗刷新钮
- **报告**：2026-11-25（用户：视频库「首页」页头点刷新，刷新钮旁边又多出一颗刷新，Windows 桌面，宽窗）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/pages/implementations/home_video_page.dart:9662`「刷新进行中另挂一颗刷新钮」与 `fushi/lib/src/utils/components/fushi_material_components.dart:4787` 页面「⋯」项宽窗平铺成独立图标钮（ce67e5539f）叠加）
- **[x] ① 已修复** — `FushiHeaderMoreEntry` 加 `busy`：平铺时就是同一颗按钮置灰且恒外露，留在菜单里置灰；视频库页删掉「进行中」那颗另挂的刷新钮，刷新项改用 `busy: _headerRefreshBusy`
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_header_adaptive_overflow_test.dart`「页面「⋯」项的 busy（BUG-5479）」两例（宽窗空闲 / 进行中都只有一颗、进行中置灰不可重入；窄位进行中恒外露）；`fushi/test/pages/home_video_refresh_remote_guard_test.dart` 守卫改为断言不再另挂 `video-library-refresh`
- **备注**：

### 根因

设计稿 #video V2 把视频库的「刷新」收进页头「⋯」，并在刷新进行中**另挂**一颗
同图标的 `video-library-refresh` 按钮（置灰），让「⋯」里的状态看得见。之后
ce67e5539f（用户 2026-11-24「宽窗有空间还是展开最好」）让页面「⋯」的项在放得下时
平铺成独立图标钮——刷新项从此常驻页头，再叠上那颗「进行中」按钮，就是并排两颗。

### 修复

进行中状态归还给菜单项本身（`FushiHeaderMoreEntry.busy`）：页头统一收纳
（`_headerActionOfMoreEntry`）把 busy 项平铺成置灰、恒外露的同一颗按钮；仍在菜单里时
置灰。页面不再为「进行中」另造按钮。
