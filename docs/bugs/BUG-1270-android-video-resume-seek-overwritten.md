## BUG-1270 · 安卓视频进入后被踢回开头：恢复 seek 被 loadfile 覆盖
- **报告**：2026-07-31（用户：手机上进视频「进去就直接给我踢开头去了。明明在外面看着还是有显示我上次观看进度的……点进去一瞬间还能看到我原本进度的一帧，然后踢回开头」）
- **真实性**：✅ 真 bug，Android 模拟器 100% 复现。根因 `hibiki/lib/src/media/video/video_player_controller.dart` 的 `load()`——恢复位置走「`open()` 之后再 `seek`」，而该 seek 会被 libmpv 尚未结束的 loadfile 流程按 `start`（默认 0）覆盖。

### 复现证据（Android 模拟器 emulator-5556，真实 libmpv）
`hibiki/integration_test/video_resume_seek_lands_test.dart`：90s 视频、`lastPositionMs=45000`，打开播放页后密集采样 8s 位置：

```
duration=90023
samples=[1746, 2716, 3742, 4004, ..., 17404, 17574, 17886]
```

- `duration=90023` **完全正确** → `resolveEpisodeStart` 的 near-end 分支未触发（`45000/90023=0.5`，remaining 45s），解析出的目标必然是 `45000`，即 **seek 确实发出了**；
- 但位置从 ~0 单调递增到 17.9s，**全程从未到达 45s** → seek 没有保住。

用户「看到原本进度的一帧又跳回开头」正是这个过程的肉眼表现：seek 让 mpv 渲染出断点那一帧，随后 loadfile 收尾把播放位置定位回 `start`（0）。

### 根因
- **数据流**：`VideoHibikiPage._loadSingle` 读 `VideoBooks.lastPositionMs` → `_applyLoad(initialPositionMs:)` → `VideoPlayerController.load()`。DB 侧完好——已核过全部写入点，打开视频时没有任何路径会把 `lastPositionMs` 清零（`upsertVideoBook` 是 `DoUpdate` 按列 upsert，`updateVideoBookPosition` 是单列 update）。这解释了用户「外面还显示上次进度、进去却从头」为何不矛盾：**DB 是对的，是播放器没保住 seek**。
- **缺陷**：`load()` 用 `_waitUntilSeekable`（等 `duration > 0`）当作「可以 seek 了」的判据，然后 `player.seek(target)`。但 media_kit 的 `open()` 把真正触发加载的 `playlist-pos` 写在整个命令序列的**最后**（`media_kit-1.2.6` `lib/src/player/native/player/real.dart:228`，其前是 `stop`/`playlist-clear`/`playlist-play-index none` → `pause=yes` → `loadlist append`），**且不等它完成就返回**。`duration` 属性只说明容器头解析完了（media_kit 经 `mpv_observe_property('duration')` 推送，`real.dart:1574-1581`），不代表 loadfile 流程结束。此时发出的 seek 会被随后完成的加载按 `start` 覆盖。
- **为何 media_kit 给不出正确判据**：它 observe 的 19 个属性里（`real.dart:2458-2477`）**没有 `seekable`**，所以除了 `duration>0` 之外拿不到更好的信号——这不是随手写错，是被上游接口逼出来的。
- **与 BUG-179 的关系**：同一个洞。BUG-179 只给恢复守护补了有界宽限（避免 seek 失败时守护永久吞掉进度写入），**没有修 seek 落地本身**，其文档第 22 行自陈「根因仍需真机复测」。本次补上的正是那一步。
- **为何 Android 明显、桌面偶发**：桌面 libmpv 命令消化快，seek 常常赶在 loadfile 收尾之后；Android/模拟器主循环慢，必现。

根因 `file:line`（修复前语义）：`hibiki/lib/src/media/video/video_player_controller.dart` 的 `load()`——恢复位置在 `player.open()` **之后**才 seek，判据 `_waitUntilSeekable`（`duration>0`）不足以证明 loadfile 已结束。

