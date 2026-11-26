## BUG-5532 · danmaku-clock-resnap-stutter
- **报告**：2026-11-26（用户：弹幕自己本身还是一卡一卡的抽动着前进）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/video_danmaku_overlay.dart` `_smoothPositionMs`（修前 134–144 行）：播放器时钟约 200ms 才更新一次、到达时带不定延迟，旧插值每次真值一变就**硬重锚**到真值，再叠「只进不退」钳制——采样偏晚时外推值被钳在原地（弹幕停住若干帧），偏早时一下跳过去，每 200ms 一顿一跳。BUG-4852 修的是 raster 掉帧，这是时钟本身的抽动，两者独立。
- **[x] ① 已修复** — 画面位置改由一根按帧间隔 × 速率自由运行的平滑时钟给出，真值估计（锚点 + 外推，最多外推 600ms 以免缓冲时空跑）与它的误差按 800ms 时间常数慢慢揉进去，小误差时修正量限幅 ±12% 速度；误差 >1s 视为 seek 直接对齐；暂停冻结且锚点帧时间随之前移。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_danmaku_overlay_test.dart`「scroll danmaku moves at a steady pace under a coarse, late player clock」：200ms 一跳、延迟交替 0/90ms 的时钟下逐帧位移必须 >0 且最大/最小 <1.5。
- **备注**：
