## BUG-3310 · 移动端双击暂停被跨设备同步的「点击画面播放/暂停」开关静默关掉
- **报告**：2026-10-13（应用内反馈 #lGxHvuULXI，iOS 27.2 (24B5084k)，iPhone18,3，2.10.0-debug.18681：「ios 视频播放器双击无法暂停」；截图为横屏、控制条隐藏、Jellyfin 远程片源；日志显示该用户与电脑端互联同步。）
- **真实性**：✅ 真 bug（契约缺陷；该用户设备上的实际开关值无法取得，见备注）。
  - 中带双击的唯一静默不动作分支：旧 `fushi/lib/src/media/video/video_double_tap_center_action.dart:28`
    `if (!tapTogglesPlayback) return VideoDoubleTapCenterAction.none;`，页面在
    `fushi/lib/src/pages/implementations/video_fushi_page.dart:11084` 把 `_asbConfig.tapTogglesPlayback` 喂进去。
  - `tapTogglesPlayback` 是 `VideoAsbplayerConfig` 里的一个字段，整份配置存在偏好键 `video_asbplayer_config`，
    它**不在** `SyncRepository.deviceLocalPrefKeys`（`fushi/lib/src/sync/sync_repository.dart:1483`）里 → 随备份 / 互联同步跨设备。
  - 这个开关在桌面上管「鼠标单击画面暂停」（`playAndPauseOnTap`），是桌面用户常关的项；在手机上单击本来就不改播放态，
    它唯一的效果就是吃掉「双击中带暂停」。于是电脑上为鼠标单击关掉它 → 同步到 iPhone → 手机双击静默不暂停，
    设置页文案（「关闭后点击画面只唤醒控制条」）也完全不提双击。一个布尔编码了两台设备上两个不同手势，是数据结构错误。
  - 手势层排查（排除其它假设）：用真实 vendored 移动控制条 `MaterialVideoControls`（带 onTap / onDoubleTap / 长按 / 横竖滑识别器）
    + 与页面同构的 translucent `Listener` 宿主，在 iOS / Android 两种 `Theme.platform` 下注入触摸双击：fork 的
    `DoubleTapGestureRecognizer` 赢下竞技场也吞不掉宿主 `onPointerUp`（Listener 不进竞技场），宿主每次都认出双击、走到判据。
    iOS 没有任何 `Platform.isIOS` 分支、手机上不进全屏路由、中带不落 chrome 带，单击唤出控制条也不会吃掉双击。
- **[x] ① 已修复** — `doubleTapTogglesPlayback` 拆成独立字段（默认 true，旧档缺键回落 true、**不**从 `tapTogglesPlayback`
  继承，`video_asbplayer_config.dart:156`）；判据只读它（`video_double_tap_center_action.dart`，页面 `video_fushi_page.dart:11084`）；
  设置页新增「双击画面播放/暂停」（`video.playback.double_tap_toggles_playback`，全平台可见，`settings_schema_video.dart:1282`），
  原「点击画面播放/暂停」只在桌面可见（`settings_schema_video.dart:1265`，移动端已无效果，露出来是假开关）。
  桌面鼠标双击仍切全屏；左 / 右三分之一快退快进（`_handleDoubleTapSeek`，排在判据之前）未改动。提交 d5bbe904e1。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_mobile_double_tap_pause_test.dart`（真实移动控制条 + 宿主 Listener 的触摸双击行为测试：
  iOS / Android 在「电脑同步来的 tapTogglesPlayback=false」下双击中带切换播放态；显式关掉双击开关后不动作；Android 左区双击照样到达宿主）、
  `fushi/test/media/video/video_asbplayer_config_test.dart`（旧档 `{"tapTogglesPlayback":false}` 解出 doubleTap=true）、
  `fushi/test/media/video/video_double_tap_center_action_test.dart`、`fushi/test/pages/video_double_tap_seek_guard_test.dart`
  （页面只传双击开关、不再读 `_asbConfig.tapTogglesPlayback`；两个 schema 行与可见性）、`test/settings/settings_schema_coverage_test.dart` 登记。
- **备注**：
  - 未在 iOS 真机 / 模拟器上复测原始路径；也无法读取该用户设备上的 `video_asbplayer_config` 实值，所以「这位用户正是被同步来的 false 卡住」
    是代码路径上唯一能产生该症状的分支、而非实测确认。本机 Windows 离屏 itest（平台改 iOS 跑真 libmpv）因 VS 工具链被 flutter 判为缺组件未能构建。
  - 行为变化：曾在手机上主动关掉旧开关来禁用双击暂停的用户，升级后双击暂停会恢复，需改关新开关。这是有意的：旧值无法区分「为鼠标单击关的」
    与「为手机双击关的」，继承它就保留了本 bug。
