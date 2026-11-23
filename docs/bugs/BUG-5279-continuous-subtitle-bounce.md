## BUG-5279 · 连续对白字幕交接时一句贴基线、下一句被抬高，上下跳动
- **报告**：2026-11-23（用户：连续字幕上下动——相邻对白一句贴基线、下一句被抬高一行，交替跳动）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/video_player_controller.dart` 的 `_syncRenderActivityToClock`（BUG-4352 引入的逐位置事件重算渲染集）把 125ms tick 才更新的 `_currentCueIndex` 当代表 cue 并进渲染集。相邻对白（前句 endMs == 后句 startMs，或间隔 < 一个 tick）交接时，时钟已越过前句句尾、tick 还没换代表——渲染集变成 `[前句, 后句]` 的幻影重叠。overlay 槽位表（`video_subtitle_overlay.dart` `_syncGroupSlots`）把后句排进前句上方的远端槽；前句离场后留在锚点侧做隐形占位，后句整句被顶高一行；下一句补回空出的锚点槽落回基线，于是一句高一句低。
- **[x] ① 已修复** — 时钟路径的代表 cue 改为按当前时钟重算（`_clockRepresentativeIndex`：`findCueIndex` 闭区间，末句无后继时仍保到 endMs）；只有主动跳转 snap 期间沿用 tick 的代表。句尾暂停待触发（已越过 endMs、下一拍 tick 会暂停并 seek 回句尾）时渲染集冻结在本句（`_subtitleEndHoldPendingAt`），不让下一句先闪上屏再被拉回——旧实现在这段 overshoot 里同样会把下一句并进来。「循环当前句」回绕待触发（`_shouldLoopCurrentCue`，下一拍 tick 回到本句句首）同口径冻结（合并审查补）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_explicit_pos_overlay_test.dart`：控制器级「相邻对白交接渲染集只剩后句」「间隔 < tick 时 gap 清空」「句尾暂停待触发时冻结」，「循环当前句回绕待触发时冻结」（合并审查补），以及 overlay 真布局「交接后后句盒底与单独显示时同一基线」。还原修复后这 4 条（含原「主字幕渲染集同样随位置更新」收紧后的断言）全红，修复后 11/11 绿（合并审查补循环用例后 12 条）。
- **备注**：真实重叠（后句 startMs 早于前句 endMs）仍按 libass 碰撞语义上下堆叠且在屏期间位置不变，这是设计行为、不在本修复范围。
