# 音乐逐曲断点续播（2026-11-06）

反馈 QAondMh4M5：纯音频从视频库改归音乐库（PR #2977）后，广播剧 CD 这类长音频不能丢续播。用户拍板「正常应该支持的就支持」。

## 结论

- **存哪**：`music_resume_points`（fushi_core Drift，schema v145），一首一行：`track_uid` 主键、`position_ms`（相对曲目起点）、`duration_ms`、`updated_at`。和播放流 `music_play_events` 同一身份，同在 Drift 库里。
  - 这里偏离了「Rust 胖核心」：音乐库的状态（曲库目录、播放流）全在 Drift，`native/fushi_music` 只负责扫描、标签、歌词、插件和 uid，没有任何存储。在 Rust 里另起一个存储，等于多出第二个音乐库存储，备份 / 迁移 / 软删都要再做一遍。这里只多一行持久化和一个纯函数判定，不新增 FFI。
- **从哪开始放**：直接复用视频的 `EpisodeStartIntent` / `resolveEpisodeStart` / `isEpisodePositionNearEnd`（`video_episode_start_policy.dart`；BUG-3491 规定「选条目」和「定起点」共用同一套判据），音频只换一个参数：
  - 列表点开、跳转、「下一首」、失败后重开都续播；「上一首」换曲、无缝 / 交叉淡入推进、拿不到流时的自动跳过一律从头。
  - 片尾区：视频是 ≥90%，音频用 `kAudioStartNearEndProgress = 0.98`。广播剧单轨常有 60 分钟，按 90% 算，停在最后 6 分钟再打开就会从头放。「剩余 ≤ 3 秒」这个下限两边共用。
  - 写入侧用同一判据：停在开头（≤ 0）或片尾区时直接删行，不留「读的时候也会从头放」的行。
- **门**：设置 `music_resume_mode`，可选 `off` / `long_tracks`（默认）/ `all`。长曲目指 ≥ 8 分钟或时长未知；歌曲每次从头放。
- **怎么起播**：`MusicOutputBackend.openPair(startAt:)` 只作用于「当前」那一首。mpv 在 `on_load` 里给播放列表第 0 项下发一次逐文件 `start`（`musicFileLocalWithStart`）：
  - 普通文件和 CUE 的 EDL 段直接写 `start`；
  - 音频 CD / 光盘章节在本曲的盘上起点上加 `startAt`。
  - 首开时没有前一首的尾巴，`start` 清设备缓冲这件事没有影响。
  - 单曲循环预排的下一首是同一个对象，所以这个起点不记进按 trackUid 键控的 `_fileLocalFor`。
- **恢复守护**（照搬视频 BUG-179 的思路）：起点落地前的位置是过渡值，不写。以下任一情况清除守护：
  - 位置追上目标（差 1.5 秒以内）；
  - 实际已经播了 10 秒还没追上（不可 seek 的流上 `start` 静默失效，照实记新位置）；
  - 用户自己 seek。
- **写入时机**（`MusicSession`）：
  - 在播时位置每变 5 秒写一次；没在播（暂停、暂停时拖动、播完）时位置每变 1 秒写一次。
  - 换曲 / 停止 / 重开时，引擎经 `onTrackLeft` 交出换下那首此前的精确位置，按它结算。恢复还没落地的不写。
  - 进后台（`AppLifecycleListener.onPause`，不经过 main.dart 里 Android 的早返回）和退出（`ExitFlushRegistry`：桌面关窗、⌘Q、detach 都会调 `flushAll`）时写穿。
  - 读断点前先等在途的写落库，所以切走马上又切回来能读到刚写的位置。
- **各平台一致**：五端都走同一个引擎和会话。系统媒体控件、锁屏、耳机键最后都调用 `engine.seek/play/skip*`。

## 不支持续播的来源

- Apple Music 整曲和电台：MusicKit 不能从曲内某处起播，能力表里 `startAt: false`，引擎不问断点，会话也不记。
- 服务器转码流：如果不能 seek，起点落不了地，由恢复守护兜底（见上）。

## 迁移

`video_audio_to_music_migration.dart` 把视频行里没看完的断点带过来。

- 整轨 + CUE 时，视频行记的是整个文件上的绝对位置。按它落在哪一轨的起点区间里（`musicTrackAtFilePosition`）找到对应曲目，再存相对那一轨起点的位置。播放记录也记在那一轨上。
- 已在片尾区的不写。库里如果已有同一首更新（或同刻）的断点，不覆盖，所以重跑幂等，也不会把位置倒退回去。

## 备份

`music_resume_points` 和播放流同属「音乐」类别。合并时同一首按 `updated_at` 取较新的一方。

删除不同步：听完就删行，没有墓碑。本机已删的行，合并一份更旧的备份后会回来，结果只是下次打开从那里接着放。

## 界面

- 设置 →「音乐」→「断点续播」：三档分段，走 `SettingsSegmentedItem`，自动进设置搜索。
- 曲目列表：有会被续播的断点时，行尾显示「剩余 m:ss」，副标题下加一条细进度条。进度条补间用 `FushiMotion.medium`，减弱动态效果时瞬间到位。
- 曲目详情：有断点时平铺「从头播放」（`playQueue(resume: false)`，断点留着，真正放起来后被新位置覆盖）和「清除播放位置」。
- ops：`music/player/play` 走 `playQueue`，同样会续播，描述已写明。没有新增 AI 写操作。

## 有意的取舍

- 连续播放下去的下一轨从头放：曾把第 5 轨听到一半，后来从第 4 轨连播下来，第 5 轨会从头开始。这和视频的 autoAdvance 一致。
- trackUid 含路径：文件移动或改名后断点对不上，这一点和播放流、歌单的表现一样。
- 在线插件 / 服务器曲目的菜单没有加「从头播放」项。这类曲目一样会续播，详情页入口只在本地曲目上。
