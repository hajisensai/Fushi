## BUG-4005 · 沉浸锁定时长按画面仍会临时加速，不跟随沉浸模式档位
- **报告**：2026-11-03（开发者反馈 #LVLfqlFLVA：「沉浸模式的时候长按应该不能加速播放，或者说应该跟随配置项效果」，Windows，3.3.0-debug.23213）
- **真实性**：✅ 真 bug。长按临时倍速入口 `fushi/lib/src/pages/implementations/video_fushi/speed.part.dart:73` `_handleVideoLongPressStart` 只判「是否落在控件上」（`videoPointerHitsChrome`）就接管倍速，从不看 `_immersiveLocked` / `appModel.videoImmersiveMode`。长按识别器 `VideoLongPressSessionDetector` 挂在 `layout.part.dart` 控制条 `IgnorePointer` 之外，沉浸锁定挡不到它；同为指针播放控制的触摸双击 seek（`_immersiveAllowsDoubleTapSeek`）、滚轮音量与右键菜单（`_immersiveAllowsFullControls`）早已按档位门控，长按是唯一漏网的。键盘 / 手柄按住倍速走 `_runWhenImmersiveAllowsShortcuts`，本来就跟随档位。
- **[x] ① 已修复** — 判据收进纯函数 `videoImmersiveAllowsLongPressSpeed`（`fushi/lib/src/media/video/video_immersive_mode.dart`：未锁定放行，锁定只有 `full` 档放行，与触摸双击 seek 同档）；`_handleVideoLongPressStart` 在写恢复位 / 改倍速前先过它，早退后 move / end 都是空操作。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_immersive_long_press_speed_test.dart`：四档 × 锁 / 未锁真值表 + 接线守卫（判据先于 `_longPressPreviousSpeed = _playbackSpeed`）。`test/pages/video_immersive_mode_levels_guard_test.dart` 同跑无回归。
- **备注**：VideoFushiPage 依赖 media_kit，宿主测试不能整页实例化，接线只能源码守卫。未在真机 / 桌面实测长按。
