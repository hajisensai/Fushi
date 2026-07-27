## BUG-1168 · 静止树上 addPostFrameCallback 焦点回收永不触发（进出全屏/关字幕遮罩后快捷键失灵）

- **报告**：2026-07-27（用户：「无论是做视频还是漫画都特别容易丢快捷键，鼠标事件也容易丢」——排查该总症状时，给统一焦点层写单测**暴露出来**的存量真 bug）。
- **真实性**：✅ **真 bug（单测复现 + 沿真实代码路径确认）**。`WidgetsBinding.instance.addPostFrameCallback` **本身不调度帧**：它只把回调排进「下一帧结束后」的队列，若此后没有任何东西请求下一帧，回调就一直挂着、永不执行。视频页有三处「等下一帧再归还焦点」的补丁全部只调了 `addPostFrameCallback`，没有配套的帧调度：
  - `hibiki/lib/src/pages/implementations/video_hibiki/fullscreen.part.dart:224`（进全屏 `finally`）
  - 同文件 `:237`（`_onVideoFullscreenRouteClosed`，所有退全屏路径的收口）
  - `hibiki/lib/src/pages/implementations/video_hibiki/subtitle.part.dart:896`（`_hideSubtitleLoadingOverlay` 关闭字幕抽取加载态后）
  （以上均为修复前行号。）
  - 触发条件：**视频暂停**（或已播放完）时树静止——播放中每帧都在推进，回调顺带被执行，所以问题只在暂停态暴露，这也是它长期没被发现的原因。此时进全屏 / 退全屏 / 关字幕加载遮罩之后，焦点回收永远不发生，键盘快捷键失灵，只能靠点一下画面的兜底路径恢复。
  - 这三处 post-frame 是必须的、不能改成同步：注释（`fullscreen.part.dart:219-222`）已写明同步 `requestFocus` 会跑在全屏路由 build 之前，随后的 reparent 会把 primary focus 让给全屏路由的 `ModalScope`，进全屏后快捷键直接死掉。所以修法不是去掉 post-frame，而是补上帧调度。
- **[x] ① 已修复** — 提交 `9ef5f2776`（PR #480）。根因修：`PageFocusOwnership.reclaimAfterFrame` 在注册 post-frame 回调后显式调 `WidgetsBinding.instance.ensureVisualUpdate()` 把帧要出来（`hibiki/lib/src/focus/page_focus_ownership.dart`）。三处调用点一并改走该方法，「等下一帧」这件事从此只有一份实现，不会再有人只写一半。
- **[x] ② 已加自动化测试** — `hibiki/test/focus/page_focus_ownership_test.dart` 的 `reclaimAfterFrame defers to the next frame`：先断言**不同步执行**（`reason: 'must not run synchronously'`），再 `pumpAndSettle` 后断言回调已跑且节点持焦。该用例在补 `ensureVisualUpdate` 之前是**红的**（树静止、无人调度帧，回调不执行，`asked` 为空）——即这条测试真的复现了本 bug，不是事后补的形式测试。另有 `video_page_keyboard_focus_static_test` / `video_subtitle_fixes_guard_test` 源码守卫钉住三处调用点必须走 `reclaimAfterFrame`（而非裸 `addPostFrameCallback`）。
- **备注**：全平台（桌面尤甚，桌面才有键盘快捷键依赖）。`flutter analyze` 干净；`test/focus` + `test/media/video` + 视频页 11 个守卫共 1979 passed。**桌面真机肉眼复测待用户**：视频**暂停**状态下按 F 进全屏 → 直接按空格/方向键应立即生效（修复前需先点一下画面）；退全屏、以及加载外挂字幕后同理。同批修复见 [BUG-1167](BUG-1167-video-subtitle-align-dialog-focus-not-returned.md)。