### ① 修复
- **[x] ① 已修复** — 把「从哪开始」从**加载后的操作**改成**加载参数**，竞态窗口直接消失（不是加延迟/重试掩盖症状）：
  1. 新增 `applyMpvStartPosition(player, positionMs)` / `clearMpvStartPosition(player)` / `formatMpvStartSeconds(ms)`（`hibiki/lib/src/media/video/video_mpv_config.dart` 末尾），经既有 `native.setProperty` best-effort 范式写 libmpv `start` 选项；
  2. `load()` 在 `player.open()` **之前**按 intent 算出 `preloadStartMs`（`resolveEpisodeStart(..., null)`，该分支已把 `manualPrevious`/`autoAdvance` 归 0，不会给「本就该从头」的入口设 start）并下发 `start` → mpv 在 loadfile 时就定位到断点；
  3. open 之后用真实 duration 复核 near-end；`start` 是**全局选项**（换集/画质切档复用同一 `Player`），复核完立即 `clearMpvStartPosition` 复位，绝不让下一集继承上一集的起播秒数；
  4. near-end 复核翻转时（open 前按断点设了 start，真实 duration 显示已快看完）显式 `seek(Duration.zero)` 把 mpv 拉回开头，保住 near-end 语义；
  5. 非 libmpv 后端 `applyMpvStartPosition` 返回 false，**回退到既有的 open 后 seek 路径**，行为与修复前一致；`_restoreTargetMs` 守护与 BUG-179 的有界宽限全部保留（它挡的是「seek 未落地期间用过渡期小值覆盖真实进度」，与本修复正交）。
- 修复 `file:line`：`hibiki/lib/src/media/video/video_mpv_config.dart`（`formatMpvStartSeconds` / `applyMpvStartPosition` / `clearMpvStartPosition`）；`hibiki/lib/src/media/video/video_player_controller.dart:1120-1140`（open 前下发 start）、`:1205-1245`（duration 复核 + 复位 + near-end 拉回 0 + 回退 seek）。
- 提交：见分支 `worktree-video-resume-seek-race`。

### ② 测试
- **[x] ② 已加自动化测试** —
  - **真机行为门**：`hibiki/integration_test/video_resume_seek_lands_test.dart`（新增）。跑真实 libmpv：90s 视频 + `lastPositionMs=45000` → 打开播放页 → 密集采样 8s → 断言 ①恢复 seek 至少落地过一次（出现过 ≥40s），②落地后不得回落到开头（<5s）。Android 模拟器 emulator-5556 实测：

    | | `samples`（位置采样，ms） | 结果 |
    |---|---|---|
    | 修复前 | `[1746, 2716, …, 17886]` — 从 0 播，全程未达 45s | ❌ 红：「恢复 seek 从未落地」 |
    | 修复后 | `[46200, 46959, …, 63074]` — 从 46.2s 起播，无回落 | ✅ 绿：`All tests passed!` |

    两次 `duration` 均报 90023（正确），佐证失败与 near-end 误判无关，就是 seek 没保住。
    - 素材：Android 模拟器（x86_64）没有 FFmpegKit native 库，`generateTestVideo` 必失败，故测试优先读 `adb push` 到 `/sdcard/Android/data/app.hibiki.reader/files/resume_probe.mp4` 的预置素材（app 外部文件目录，无需存储权限），桌面/有 ffmpeg 环境仍自给自足。
  - **host 侧守卫**：`hibiki/test/media/video/video_mpv_start_position_test.dart`（新增，5 用例，进 CI 单测门）。`start` 值格式化 + **顺序契约源码扫描**：`applyMpvStartPosition` 必须排在 `player.open(` 之前、必须有 `clearMpvStartPosition`、near-end 翻转必须 `seek(Duration.zero)`。顺序一旦被后来的重构挪动，修复会静默失效且任何 host 侧行为测试都抓不到，故用源码守卫钉死。
- **变异实测**（守卫防假绿）：① 把 `applyMpvStartPosition` 调用挪到 `player.open(` 之后 → 「start 下发排在 player.open( 之前」转红；② 删掉 `clearMpvStartPosition(player)` 调用 → 「start 用完必须复位」转红。两次变异后均还原源码并复跑全绿。
- **备注**：headless 单测跑不了真实 libmpv loadfile，故行为验证只能落在集成测试；host 侧守卫只保顺序契约不保行为，两者互补。

### 相邻问题（本 bug 不含，另行跟踪）
用户同报「字幕记录也无了得重新选」。已排查并**排除**两条嫌疑：来源库重扫（`source_library_scanner.dart:583-586` 对已入库路径有显式跳过，且扫描全靠手动触发）、合集各集字幕不落库（`subtitle.part.dart:934/977/1004` 的 else 分支确实调了 `updateSubtitleSource`）。尚无确凿根因，待单独立项。
