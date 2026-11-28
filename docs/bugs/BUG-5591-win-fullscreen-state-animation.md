## BUG-5591 · win-fullscreen-state-animation
- **报告**：2026-11-27（用户：Windows 视频页进 / 退全屏不顺——进入有实色帧，退出先闪一个小窗口再变大、也有实色帧）
- **真实性**：✅ 真 bug。Release 版 60 fps 采样复现（玻璃设计 + 浅色主题、最大化窗口）：进入每次 2–5 帧 ≥99% 纯 RGB 243；退出每次 19–20 帧（约 320 ms）：全屏 → 屏幕中间小窗口（拉伸的快照）→ 纯 243 → 小窗里的视频 → 最大化放大动画。普通（非最大化）窗口：进入 1–3 帧、退出 2–3 帧纯 243。
  - 根因 1（进入实色帧）：`fushi/windows/runner/win32_window.cpp:818`（基线）进入时先 `SetWindowPlacement(SW_SHOWNORMAL)` 把最大化窗口还原到显示器矩形，再在 `:844` `SetWindowPos` 撑大——两步、且改了 show state。show state 改变让 DWM 播还原动画，动画画的是窗口重定向表面、不是 Flutter 子视图合成层。
  - 根因 2（退出小窗口）：`win32_window.cpp:866`（基线）退出时先 `SetWindowPlacement(SW_SHOWNORMAL)` 回到最大化前的普通矩形（屏幕中间的小窗），再 `:868` `ShowWindow(SW_MAXIMIZE)` 放大，两步各带一段 DWM 动画。
  - 根因 3（退出实色帧 / 243 灰的来源）：`win32_window.cpp:674`（基线）`FillSurfaceBackdrop` 在主表面「透底」（`MainSurfaceSeeThrough`，即玻璃设计开了 Mica，`windowBackdropRequestedOf`）时跳过过渡快照、只刷透明底；`:851/:877/:882` 又在 resize 一返回就释放快照。透出来的就是 Windows 11 浅色 Mica 材质本身的颜色 RGB 243。另外 GDI 写出的 alpha 是 0，在 DWM 里按加色叠加，所以快照即便画上去在 Mica 窗口里也不是不透明的。
  - 根因 4（第一轮修复后 Mica 下残留的 0–3 帧纯灰）：属于「父窗表面在 Flutter 新尺寸帧真正上屏前露出」，不是「Flutter 帧本身透明」。证据：① 代码路径上本地视频页整窗不透明——`third_party/media_kit_video/lib/src/video/video_texture.dart:384` 画面 `Container(color: fill)`，`fill` 由 `video_fushi/layout.part.dart:172` 定为 `Colors.black`（非网页档），全屏路由外包 `Material`（`video_fushi/fullscreen.part.dart:247`）；② 灰帧覆盖整个客户区（≥93%，余下是任务栏），没有控件 / 画面残迹，透明 Flutter 帧不会连 OSD 都没有；③ 同一构建只把「新尺寸首帧光栅化后撤回快照」（`win32_window.cpp` `OnChildFrameRasterized`）关掉，6 次切换 0 帧纯灰；撤回前加一次 `DwmFlush` 仍有 1–2 帧。即 Dart `FrameTiming` 报出新尺寸已光栅化时，DWM 还没合成到视图交换链的新缓冲（引擎 resize 时重建缓冲，旧内容作废），runner 观测不到真正上屏的时刻；透底表面此时撤回快照，露出的就是材质本色。
  - 主题 / 设计系统：243 只在「玻璃设计 + Mica 生效 + 浅色」出现；深色主题下 Mica 是深灰（同一机制，颜色不同）。M3E 下主表面不透底，基线本来就画快照，只剩根因 1、2 的两步几何 + DWM 动画（表现为快照被拉伸的小窗 / 放大动画，没有纯色）。M3E / 深色本轮没有实测像素，结论来自代码路径。
