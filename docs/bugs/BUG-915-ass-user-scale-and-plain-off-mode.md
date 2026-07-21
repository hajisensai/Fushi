## BUG-915 · 尊重字幕不能调字号；关闭尊重时 ASS 特效层叠印乱字
- **报告**：2026-07-19（用户：截图为关闭「尊重字幕自带样式」后一行对白与特效层同位叠印成乱字；而开着尊重时字号滑块无效，「尊重字幕又不能调节大小」——用户被迫二选一）
- **真实性**：✅ 真 bug，两处根因（`hibiki/lib/src/media/video/video_subtitle_overlay.dart`）：
  1. **尊重模式字号不可调**：`_styleForGrapheme` 里 `cueFontPx != null` 时字号完全由 ASS 值换算，`widget.fontSize`（用户滑块）只在无 ASS 字号时作回退——滑块对 ASS 字幕零作用，没有 mpv `sub-scale` 那样的用户倍率通道。
  2. **关闭尊重叠印乱字**：respectAssStyle 关时**样式**统一但**位置不统一**——`_posScreen`/`_positionKey` 的 \pos/\an/Layer/MarginV 不受 respect 门控，而 \1a 透明填充、\fscx 缩放、字号、动画全被忽略。KFX/多层特效字幕（一句拆成多条同时事件、依赖透明层/逐段样式区分）被渲染成多份**裸文本**按作者坐标叠画 → 同位叠印乱字（用户截图）。半吊子「样式不尊重、位置却尊重」语义即病根。
- **[x] ① 已修复** — worktree-ass-size-outline-mpv-parity（叠加在 BUG-891 之上）：
  - 尊重模式：**完全按作者字号**（mpv 平价），用户字号滑块不参与 ASS 字号。曾按根因 1 实现 `assUserFontScale`（mpv `sub-scale` 倍率，commit 0886c2bd6），**2026-07-21 用户决策取消**（「调字号那个取消，尊重ass字号」）——尊重即尊重字号，倍率通道已整体回退，根因 1 按用户意图重新定性为「预期行为」而非缺陷。
  - 关闭尊重 = **纯字幕模式**（asbplayer 语义）：位置/层/边距语义整体归零——全部 cue 折进一个底部组（副字幕仍置顶），`_uniqueByText` 按文本去重（特效层拷贝只渲染一条），文本互异的竖排堆叠不叠印；`_positionCueGroup` 的 `ownMarkup` 按 respect 门控置 null，下游 \pos/\an/margins 全走「无位置信息」分支，零特例。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_ass_user_scale_plain_mode_test.dart`：①尊重模式作者字号基线（48@720→30）+ 用户 fontSize=60 不改 ASS 字号/描边（钉死「滑块不参与」决策）；②纯字幕模式同文本多层去重、\pos 顶部招牌落底部堆叠不叠印、respect 开时 \pos 不回归。旧断言依「定位属尊重语义」更新：`video_subtitle_dual_position_test.dart` / `video_subtitle_overlay_markup_test.dart` 的 \an 定位测试改显式 `respectAssStyle: true`。
- **备注**：行为变化（有意）：respectAssStyle 关时 \an8 顶部歌词/\pos 招牌不再按自带位置渲染，一律底部堆叠（开关默认开，关=明确选择统一简洁外观）。「调大小」诉求走关闭尊重的纯字幕模式（滑块在该模式下有效），尊重模式恒 mpv 平价。
