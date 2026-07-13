## BUG-791 · 安卓视频原生SubtitleView与可点浮层字幕重复(控制条显示时上下两条)
- **报告**：2026-07-14（用户：安卓视频，字幕；截图 OP staffroll 场景 00:06，外挂 .ass，所有视频都复现）
- **真实性**：✅ 真 bug。根因方向已定位（见下），**确切失效环节 + 修复验证需真机（当前 adb 无设备在线）**。
- **[ ] ① 未修复** — 需真机 logcat 定位是「字幕轨残留被选中」还是「visible 标志未生效」，再改并复测原始失败路径
- **[ ] ② 未加自动化测试** — 修好后加守卫（抑制序列 / SubtitleView 不渲染）
- **备注**：本条与草稿 PR#94 的 BUG-790 撞号，已手动改 791。

---

### 症状
安卓视频播放：**控制条隐藏时字幕正常（1 条）；控制条显示时字幕变成上下两条**（同一句文本）。
- 上面一条：**较大**、干净、随控制条出现被抬到画面中部（躲进度条）。
- 下面一条：**较小**、钉在最底部、被进度条/控制按钮盖住，不随控制条移动。

截图证据：两条字幕**字号明显不同** = 两个不同渲染器。桌面端不复现（安卓特有）。

### 验真过程（沿真实代码路径）
1. **浮层只有一个实例、只有它渲染 cue**：全仓 `VideoSubtitleOverlay(` 仅 `layout.part.dart:324` 一处，且已 wired `controlsVisible: _videoControlsVisible`（会随控制条上抬）。唯一消费 `activeCues` 渲染的组件就是它（`video_subtitle_overlay.dart:478`）。
2. **数据层无重复**：用 app 的 `AssParser.parseString` 解析用户真实文件（`Shunkashuutou…S01E08…ToonsHub.ass`），6000ms 处**只有 1 条 cue**（`ああ　四季庁よりも2人の意思を\N優先するよう動いてくれ`，`Text_JP` 样式 Alignment=2 底部、MarginV=30、无 `\pos`），全片仅出现 1 次。单 cue → 单渲染（widget 测试证实一条底部 cue 正确避让、只出一个盒子）。
3. **下面那条是 media_kit 原生 `SubtitleView`**：
   - `libass = false`（media_kit 默认 `platform_player.dart:526`，Hibiki 构造 `Player()` 从不设 libass，`video_player_controller.dart:1257-1263`）→ libmpv **不**把字幕烤进纹理。
   - fork `third_party/media_kit_video/lib/src/video/video_texture.dart:450-460`：`SubtitleView` 仅在 `subtitleViewConfiguration.visible && !libass` 时渲染，且**位于 controls（Hibiki 浮层）之下**（`:461-463`）。z 序、字号差、"随控制条上抬的是上面那条浮层、下面那条不动" 全部吻合。
   - `MaterialVideoControls` 不自渲染字幕（只 `shiftSubtitle` 改 padding，且 `shiftSubtitlesOnControlsVisibilityChange` 默认 false，`material.dart:759`）——排除控制条自带字幕。
4. **`SubtitleView` 出字的必要条件**：① `subtitleViewConfiguration.visible == true`（运行时）**且** ② `player.state.subtitle` 非空（= libmpv 里有被选中的字幕轨在吐 `sub-text`）。Hibiki 本应把 ① 压成 `visible:false`（`layout.part.dart:79`、`fullscreen.part.dart:140`）、把 ② 压成空（`setSubtitleTrack(SubtitleTrack.no())` + `sub-auto=no` + `sub-visibility=no`，`video_player_controller.dart:1413-1425`）。**安卓上没压住**。
   - 因为 `libass=false`，"下面那条能出字" 反证 **② 成立**：libmpv 里确有一条字幕轨被选中（该视频是 AMZN WEB-DL，含**内嵌**日文字幕轨；用户又外挂了 ToonsHub 同内容 .ass 走可点浮层 → 内嵌轨经原生 SubtitleView 冒出来 = 同句、异字号、双份）。
   - 外挂字幕**从不**交给 libmpv（无 `SubtitleTrack.uri`/`sub-add`，仅解析成 cue），故原生那条不是外挂、而是**视频内嵌轨**。

### 根因（方向已定，确切环节待真机）
抑制在 `load()` 里 `open()` 后**只下发一次**（`video_player_controller.dart:1413-1425`）。已知竞态（代码注释 `:1415-1421`）：内嵌字幕轨是 `open` 后**异步解析就绪**的，mpv 默认 `sub-auto=exact` 会自动选中。安卓上（容器解析时序不同）疑似出现：`setSubtitleTrack(no())`（1413）执行时轨列表尚未就绪 → no-op；轨随后就绪被自动选中；`sub-auto=no`（1422）只阻止**未来**自动重选、**不会反选已选中的那条** → 内嵌轨残留被选中，`player.state.subtitle` 持续非空，被（visible 未真正生效的）`SubtitleView` 渲染。

### 修复方向（待真机验证后落地）
根治点 = **强制"非图形字幕模式下 libmpv 字幕轨恒为未选中"的不变量**（把条件 ② 钉死，`SubtitleView` 自然不出字，与 ① 是否生效无关）：
- 订阅 `player.stream.track`，当选中的字幕轨非 `no()`/`auto` 且 `!_graphicSubtitleActive` 时，重下发 `setSubtitleTrack(SubtitleTrack.no())`（沿用 `_isCurrentLoad` use-after-free 双判据；注意 `selectEmbeddedGraphicTrack` 需在选轨**前**置 `_graphicSubtitleActive=true` 并在各早退路径复位，避免误反选图形轨）。
- 或最小改动：抑制序列在 `sub-auto=no` **之后**、等轨列表就绪再补一次 `setSubtitleTrack(no())`（非图形模式）关掉竞态窗口里被选中的轨。
- 该区域涉及 BUG-190/122/301 与原生 use-after-free 守卫，**盲改风险高**；必须真机复测原始失败路径（安卓 + 含内嵌字幕的视频 + 外挂 .ass + 显示控制条）+ 验证图形字幕（PGS）不回归。

### 待办
- [ ] 真机 logcat：确认是「内嵌轨残留被选中」（预期）还是「`subtitleViewConfiguration.visible` 未生效」；打印 `player.state.track.subtitle` / `player.state.subtitle`。
- [ ] 按上面方向根治并加守卫测试。
- [ ] 真机复测 + 图形字幕不回归。
