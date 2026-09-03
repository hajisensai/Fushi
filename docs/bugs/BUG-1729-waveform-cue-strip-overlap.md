## BUG-1729 · 波形对轴弹窗字幕条带重叠cue叠画
- **报告**：2026-08-19（用户：）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/subtitle_waveform_align_panel.dart:943-1034`（修复前行号）：`_buildCueStrip` 把全部 cue 平铺在同一行，每个 chip `Positioned(left, top: 0, bottom: 0, width)` 占满条带全高、x 只由时间决定——时间重叠的 cue（.ass 同屏双行/注音天然存在）直接叠画成一团。次要因素：`_minChipWidth = 48`（:398）把短句撑宽，低缩放下时间不重叠的相邻句也像素级假重叠。
- **[x] ① 已修复** — 贪心 lane 分配：新增纯函数 `layoutCueStripChips`（同文件末尾）对**整条时间轴**的 cue 按**撑宽后的像素区间**（而非原始时间）做贪心分行（维护每 lane 右缘、放进第一个放得下的 lane，封顶 3 行、超出挤末行接受叠画），像素判据顺带消掉假重叠；lane 表覆盖全部 cue、与滚动无关，视口裁剪只在建 widget 时做，滚动不跳行。chip 改 `top: lane * laneHeight, height: laneHeight`；条带高度随 lane 数伸缩（1 lane 保持 56 观感不变，多 lane 每行 38，chip 文本降为一行），外框高度跟随。产品行为对齐主播放器 overlay 的「重叠 cue 都要显示、竖排堆叠」（TODO-1312），不走只显一条。提交：见本分支 fix 提交。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle_waveform_align_panel_test.dart`：widget 守卫「BUG-1729: time-overlapping cues land on different strip lanes」（两条时间重叠 cue 的 chip 文本 top 不同且矩形不相交）+ 纯函数五用例（时间重叠分行 / 像素假重叠分行 / 不重叠同行 / 4 句互叠封顶 3 行末行共享 / 空文本不占 lane）。
- **备注**：既有守卫（chip 显示、拖条带调延迟、BUG-1486 播放头跟随）全部保持通过；单 lane 场景几何与修复前逐像素一致，零破坏。
