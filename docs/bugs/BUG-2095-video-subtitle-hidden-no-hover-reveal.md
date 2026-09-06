## BUG-2095 · 字幕隐藏后鼠标悬停/点击无法临时显形
- **报告**：2026-09-03（用户原话：「字幕隐藏了，鼠标放上去怎么让他显示啊」→「隐藏也能鼠标放上去显示」）
- **真实性**：✅ 真 bug（沿真实代码路径复现，widget 测试可断言）
- **根因**：遮蔽的两种视觉（`VideoSubtitleObscureMode` 的模糊 / 隐藏）被实现成两条**结构不同**的路径。

  `fushi/lib/src/media/video/video_subtitle_overlay.dart:989`（修前，base `55f19003b6`）在 build 期直接把活动集清空：

  ```dart
  final List<AudioCue> mainCues =
      widget.subtitleHidden ? const <AudioCue>[] : widget.controller.activeCues;
  ```

  活动集一空，该层就没有任何 widget 上树 —— 承载显形的 `MouseRegion`（`:1789` 一带）和点击热区
  （`Key('video-subtitle-reveal')`）随之根本不存在。所以隐藏态**结构上**不可能响应悬停：不是回调没接上，
  是屏幕上没有几何可供指针命中。模糊态之所以能显形，恰恰因为它「照常渲染 + 盖一层 `ImageFiltered`」，
  几何一直在。

  同一形态的三条派生问题（同一次修复一并收口）：
  - `_wrapInteractive`（`:1688`）对 `dragAdjustEnabled` **提前返回**，模糊的 `ImageFiltered` 因此被跳过
    （既有契约：拖拽调整模式内字幕保持清晰便于对位）。隐藏的 `Opacity(0)` 若挂在早退**之外**
    （`_positionCueGroup`），拖拽模式内隐藏字幕仍是全透明：用户拖一个看不见的盒子，连 `_wrapDragAdjust`
    那圈可拖指示边框都被 `Opacity` 吞掉，而松手会真写入新的字幕位置 —— 从「可见地坏」退化成「静默地改状态」。
  - `didUpdateWidget`（`:980`）复位显形态的判据只看 `blurEnabled`，隐藏态一次父级重建（视频页每帧都在做）
    就把刚悬停出来的显形态清掉。
  - 显形态是**一个 bool 承载两种来源**：悬停有确定的 `onExit`，点击没有（移动端无 OS hover，而显形热区在
    显形之后已撤下，让位给逐字查词）。点击置起的 true 只能等「本层活动集为空」才复位，台词密集、没有字幕
    空档的片段里一次误触就把遮蔽废到下一个空档，且用户没有任何点回去的手段。
- **[x] ① 已修复** — 两种遮蔽收敛成同一条路径「照常布局 + 遮蔽视觉 + 共享显形状态机」：
  - 隐藏的视觉是 `Opacity(opacity: 0)`（不绘制，但布局与命中几何照旧），与模糊的 `ImageFiltered`
    **挂在同一层**（`_wrapInteractive` 里 `dragAdjustEnabled` 早退之后）。「拖拽模式内不遮蔽」这条契约
    因此只有**一个**真相点（那次早退），不需要在别处补第二个特例分支。
  - 未显形时不登记查词命中（`registerHits: !hidden`）：一条数据判据同时掐掉字符 tap、glyph 命中吸收与
    选词光标目标 —— 「看不见的字不可查词」。
  - `didUpdateWidget` 的复位判据补上 `subtitleHidden` / `secondaryHidden`。
  - 显形态按来源分账：`_revealed`（悬停，`MouseRegion` onEnter/onExit + BUG-1068 的空集兜底）与
    `_tapRevealed`（点击，按「本层活动集换一轮」失效）。`_setRevealed` 新增必填 `byTap`，写错来源会让
    复位路径接不上。点击显形因此只豁免当前这句，误触的代价从「到下一个字幕空档」缩到「到下一句」。
  - 提交：`0d89233030`（`fushi/lib/src/media/video/video_subtitle_overlay.dart`）。PR #1191。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_hide_hover_reveal_test.dart`（20 条，
  全部按真行为断言，无源码扫描）：① 隐藏态保留几何但不绘制 ② 悬停显形 / 移开复原 ③ 点击显形且不误查词
  ④ 显形后恢复查词 ⑤ 主/副显形态互相独立 ⑥ 拖拽模式内 hidden / blur 都让位（含两条非拖拽反向基准）
  ⑦ 父级带不同 props 重建后显形态不被清（主/副各一条 + 「真关掉遮蔽才复位」反向守卫）
  ⑧ `registerHits` 门控的另外两条**不经过显形热区**的通道 —— 悬停查词内核 `VideoSubtitleHitTester.hitTest`
  与手柄选词光标 `caretAnchorEntry`/`caretEntryCount` ⑨ 点击显形只豁免当前这句 + 悬停显形跨句不被误清。
  另 `video_secondary_subtitle_obscure_test.dart` 的副字幕隐藏判据由「找不到文本」改为「被 `Opacity(0)` 包住」。
- **备注**：变异实测（唯一锚点替换 + sha256 逐字节还原）6 条全部被杀：`registerHits: !hidden`→`true`（被 ⑧ 杀）、
  `didUpdateWidget` 去掉 `!widget.subtitleHidden`（被 ⑦/⑨ 杀）、把 `Opacity(0)` 搬回 dragAdjust 早退之外
  （被 ⑥ 杀）、点击显形不随活动集换轮失效（被 ⑨ 与 BUG-1068 用例杀）、`didUpdateWidget` 不复位
  `_tapRevealed`（被 ⑦ 反向守卫杀）、把悬停记成点击来源（被 ② / ⑨ 杀）。
  「显形后再点一下收回」做不到：显形热区在显形后必须撤下（否则它盖在盒面上会吃掉逐字查词的 tap，
  而竞技场里先加入的识别器胜出、热区永远在字幕之上），所以 `onTap` 改 `!revealed` 是个恒为 `true` 的空操作。
  真正能撤销误触的是上面的「点击显形随活动集换轮失效」。
