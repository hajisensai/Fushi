## BUG-599 · 视频buffered已满仍卡加载态
- **报告**：2026-07-07（用户：TODO-1297）
- **真实性**：✅ 真 bug（TODO-1276 首帧 gate 不完整）—— 根因
  `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:2381`（首开就绪判据
  `_videoReadyToShow = controller.hasFirstFrame`）+ `:1485`（promote 监听同样只判
  `hasFirstFrame`）。
- **[x] ① 已修复** — 提交 `PENDING`
  - 根因：TODO-1276（`bf29a7a43`）把首开页级加载层保持到「首帧解码出画」
    （`hasFirstFrame` = 视频宽/高均为正）再挂载 media_kit `Video`，以消除页级圈与
    media_kit 缓冲圈接力的「转两次圈」。但**首帧已解码 ≠ 可稳定起播**：网络流常在
    解码出首帧（宽高就绪、`hasFirstFrame` 翻真）时**仍在缓冲**（libmpv
    `paused-for-cache` / `core-idle`，media_kit `player.state.buffering=true`）。此时
    页面据 `hasFirstFrame` 提前挂载 `Video`，media_kit 自带缓冲圈接着盖住画面——正是
    TODO-1276 想消除的第二个圈，而进度条的已缓冲填充（`demuxer-cache-time`）此刻已
    可见 → 用户看到「进度条显示已经缓冲了、但还在加载」。页级加载层本身有 2.5s 兜底
    定时器不会永久卡住；持续「加载」的是 media_kit 缓冲圈忠实反映的 `state.buffering`。
  - 修复（`video_player_controller.dart`）：新增 `isBuffering`（读同一
    `player.state.buffering`）、纯函数 `readyForFirstPaint(w,h,buffering)=首帧已出画
    && !buffering` 与组合 getter `isReadyForFirstPaint`；新增**始终挂**的
    `_bufferingReadySub` 在缓冲态翻转时 `notifyListeners`（缓冲结束不一定伴随宽高/
    播放态变化，须独立驱动就绪重评），换集清理 + dispose 两处取消。
  - 修复（`video_hibiki_page.dart`）：首开就绪判据从 `hasFirstFrame` 收紧为
    `isReadyForFirstPaint`（快路径 `:2381` + 慢路径 promote 监听）。Hibiki 页级上下文
    加载层（`VideoLoadingOverlay`，带返回按钮、绝不困死用户）覆盖整个解码 + 缓冲窗口，
    直到有稳定帧且缓冲结束再让位给 media_kit → 单圈。2.5s 兜底定时器不变（始终不就绪
    的解码异常机型 / 纯音频容器 / 缓冲久拖不比现状更差）。换集（`!isInitialVideoOpen`）
    与全屏路由复用不改动（BUG-120/121 不受影响）。
- **[x] ② 已加自动化测试** —
  `hibiki/test/media/video/video_ready_for_first_paint_gate_test.dart`：锁死
  `readyForFirstPaint` 真值表（首帧+非缓冲=就绪；首帧+缓冲中=未就绪，即本 bug 场景）
  + 控制器缓冲订阅链路 + 页面首开就绪门控源码守卫。并同步更新
  `video_first_frame_gate_test.dart` 的页面就绪判据断言（`hasFirstFrame` →
  `isReadyForFirstPaint`）。
- **备注**：media_kit 视频无法离屏跑，就绪判据只能单测这层逻辑；真实「缓冲进度条填满
  即出画、无第二个圈」观感须真机复测网络流视频。若某内容出现 `state.buffering` 在
  cache 已满时**永久**卡 true（如 TODO-1280 分离流 audio-only 轨 403 永不就绪导致
  `paused-for-cache` 常驻），属独立的 mpv/流层问题，本判据（含 2.5s 兜底）不会更差但
  也不掩盖，需按具体内容单独复现。
