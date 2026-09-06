## BUG-2105 · 移动端换集后掉出全屏：旧页 dispose 无条件放开横屏锁并清空系统栏回调
- **报告**：2026-09-04（用户：「视频全屏跳转到别的集数会退出全屏播放」，附安卓截图）
- **真实性**：✅ 真 bug（静态可证的时序反序，移动端唯一暴露面）。根因 `fushi/lib/src/pages/implementations/video_fushi_page.dart` 的 `dispose`（原第 3757 / 3791-3794 行：`SystemChrome.setSystemUIChangeCallback(null)` + `_restoreOrientationOnExit()` + `setMacOSTrafficLightsHidden(false)` 三处**无条件**还原）与 `initState`（第 1943-1956 行认领同三件）
- **[x] ① 已修复** — 本分支 `worktree-worktree-user-batch-0904`（提交见 git log）
- **[x] ② 已加自动化测试** — 纯函数真值表 `fushi/test/media/video/video_display_claim_test.dart`（7 组，含「新页 initState 先于旧页 dispose」「连续换集三集」两条正是本 bug 的顺序）+ 源码守卫 `fushi/test/media/video/video_lifecycle_static_test.dart` 三条（initState 必须先登记再设；dispose 不得含任一无条件还原；`_releaseVideoDisplayClaim` 的记账门必须排在三件还原之前）。变异实测：把 `if (!VideoDisplayClaim.release(this)) return;` 改成裸调用 → 守卫判红
- **备注**：视频播放/全屏类。BUG-2043 只修了桌面（全屏路由接管），移动端整段被 `isMobilePlatform` 门控掉，是同一症状的遗漏面。桌面/macOS 也顺带受益（换集不再让 macOS 交通灯闪出）。真机复测缺口见下。

### 根因

移动端**没有全屏路由**（BUG-221 起 `_toggleVideoFullscreen` 在 `isMobilePlatform` 上统一 no-op，横屏沉浸态即唯一「全屏」形态）。因此换集（`video_fushi/episode.part.dart` 的 `_switchEpisode` 本地分支）走 `resolveEpisodeSwitchPlan` 的 `replace` 模式 = 裸 `pushReplacement`，BUG-2043 的接管路径（`push` + `removeRoute` + `initialFullscreen`）在移动端根本不进。

而视频页在 `initState` 认领三件**进程级、全局单槽**的显示态：

1. 横屏锁 `_lockLandscapeForVideo()` → `setPreferredOrientations([landscapeLeft, landscapeRight])`；
2. 系统栏可见性回调 `_registerSystemBarsVisibilityCallback()` → `SystemChrome.setSystemUIChangeCallback(...)`（**全局单槽**，后设的覆盖前一个）；
3. macOS 交通灯隐藏 `setMacOSTrafficLightsHidden(true)`。

`dispose` 里原先**无条件**把这三件还原。Flutter 语义下 `pushReplacement` 的旧路由要等新路由入场动画结束才被移除并 `dispose`，所以真实顺序是：

```
新页 initState（锁横屏 / 注册回调 / 隐交通灯）
      ↓ 约一个入场动画之后
旧页 dispose（放开方向 → 置空回调 → 显交通灯）   ← 把新页刚设好的全部掀掉
```

于是换集后：

- **方向**：`_restoreOrientationOnExit()` 把允许集放宽成 `[portraitUp, landscapeLeft, landscapeRight]`。移动端开着「自动旋转锁定」时，含 `portraitUp` 的允许集会退回用户锁定的竖屏 —— 画面当即从横屏满屏变竖屏小窗，观感就是用户报的「跳转到别的集数会退出全屏播放」。
- **系统栏几何**：全局回调被置空后 `_systemBarsVisible` 再不更新，`_videoBottomSystemInset` 的门控卡在旧值，进度条 / 字幕避让几何回到 BUG-383 的错态。
- **macOS**：交通灯在全屏画面左上角闪出（桌面侧走 `takeover` 路径，同样命中这条无条件还原）。

同一形状的第四件（Windows 标题栏 owner）**早就是对的**：`FushiWindowsTitleBar.setContentFullscreen(owner: this, ...)` 用 `_contentFullscreenOwners` 集合按所有者记账，所以标题栏没有这个 bug。

### 修复

抄上面那份既有范式，把「该不该还原」从页面生命周期改成**所有者记账**：

- 新增 `fushi/lib/src/media/video/video_display_claim.dart` 的 `VideoDisplayClaim`（纯 Dart 登记表：`claim(owner)` / `release(owner)`，`release` 返回 true **当且仅当**集合被它清空）。
- `initState` **先** `VideoDisplayClaim.claim(this)` 再去设三件。
- `dispose` 的三处无条件还原收敛成一个 `_releaseVideoDisplayClaim()`：`if (!VideoDisplayClaim.release(this)) return;` 之后才还原。换集期间集合短暂同时含新旧两页 → 旧页释放时非空 → 不还原；正常退页时集合空 → 照旧还原。

判据是纯函数，所以「旧页掀掉新页显示态」这条回归可在 headless 单测判红（行为级要真设备方向系统 + 真过渡动画，跑不了）。

### 验证

- `flutter test test/media/video/ test/video/macos_video_trafficlight_hide_guard_test.dart test/pages/video_orientation_fullscreen_guard_test.dart test/pages/video_statusbar_immersive_guard_test.dart --no-pub`：`PASSED - 3086 tests ran`
- 变异实测：去掉记账门 → `video_lifecycle_static_test.dart` 判红（`FAILED`）；还原后复绿
- ⚠ **真机复测缺口**：安卓真机上「开着自动旋转锁定 → 横屏看片 → 换集」这一条原始失败路径尚未实测（本轮只做了静态与单测层）。桌面侧 BUG-2043 的离屏 e2e（`integration_test/video_fullscreen_sublist_next_episode_test.dart`）覆盖的是全屏路由掉线，不覆盖移动端方向锁。
