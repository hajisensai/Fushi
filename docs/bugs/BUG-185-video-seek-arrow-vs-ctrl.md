## BUG-185 · 视频普通箭头改时间seek/Ctrl箭头改句子seek+上句太远回退3s
- **报告**：2026-06-11（用户：TODO-090 飞书第103行 / TODO-085 飞书第98行）
- **真实性**：✅ 真需求（行为改进）。现状 `hibiki/lib/src/media/video/video_player_shortcuts.dart:58-60`
  把**普通**左右方向键绑到上/下一句字幕（`previousSubtitle`/`nextSubtitle`），用户要的是普通
  ←/→ = 按秒时间 seek、Ctrl+←/→ = 按句字幕 seek；且按句后退（Ctrl+←）时若上一句距当前太远应退化成回退 X 秒。
- **[x] ① 已修复** — commit `<填>`
  - TODO-090 键映射：`video_player_shortcuts.dart` 普通 `arrowLeft`/`arrowRight` 改绑 `seekBackward`/`seekForward`
    （时间 seek ±seekSeconds 秒）；新增 `Ctrl+arrowLeft`/`Ctrl+arrowRight` 绑 `previousSubtitle`/`nextSubtitle`（句子 seek）。
  - TODO-085 上句太远回退 Xs：`video_player_controller.dart` 新增纯函数 `prevSeekDecisionFor`
    （`cues/currentCueIndex/positionMs/seekSeconds` → `PrevSeekDecision`：近则跳句、`gap > seekSeconds*1000` 则
    退化成回退 `seekSeconds` 秒、首句则 none）+ 三态值对象 `PrevSeekDecision` + 方法 `skipToPrevCueOrSeekBack`。
    `video_hibiki_page.dart` 的 `previousSubtitle`（Ctrl+←）改走 `skipToPrevCueOrSeekBack(seekSeconds: _asbConfig.seekSeconds)`。
  - 不动底栏「上一句/下一句」按钮（仍纯 `skipToPrevCue`/`skipToNextCue`，按钮语义不退化）；不破坏 TODO-096
    (BUG-176 句子 seek 不打回原点)/060(字幕调轴走设置面板)/044(上下方向键=音量)。
- **[x] ② 已加自动化测试** —
  - `test/media/video/video_player_shortcuts_test.dart`：普通箭头→seekBackward/Forward、Ctrl+箭头→previousSubtitle/nextSubtitle。
  - `test/media/video/video_player_controller_test.dart`：`prevSeekDecisionFor` 8 例（近跳句/远回退Xs/gap远退化/阈值边界
    恰好等于仍跳句/首句none/空列表/seekSeconds<=0防御/值相等性）。
  - `test/media/video/video_player_keyboard_static_test.dart`：源码守卫更新为 TODO-090/085 新契约
    （普通箭头=时间 seek、Ctrl+箭头=句子 seek、Ctrl+←走 skipToPrevCueOrSeekBack、阈值=seekSeconds 秒、> 才退化）。
- **备注**：真机未验（桌面键盘 ←/→/Ctrl+←/→ 实际播放需用户复测；测试宿主无 libmpv，`load()`/Player 构造即抛，
  故键盘交互走源码守卫 + 纯函数行为测试，与既有 video 键盘测试范式一致）。
