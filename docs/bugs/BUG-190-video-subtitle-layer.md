## BUG-190 · 禁用 media_kit 内置 SubtitleView：字幕透明/查词坏/横竖屏残留黑字
- **报告**：2026-06-11（用户：TODO-080/092 任务A「视频字幕透明随机 / 点字幕落空呼出键盘 / 横竖屏切换残留黑底字」）
- **真实性**：✅ 真 bug（双层字幕渲染）。沿真实代码路径定位：
  - **双层渲染根因**：Hibiki 视频字幕的唯一真相是可点 `VideoSubtitleOverlay`
    （`hibiki/lib/src/pages/implementations/video_hibiki_page.dart:3397`，逐字符可点 + cue 同步 + 逐字查词）。
    但页面里两个 `Video(...)` widget（窗口侧 `video_hibiki_page.dart:3327` 区、全屏路由侧 `:1817` 区）
    都没禁用 media_kit 内置的 `SubtitleView`——它**默认 `visible:true`**，会监听 `player.state.subtitle`
    把 libmpv 解析的字幕渲染成一整块**不可点** `Text`（白字 + `0xaa000000` 半透明黑底），叠在可点
    overlay 之上。后果：① 点字幕字穿透到 media_kit 自己的手势层 → 触发暂停而非查词、落句首词 / 呼出键盘
    （080-3）；② 字幕轨异步刷新时 `SubtitleView` 时有时无 → 随机透明（080-1）；③ 横竖屏切换 `Video` 子树
    重建时残留黑底（092）。
  - **libmpv 异步重选轨竞态（第二层）**：`VideoPlayerController.load`
    （`hibiki/lib/src/media/video/video_player_controller.dart:415`）只在「调用那一刻」
    `setSubtitleTrack(SubtitleTrack.no())` 清掉选轨，但 libmpv 的字幕轨列表是 `player.open` 后**异步**解析
    就绪的，mpv 默认 `sub-auto=exact` 会在轨就绪后**自动重新选中**内嵌字幕轨、覆盖掉先前的 `no()`，再经
    `sub-visibility=yes` 渲染成画面像素字幕——这条画面字幕又喂给上面的 `SubtitleView` / 直接画在 vo 上，
    与可点 overlay 双重叠加。`setSubtitleTrack(no())` 一次性调用根本压不住后到的自动重选。
  - **数据所有权澄清**：字幕 cue 数据流（`setCues` → overlay）不受影响——外挂 sidecar 经
    `loadCuesForSource`→`controller.load(cues:)`→`setCues`（`video_player_controller.dart:378`）、内嵌文本轨经
    `_loadEmbeddedSubtitleIfNeeded`→`setCues`（`:536`）都仍喂 overlay。本 bug 只是 libmpv/SubtitleView 自己
    **额外**画了一层不可点字幕，禁用它字幕不会消失（overlay 仍在）。
- **[x] ① 已修复** — commit `631055df6`
  - **禁用内置 SubtitleView（两处）**：窗口侧与全屏路由侧两个 `Video(...)` 的 `subtitleViewConfiguration`
    都显式设成 `const SubtitleViewConfiguration(visible: false)`
    （`video_hibiki_page.dart:3327` 窗口、`:1851` 全屏路由）。全屏侧虽与窗口侧共享
    `videoViewParametersNotifier`，但不依赖隐式传播、直接覆盖，消除「全屏路由快照时窗口侧 didUpdate 尚未把
    配置写进 notifier」的时机竞态。`SubtitleView` 不渲染后，字幕只由可点 overlay 单层承载。
  - **根除 libmpv 自动重选竞态**：`VideoPlayerController.load` 在 `setSubtitleTrack(no())` 之后注入纯函数
    `buildSubtitleSuppressionProperties()`（`sub-auto=no` + `sub-visibility=no`，
    `video_mpv_config.dart`）——`sub-auto=no` 让 libmpv 永不自动选轨（根治异步重选），`sub-visibility=no`
    即便某轨仍被选中也不画画面字幕。
  - **图形 PGS 轨例外（保 BUG-122）**：`selectEmbeddedGraphicTrack`（`video_player_controller.dart:243`）
    选位图轨后注入 `buildGraphicSubtitleVisibilityProperties()`（只重开 `sub-visibility=yes`，`sub-auto` 仍
    保持 `no`——轨由代码显式选定，不交给 mpv 自动选）。图形字幕无文本 cue，必须靠 libmpv 画面渲染，是抑制的
    唯一例外。
  - 根因修而非补丁：把「禁内置渲染层 + 禁 mpv 自动选轨」收敛进 `load` 一处 + 两个纯函数 map，图形轨在其
    选轨路径自行重开可见性，不在各处散落特例。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/video/video_mpv_config_test.dart` 新增两 group（纯函数）：
    `buildSubtitleSuppressionProperties` 只发 `sub-auto=no`+`sub-visibility=no` 两个 key；
    `buildGraphicSubtitleVisibilityProperties` 只重开 `sub-visibility=yes` 且**不含** `sub-auto`。
  - `hibiki/test/media/video/video_subtitle_layer_guard_test.dart`（新增源码守卫）：
    ① `video_hibiki_page.dart` 两处 `Video` 都有 `SubtitleViewConfiguration(visible: false)`（正则计数 >=2）；
    ② `load()` 在 `no()` 后注入 `buildSubtitleSuppressionProperties()`；
    ③ `selectEmbeddedGraphicTrack` 注入 `buildGraphicSubtitleVisibilityProperties()`（BUG-122 例外）。
    撤任一改动转红。media_kit 无头不可用，故走纯函数 + 源码守卫范式（与既有 video 守卫一致）。
- **备注**：真机未验——`Video` 渲染层与 libmpv 属性注入需真实设备/播放器；横竖屏残留、点击穿透是时序 + 原生
  渲染产物，留用户在真机/平板复测：字幕仍正常显示（overlay）、点字幕能查词不呼键盘、横竖屏切换无残留黑底、
  图形 PGS 字幕仍可见。base SHA：d94197419；分支 `codex/todo-080-092-subtitle-layer`；冲突组
  video-page + video-controller。
