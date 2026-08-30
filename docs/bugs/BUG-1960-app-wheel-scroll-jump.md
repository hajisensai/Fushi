## BUG-1960 · App 桌面滚轮滚动逐事件瞬移不流畅
- **报告**：2026-08-30（用户：App 内例如首页滚动不流畅，怀疑一次滚动范围过大）
- **真实性**：✅ 真 bug。首页纵滚是 `fushi/lib/src/pages/implementations/home_dashboard_page.dart:995` 的默认 `ListView`，没有调节滚轮输入。Windows Flutter engine 按系统默认 3 行把一格滚轮换算成约 100px，framework 随后把原始 delta 直接交给 `ScrollPosition.pointerScroll` 单帧 `forcePixels`，所以真实表现就是约 100px 一格的离散跳转。`fushi/lib/src/utils/misc/platform_utils.dart:62` 的 `desktopAwareScrollPhysics` 只管 clamp/bounce，既不缩放 pointer delta，也不做插值。首页虽会一次读最多 200 条活动并 eager 构建时间轴，但普通滚动不触发这批 widget 重建，不是“一格一跳”的第一根因。
- **[x] ① 已修复** — `bbdf2d91c8`：新增可复用的 Windows 粗滚轮归一化控制器；粗滚轮沿用 popup 已验证参数降为 0.48（默认约 100px → 48px），小 delta 精密触控板/高分辨率滚轮保持 1:1，并在同一 200ms gesture 内锁住设备分类；`pointerScroll(0)`（inertia cancel）立即清分类。首页主 `ListView` 接入；触摸拖动、键盘/手柄滚动和横向嵌套行不改。
- **[x] ② 已加自动化测试** — `bbdf2d91c8`：`fushi/test/utils/misc/desktop_wheel_scroll_controller_test.dart` 覆盖粗/细 delta、fine/coarse latch、idle reset、inertia cancel 跨设备复位与边界；`fushi/test/pages/home_dashboard_scroll_controller_wiring_test.dart` 钉住首页 controller 持有/释放/接线。与图标守卫合跑共 17 tests 全绿。
- **备注**：刻意不对所有 `pointerScroll` 无条件加动画：该 API 已丢失设备细节，精密触控板也可能走同一通道；二次平滑会制造拖尾。本提交修的是用户点名的首页主滚动，并把控制器做成可复用件，不宣称其它尚未接线的页面已覆盖。真机仍需用鼠标滚轮与触控板各复测一轮。