- **[x] ① 已修复** — 进出全屏各只有一步几何、关掉 DWM 窗口动画：
  - `win32_window.cpp` `SetFullscreen`：整段包在 `ScopedNoDwmTransitions`（`DWMWA_TRANSITIONS_FORCEDISABLED`）里；最大化窗口用一次 `SetWindowPlacement` 直接还原到全屏矩形（`fullscreen_geometry.h` `FullscreenUnzoomPlacement`，rcNormalPosition = 目标、换算成工作区坐标），普通窗口一次 `SetWindowPos`；退出时普通窗口一次 `SetWindowPos` 回原矩形，最大化窗口 `ShowWindow(SW_MAXIMIZE)` 从全屏矩形直接放大、再 `SetWindowPlacement` 只记账普通矩形。
  - 全屏期间 `WM_NCCALCSIZE` 把客户区钉成显示器（`FullscreenClientRect`），不受进入前 show state 测得的边框差影响；`WM_GETMINMAXINFO` 只放开 `ptMaxTrackSize`（`ApplyFullscreenMinMaxInfo`）。
  - 快照：32 位 DIB、alpha 补成 255、`AlphaBlend` 画上去，玻璃 / M3E 都不透明；不透底表面沿用 BUG-1933（快照留在视图下面）；透底表面等视图在新尺寸上报出第一帧光栅化（`OnChildFrameRasterized`）后才换回透明底，非全屏过程的 `WM_SIZE` 丢掉残留快照。
  - 根因 4 的修法（结构，不是等待）：透底只在有东西能透出来时才需要。`main_surface_composition.h` 的 `MainSurfaceState` 加 `content_opaque`，`MainSurfaceSeeThrough = system_backdrop && !content_opaque`，DWM 边距、表面填充、快照去留都从这一处派生。内容是否整窗不透明由一处决定：桌面自绘顶栏盖住整个 Navigator 的那层底色（`fushi/lib/src/utils/components/fushi_desktop_title_bar.dart` 的 frame `ColoredBox(colors.surface)`，底层合成时让开、由 WebView2 宿主垫底）。那层就地包一个 `OpaqueWindowContentClaim`（`fushi/lib/src/utils/opaque_window_content_claim.dart`），按它自己的颜色经 `setContentOpaque` 认领：不透明时主窗表面在 Mica 下也按不透明合成，全屏跳变走 BUG-1933 的不透明路径（快照像素留在视图底下，视图新帧上屏前看到的是上一帧画面，不是纯色）。所以首页 / 书架上 F11、本地视频页、网页视频页（底层合成）都走这条路径。可靠性不依赖时序：表面合成方式只跟「内容是否不透明」这一事实走，切换只发生在这层颜色变化时（不透明→认领放在那一帧画出之后，变半透明→放手赶在那一帧之前），与跳变、上屏时刻都无关。
  - 第二轮曾把认领放在本地视频页上（路由落定后认领）。查实后改到根层：根层 frame 底色本来就盖住每个路由，首页 0.6 的外壳底色叠在它上面同样不透明；按页认领既覆盖不全（F11 在首页 / 书架、网页视频页），又是对同一事实的第二份声明。
  - 附带发现（用户 2026-11-28 拍板维持现状）：因为根层 frame 是实色，Windows 上 Mica 在正常画面里透不出来（只在跳变空档里露出过）。用户拍板维持现状：frame 保持实色、不打引擎补丁；`home_page.dart` 里「外壳半透明让系统背景透出」的注释已改成与实际一致（只改注释，行为不变）。
- **[x] ② 已加自动化测试** —
  - 原生单测 `fushi/windows/runner/tests/fullscreen_geometry_test.cpp`（cmake 构建门 `fushi_windows_fullscreen_geometry_gate`）：全屏矩形、客户区钉死、工作区坐标换算（任务栏底 / 左 / 上）、un-zoom 直接落到全屏矩形而不是普通矩形、退出计划。
  - 原生单测 `tests/main_surface_composition_test.cpp`：Mica + 不透明内容 → 不透底、边距同普通窗口。`fullscreen_geometry_test.cpp` 加过渡时间线（`fullscreen_trace.h`）的记录与「过渡期间窗口尺寸序列」分析。
  - runner 诊断时间线 `fullscreen_trace.h`：每次 SetFullscreen 从头记录 `WM_WINDOWPOSCHANGED`（窗口矩形 / zoomed / 客户区）、子窗尺寸投递与引擎阻塞耗时、Dart 报的新尺寸首帧光栅化、快照撤回原因，带 QPC 微秒时间戳；窗口通道 `fullscreenTrace` 读出。
  - 离屏集成测试 `fushi/integration_test/win_fullscreen_geometry_itest.dart`（`run_windows_itest.ps1`，窗口停在 -32000，不上屏不激活；`PROBE_MAXIMIZED=true/false` 两条路径）：进 / 出各自从开始到读出为止窗口尺寸只出现一个（全屏 / 进入前）、全屏客户区 = 显示器、退出后矩形 / 客户区 / 最大化态与进入前逐一相等、子窗收到新尺寸且新尺寸帧已光栅化（打印耗时）。
  - widget 测试 `fushi/test/utils/opaque_window_content_claim_test.dart`：路由里入场动画中不认领、落定后认领、pop 当下同步放手、随 enabled 切换、离树放手；路由外（根层 frame）画出一帧后认领。
  - 离屏集成测试预置玻璃设计（向 runner 请求 Mica），断言每次快照撤回原因都是「不透明表面」，即根层认领生效、表面没被清成材质。
  - 守卫 `fushi/test/build/win_fullscreen_flash_guard_test.dart`：DWM 动画关闭包住所有几何调用；进入无 `ShowWindow`、只一次 `SetWindowPlacement` 且走 `FullscreenUnzoomPlacement`；退出无 restore-to-normal、`ShowWindow(SW_MAXIMIZE)` 在记账 `SetWindowPlacement` 之前；透底表面只在光栅化回报后清快照。
