## BUG-3517 · video-chrome-double-click-fullscreen
- **报告**：2026-10-18（用户：M3E 浮动底栏连点「+10s / −10s」想连续快进，常被当成双击把视频切成全屏；随后要求同类判据全部根本性修复）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_fushi_page.dart` 旧 `_isVideoChromePointer`：只把顶 / 底各一条 `_videoButtonBarHeight`（56）高的几何带当控制条。M3E 底栏实际高度 = 进度条 + 按钮行 + `bottomButtonBarMargin` + 抬升，按钮上半截落在带外 → `_handleVideoPointerUp` 当成「点画面」，400ms 内两次即双击（中带桌面切全屏、左右区双击 seek）。同类「按几何猜控件区」判据共 6 处：
  1. 页面双击（全屏 / seek / 暂停）——本报告；
  2. 页面滚轮调音量（同一几何函数）；
  3. 页面长按临时倍速：外层长按是所有控件的祖先，长按控件区空隙 / 只认单击的按钮也会加速（无判据）；
  4. fork 桌面点击层 `isInPlayPauseRegion`：`desktopControlsBottomStripHeight` 按主题字段反推底部条带（BUG-3498 已为进度条上缘补过一次几何）；
  5. fork 桌面触屏滑动层：控制条显示时，从底栏空隙 / 进度条上起手的拖动只靠底部内缩挡；
  6. fork 移动端：点底栏空隙会收起控制条 / 触发 media_kit 双击 seek（无判据），拖动层同 5。
- **[x] ① 已修复** — 唯一判据改为**按下时真实 hit-test**：
  - fork 新增 `VideoControlsChromeRegion`（translucent `MetaData` 标记，不改下层命中）+ `hitsRegion(globalPosition:, viewId:)`，套在桌面 / 移动控制条的顶栏、中央按钮、进度条、底栏；页面侧细进度条与 `VideoM3eFloatingSurface` 实体胶囊也套上。
  - 页面侧 `fushi/lib/src/media/video/video_chrome_hit_test.dart` 的 `videoPointerHitsChrome`：命中路径含上述标记或带 onTap 语义的 `RenderSemanticsAnnotations`（`InkWell` / 全部 Material 按钮，覆盖页面自己叠的浮层按钮）即算控件。不用 click 光标：`InkWell` 默认 `adaptiveClickable` 在原生平台解析成 basic（测试实测抓到）。
  - 1/2：按下记账、抬起取走（与 BUG-2403 非主键账同一套），滚轮同判据；3：长按 start 命中控件即早退；4：`isInPlayPauseRegion` 改走 `hitsRegion`，删除 `desktopControlsBottomStripHeight`；5/6：滑动层用 `onXxxDragDown` 记按下点、命中控件则整次拖动作废。底部内缩 `16 + subtitleVerticalShiftOffset` **保持不变**：它在控制条隐藏时同样生效，是给系统边缘手势与字幕留的固定死区，不是控件判据（中途曾删掉它，导致隐藏态下画面底部约 100px 也能滑动调进度 / 音量 / 亮度，已撤回）；移动端点在控件区只续命（重置自动隐藏），不收起、不双击 seek。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_chrome_hit_test_test.dart`（真实渲染树：画面空白 / 底栏按钮与空隙 / 旧 56px 带外的底栏上半截 / 控制条外浮层按钮）；`fushi/test/pages/video_desktop_touch_tap_router_test.dart` 控件区 hit-test 组（真实点击层：进度条上缘 / 底栏空隙鼠标不暂停、触屏只续命、源码断言不再推几何）；`integration_test/video_wheel_volume_itest.dart` 的 chrome 反证点改取真实底栏区域中心（未在本地跑）。
- **备注**：右键菜单仍在控制条上也会弹出——那是「对视频的菜单」，不是把控件误判成画面后执行画面动作，不属本类。布局类用法（`_videoButtonBarHeight` 给 OSD / 字幕让位）不是指针分类，未动。
