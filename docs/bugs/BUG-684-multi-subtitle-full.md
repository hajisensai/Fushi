## BUG-684 · 视频多字幕降级:同锚点MarginV裹挟+副字幕硬拽顶部
- **报告**：2026-07-09（用户：）· TODO-1341（续 BUG-651）
- **真实性**：✅ 真 bug。BUG-651 修好了「同轨时间重叠、锚点各异」的双字幕定位（顶 vs 底），但用户复诉「为什么总要降级·2 条甚至 4 条都显示不全」。沿真实渲染路径 `hibiki/lib/src/media/video/video_subtitle_overlay.dart` 复现出**两处剩余降级**（overlay 覆盖字幕自带位置，非 mpv 式各就各位）：
  1. **同锚点不同 MarginV 被裹挟**：`_positionKey`（旧 `video_subtitle_overlay.dart:496-506`）只按 `\pos` 或 `\an` 锚点分组，**不含 MarginV**。OP/ED 里标题（`\an8` MarginV=60）与多行歌词（MarginV=150/240）同为顶部锚点 → 同键 → 被塞进**一个 Column** 贴着排（`_positionCueGroup` `Column`），丢掉各自 authored 高度。实测容器 H=450 时三条渲染在 dy 81/126/164（仅行高间距），而作者按 MarginV 意图的 dy≈31/68/106。
  2. **副字幕无条件拽到顶部**：`_positionCueGroup`（旧 `:534` / `:557-559`）对 `isSecondary` 恒 `posMarkup=null` + 强制 `\an` 顶部锚点，丢掉副字幕自带 `\pos`/`\an`。实测「自带 `\an2` 底部」的副字幕被渲染到 dy=81（顶部）而非其锚点位置。
- **[x] ① 已修复** — `git commit <TBD>`。`hibiki/lib/src/media/video/video_subtitle_overlay.dart`：
  1. **MarginV 纳入分组键 + 消费为竖直偏移**：`_positionKey` 追加 `:$mv`（`markup.cueStyle.marginV` 四舍五入；`\pos` 时不并入，`\pos` 覆盖 MarginV）→ 同锚点不同 MarginV 各成一组。新增 `_scaledMarginV`（MarginV × 显示区高/PlayResY，与字号/阴影同源缩放，夹 [0, 显示区高]）；`_paddingFor` 顶部锚点用缩放 MarginV 作 top 偏移、底部锚点取 `max(bottomPadding, 缩放MarginV)` 作基线再对控制条 reserve 取下限（**单调抬升**——绝不低于用户基线，保 TODO-129/161/238 控制条避让不回归；作者用大 MarginV 要更高时才抬）。MarginV 仅 ASS 非空（srt/vtt `cueStyle`=null），故 srt/vtt 几何像素级不变。
  2. **副字幕遵自带非底部位置**：`_positionCueGroup` 改判 `forceTop = isSecondary && !ownNonBottom`，`ownNonBottom = 自带 \pos || \an 顶部/中部`。自带底部/无位置（纯 SRT、`\an2` 对白）仍置顶避让主字幕底部对白（asbplayer 式上下分栏、不撞位）；自带顶部歌词/中部注释/`\pos` 招牌的副字幕遵其自带位置。副字幕也走 `_groupMainCuesByPosition` 分组（各遵自带位置）。
  - 主/副字幕重叠活动集本就全渲染（TODO-1312 `activeCues`/`secondaryActiveCues`，无条数上限），2/4 条同时活动都不丢弃；本次只修「位置降级」。修复后位置：主 dy 31/68/106/340（各就各位）、副字幕底部→顶部避让、副字幕顶部→遵其位。`video_subtitle_overlay.dart:474-1029`。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_multi_full_test.dart`（5 例）：① OP 标题+两行歌词按 MarginV 竖直分离（间距 >25px，不裹成一列）+ 四条同时活动全渲染；② 底部对白小 MarginV 不把字幕拽到用户基线以下（单调抬升无回归）；③ 副字幕自带底部→仍置顶不撞位；④ 副字幕纯 SRT→置顶（保 TODO-1312 语义）；⑤ 副字幕自带顶部→遵其位在上半屏。同步更新 TODO-161 源码扫描守卫 `hibiki/test/pages/video_subtitle_push_up_guard_test.dart`（`_paddingFor` 由等价三元改 `math.max` 显式取下限，仍非加法）。`flutter analyze`（含 test）No issues；`test/media/video` + 相关 overlay 守卫 70 例全绿、既有 dual_position / multicue 零回归。
- **备注**：
  - **底层限制（诚实标注）**：字幕**源**（可独立选轨/持久化）仍为 2（主 `_cues` + 副 `_secondaryCues`）。同一源内时间重叠的 cue 无条数上限、全渲染（2/4 条同显完整），但要同时挂 3~4 个**独立字幕文件/轨**（如 JP+EN+CN+罗马音各一文件）超出当前主+副模型，需扩成 N 源（选轨 UI + 持久化 DAO + `_syncCueForPosition` 多活动集泛化），非本次范围，留后续 TODO。
  - **跨层碰撞**：主字幕顶部组与副字幕顶部（都遵自带顶部）可能重叠（mpv 有碰撞检测、本 overlay 无）；honor 位置仍比硬拽更正确，属边界情况。
  - **运行时验收待用户**：真机导入 ASSx2/多字幕文件，播到 OP/ED 段确认标题+歌词各在其 authored 高度、副字幕各遵自带位置（widget 测试已证渲染几何，真机看观感）。