- **备注**：
  - 复测（第一轮修复后，60 fps，玻璃 + 浅色，最大化）：进入一步到位、无任务栏残帧；退出不再出现小窗口，直接回最大化；残留 0–3 帧纯 243，见根因 4，已按上文修。
  - 离屏时间线实测（`win_fullscreen_geometry_itest`，普通窗口 2384x1591 起步，窗口停在 -32000）：进入 6.7 ms 一次 `WM_WINDOWPOSCHANGED` 直达 3856x2169、客户区 3840x2160 = 显示器，过程中无其它尺寸；退出 12.7 ms 一次直回 2400x1600 原矩形、客户区 2384x1591，逐项与进入前相等。最大化起步在离屏 runner 里只能验几何（进 / 出各一个尺寸、退出后 zoomed 与矩形与进入前相等，已过）：停在 -32000 的 zoomed 窗口被 window_manager 按工作区算出负的客户区（-60134x-61814），视图没有尺寸，客户区 / 光栅化断言在这条路径跳过。首轮跑法用默认帧策略（只在 pump 时出帧），子窗 resize 次次撞引擎 100 ms 超时、新尺寸光栅化回报晚 1 s，测试已改 `fullyLive` 并等到新尺寸光栅化回报再读时间线。
  - 第二轮登记的「首页 F11 / 网页视频页仍露材质」已随根层认领修掉（那些页面在窗口层面同样不透明）。
  - 离屏集成测试里子窗投递 116–124 ms（超过引擎 100 ms 等待）、新尺寸首帧约 250 ms 才报光栅化：Debug 构建 4K 首帧超过 100 ms，引擎等待超时返回；`FrameTiming` 在 debug / profile 每约 100 ms 成批回报（release 约 1 s，见 Flutter `SchedulerBinding.addTimingsCallback` 文档）。真实上屏的 Release 首轮像素里退出 3 帧内到位，没有出现超时后的延迟投递。潜在风险照记：若 Release 下某次跳变首帧也超过 100 ms，紧接着的反向跳变会被 BUG-2462 的子窗闸门压到下一批 `FrameTiming`（最长约 1 s）才投递，表现为子窗短暂保持旧尺寸（有画面，不是纯色）。要缩短得有比 `FrameTiming` 更快的「新尺寸已呈现」信号，同样落在引擎补丁上，随上条拍板。
  - 前台像素复测（2026-11-28，Release `3ee74f7a3c7` 的构建，60 fps 桌面录屏 + 1 kHz 轮询窗口矩形，按 F11 切换；纯色帧 = 某一帧里出现前后稳态帧都没有的大块单一颜色区，>6% 画面）：
    | 组 | 跳变数 | 纯色帧 | 中间尺寸帧 |
    |---|---|---|---|
    | 玻璃 + 浅色，视频页最大化 ×3 | 6 | 0 | 0 |
    | 玻璃 + 浅色，视频页普通窗口 ×2 | 4 | 0 | 0 |
    | M3E + 浅色，视频页最大化 ×2 | 4 | 0 | 0 |
    | 玻璃 + 深色，视频页最大化 ×2 | 4 | 0 | 0 |
    | M3E + 深色，视频页最大化 ×2 | 4 | 0 | 0 |
    每次跳变都是 1 帧完成：最大化 3866x2090 ↔ 全屏 3866x2186，普通窗口 2400x1500 ↔ 全屏 3856x2169，中间没有第三种尺寸。同一判据跑修复前的基线录屏：进入 3/1/5 帧纯色（Mica 243），退出各 13 帧（小窗口后面露出桌面）。
    首页 / 书架按 F11 不进全屏是设计如此（`fushi/lib/src/shortcuts/global_navigation.dart:839` 只有内容页能进窗口全屏），这两项不适用。网页视频页这一项没有可比数据，见待办。
  - 多显示器、任务栏在左 / 上的真机路径只由单测覆盖，未实机测。
