## BUG-259 · 视频上/下一句字幕容易漏掉开头 0.x 秒（句首被关键帧吸附吃掉）

- **报告**：2026-06-14（TODO-316：视频按「上一句 / 下一句」字幕跳转时，常听到句子已经播了开头一小段——开头 0.x 秒被吞）。
- **真实性**：✅ 真 bug（句子跳转落点系统性偏后，不是偶发）。

### 根因（file:line）

`hibiki/lib/src/media/video/video_player_controller.dart`：

- `skipToCue`（旧 :901）→ `cueSeekTargetMs`（旧 :909-914）把目标点**精确**算成 `cue.startMs + delayMs`，**无前导余量、无取整**。
- 但 `seekMs`（:852）底下是 media_kit / libmpv 的 `Player.seek`，**不是帧精确**：它把落点吸附到最近的可解码点（关键帧），而吸附**几乎总落在请求位置之后**几十~几百毫秒 → 实际落点越过句首 → 句子开头被吃掉 0.x 秒。
- 雪上加霜：`findCueIndex`（`packages/hibiki_audio/.../json_alignment_parser.dart:120`）要求 `pos == startMs` 或 `startMs < pos <= endMs`，落在 startMs 前几毫秒返回 -1 当 gap；cue 状态只在 125ms tick 刷新，边界脆弱。
- **不是**精确 seek 减了余量，恰恰相反——是**完全没有**余量去吸收吸附偏差。

index 选择逻辑（`nextCueIndexFor` / `prevCueIndexFor`）本就正确，**未改动**。

### [x] ① 根因修复

给句子跳转加可调**前导余量**（pre-roll），让播放器吸附后可靠落在句首或略前：

- 新增常量 `kCueSeekPreRollMs = 180`（经验值，可调）。
- `cueSeekTargetMs` 改成保留 `@visibleForTesting` 的纯函数，新增两个**带默认值**的可选参数：
  - `preRollMs`（默认 0）：在 **cue 时间轴**上把目标点往前移，下界 clamp 到 0；
  - `prevCueStartMs`（可空）：前导余量减完后下界钳到「上一句起点」，确保再大的余量也**不会串回前一句**。
  - 算式：`target = max(0, cueStartMs - preRollMs)` → 若有上一句则 `max(target, prevCueStartMs)` → `(+ delayMs).clamp(0, 1<<30)`。逆变换（叠加 delay）在最后一步，与原契约一致。
- `skipToCue` 现传 `preRollMs: kCueSeekPreRollMs` + `prevCueStartMs: _prevCueStartMsBefore(cue.startMs)`（新增私有二分 helper，在升序 `_cues` 上求严格早于当前句的最后一条起点，无则 null）。
- **关键不回归点**：`preRollMs` 默认 0 ——字幕结束暂停 `_pauseAndSeekForSubtitleEnd`（用 `cueStartMs: cue.endMs`）等精确 seek **不传**余量，行为字节级不变（否则会把暂停点拉回句中）。只有 `skipToCue` 传非零余量。

未加「skipToCue 后主动 _syncCueForPosition 即时刷新」：跳转后我们故意落在**句首之前**一点，此刻 `findCueIndex` 仍返回 -1（gap），即时同步只会同步到「请求的 pre-roll 位置」（句首前）→ 仍是 gap，不仅无益还可能闪一下清空；真正命中由播放推进进入 cue 窗口后的 125ms tick 自然完成。故不加（保持简洁）。

提交：见本轮 `fix(video): add lead-in pre-roll to cue seek so sentence start isn't clipped (BUG-259)`。

### [x] ② 自动化测试

`hibiki/test/media/video/video_player_controller_test.dart` 新增 group `BUG-259 cue seek 前导余量（句首不被关键帧吸附吃掉）`（纯函数 `cueSeekTargetMs` 单测）：

- 默认 `preRoll=0` 行为不变（字幕结束暂停精确 seek 同语义）；
- `preRoll=180` 把目标点往前移到 9820（撤掉余量 → 请求句首 → 吸附越过句首漏开头，红）；
- 余量减出负值时下界 clamp 到 0；
- 上一句下界：`preRoll=500` 但上一句起点 9800 → 落点钳到 9800（不串回前一句）；余量没越过上一句起点时按余量落点；
- 前导余量与下界都在 cue 轴算完后**再叠加 delay**（逆变换在最后）；
- 负 `preRoll` 当 0（防御）；
- **回归守卫**：`kCueSeekPreRollMs > 0` ——若被改回 0（前导余量整体失效），此用例立即红。

红→绿已实测：把生产常量临时改 0，回归守卫用例红；恢复 180 后 group 全绿。`flutter test test/media/video/` 全量 550 通过（2 个需 libmpv 的用例 skip）；`flutter analyze` 改动文件 0 issue。

### 不回归

- 字幕结束暂停（`_pauseAndSeekForSubtitleEnd`）/ 调轴反变换 / `cue seek target is inverse of effective subtitle position` 既有用例全绿（默认 `preRoll=0` 保持原值）。
- index 选择（`nextCueIndexFor` / `prevCueIndexFor` / `prevSeekDecisionFor`）未触碰，相关 BUG-175/176/TODO-073/085/119 用例全绿。

### 残留风险

- **真机待验**：不同媒体容器/编码的关键帧间隔差异大，180ms 的吸收幅度需真机（桌面 + Android）实测确认句首不再被吃且没把太多前导静音/上句尾巴带入；`kCueSeekPreRollMs` 常量可能需按真机表现微调（已抽成单一常量，改一处即可）。
- 若某些极端容器吸附幅度 > 180ms，仍可能残留极小漏头——调大常量即可，下界「不早于上一句起点」会兜住不串句。
