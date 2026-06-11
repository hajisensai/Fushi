## BUG-189 · 视频OP无字幕时按下一句字幕按钮不前进（用户感知「跳回开头」）
- **报告**：2026-06-11（用户：飞书 TODO-073「平板 OP 歌词没有字幕，按下一句字幕按钮跳转的话，直接就回到开头了」）
- **真实性**：✅ 真 bug（按钮链路 vs 键盘链路不对称）。沿真实代码路径定位：
  - **先证伪「跳回开头(seek 0)」的假设**：`VideoPlayerController.nextCueIndexFor`
    （`hibiki/lib/src/media/video/video_player_controller.dart:912-926`）在 OP（position 早于首句）时
    走 `_floorCueIndexByPosition < 0 → return 0`，再 `skipToCue(_cues[0])` seek 到**首句 startMs**。
    用真实龙女仆 S01E01 字幕实测：首条 cue 在 **38456ms**（OP/片头 0..38456 无字幕）。所以「有字幕 + OP 早于首句」
    按下一句是**前进到 38456ms**，并非 seek 到 0——这是 BUG-176(TODO-096) 已修的正确行为（gap 二分定位不回原点）。
    （实测脚本喂 pos∈{0,1000,10000,20000,38000} → 全部 nextIdx=0 → seek=38456，前进。）
  - **真根因 = 空 cue 列表时按钮无 fallback**：`hibiki/lib/src/media/video/video_player_controller.dart:848-857`
    的 `skipToNextCue()` 首行 `if (_cues.isEmpty) return;` → 直接 **no-op**。底栏「下一句字幕」按钮
    （`hibiki/lib/src/pages/implementations/video_hibiki_page.dart` 移动端 2088 / 桌面经 `_skipCueAndPokeControls` 2360）
    都直接调 `controller.skipToNextCue()`，**没有键盘 `nextSubtitle` 那条
    `controller.cues.isEmpty ? controller.seekRelative(_asbSeekMs) : skipToNextCue()`（1640-1642）的空字幕前进 fallback**。
    当这一集/这段 OP 没有可用文本字幕（字幕关 / 仅图形 PGS 轨 / 移动端内嵌字幕后台抽取尚未完成时 `_cues` 为空），
    按钮**毫无反应**，用户在 OP 里反复按、画面停在 OP 开头不动，**感知为「回到开头/卡住」**。
  - 数据所有权澄清：索引语义 `-1`(gap/无 cue 覆盖) vs `0`(第一句) vs `null`(无下一句/已在末句) 三态已由
    `nextCueIndexFor` 分清，不存在「无 cue 被误当索引 0」（那是 BUG-176 旧 `_currentCueIndex + 1` 的老问题，已修）。
    本 bug 是**空列表按钮 no-op** 这一缺失的 fallback，不是索引误用。
- **[x] ① 已修复** — commit `<填>`
  - 新增对称决策方法 `VideoPlayerController.skipToNextCueOrSeekForward({required int seekSeconds})`
    （`hibiki/lib/src/media/video/video_player_controller.dart`，紧邻已有的 `skipToPrevCueOrSeekBack`）：
    空 `_cues` → `seekRelative(seekSeconds*1000)`（前进 Xs 跨过没字幕的 OP，下界 clamp 同 `seekRelative` 不会变负/回 0）；
    有下一句 cue → `skipToCue`（同 `nextCueIndexFor` 决策，OP gap 里前进到首句）；
    已在末句之后(`next==null`) → no-op（保持原位，不强行前进越过片尾）。
  - 三处「下一句」调用点改走该方法，消除按钮/键盘不对称：键盘 `nextSubtitle`（原内联三元，纯重构同语义）、
    移动端底栏「下一句」按钮、桌面 `_skipCueAndPokeControls(forward:true)`。**上一句按钮不动**
    （仍纯 `skipToPrevCue`，按钮语义不退化，与 BUG-185 一致）。
  - 根因修而非补丁：把「无字幕前进 / 有字幕跳句 / 末句不动」三态收敛进一个与 prev 对称的决策方法，
    所有「下一句」入口共享，不在各调用点散落 `cues.isEmpty ? ...` 特例。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/media/video/video_player_controller_test.dart` 新增 group「TODO-073 OP 无字幕「下一句」不回开头」：
    ① 用真实 OP cue 结构（首条 38456ms）断言 OP 各 position 下一句 = 索引 0（前进到 38456，不回 0）；
    ② tick 同步 currentCueIndex=-1 后下一句仍前进到首句的回归；③ 末句之后 = null（保持原位）；
    ④ `skipToNextCueOrSeekForward` 空列表 / 有 cue 在无 player 宿主下安全 no-op、不把状态写回原点。
  - `hibiki/test/media/video/video_player_keyboard_static_test.dart` 源码守卫更新为 TODO-073 新契约
    （三处「下一句」入口都走 `skipToNextCueOrSeekForward(`，不再是裸 `skipToNextCue()`）。
- **备注**：真机/平板未验——测试宿主无 libmpv（`load()`/`Player` 构造即抛、`seekMs` 是 no-op），故核心 seek
  行为走纯函数 + 源码守卫 + 无 player 安全性测试，与既有 video 键盘测试范式一致。需用户在平板上复测：OP 无字幕段
  按底栏「下一句字幕」按钮应**前进 seekSeconds 秒跨过 OP**（不再停在开头），有字幕时仍正确跳下一句。
  base SHA：be2e9e966；分支 `codex/todo-073-no-subtitle-next-jump`；冲突组 video-controller。
