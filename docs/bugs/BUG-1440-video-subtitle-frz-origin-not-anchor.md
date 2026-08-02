## BUG-1440 · \frz 绕盒中心而非 \an 锚点旋转，竖排整列左移出框

- **报告**：2026-08-02（用户：「这个左边出框了正常吗」+ 截图，OP 标题画面左缘竖排歌词被切掉左半）
- **真实性**：✅ **真 bug**。根因
  `hibiki/lib/src/media/video/video_subtitle_overlay.dart:1702`
  （旧代码 `Transform(alignment: Alignment.center, transform: m, child: box)`）。

### 片源真值

`[Nekomoe kissaten&VCB-Studio] … [10][JPN].ass`（`PlayResX 1280 / PlayResY 720`）：

```
Dialogue: 0,0:03:59.01,0:04:08.35,OP_JP,,0,0,0,,{\fad(250,250)\blur2\fn@A-OTF Kaimin Tsuki Std H\an2\frz270\pos(10,360)}雨上がり　君は　君の目で答えを探してほしい
```

`@` 竖排字体 + `\frz270` + `\an2\pos(10,360)`：字形与整行两次旋转抵消成「字正着、行竖排」，
整列贴画面左缘竖向居中。

### 根因

BUG-1331 已经把 `@` 前缀的**字形预旋转**补上（字确实是正的），但 `\frz` 的**变换原点**还错着：
`_applyAssTransform` 一律用 `Alignment.center`（盒中心），而 VSFilter/libass 的 `\frz`/`\fscx`
绕的是该行的 **`\an` 对齐点**——也正是 `_absolutePositioned` 把盒子落到 `\pos` 时用的那个点
（`_AbsoluteCueLayoutDelegate` 的 `anchorFx/anchorFy`）。两处取了不同的点，旋转后整盒被平移。

`\an2` = 底边中点，与盒中心差半个行高 `H/2`。`\frz270` 把这半个行高从竖直方向转到水平方向：

- 正确：列落在 `x ∈ [10, 10+H]`（锚点右侧）
- 实际：列落在 `x ∈ [10-H/2, 10+H/2]`，`H/2 > 10` → 左半截溢出画面外

小角度招牌（`\frz15` 之类）差别看不出来，90°/270° 的竖排行才把它放大成「出框」。
`_absolutePositioned` 的注释里早写过「横向出屏另有根因」并特意不做水平钳制——钳了只会盖住
这个 bug，本条即是那个根因的剩下一半。

### 修复

- **[x] ① 已修复** — 变换原点改成本行的 `\an` 对齐点：
  `Transform(alignment: _alignFor(markup.anchor), …)`。
  - 复用既有的 `_alignFor(SubtitleAnchor?)`（无 `\an` 时回落底居中，与 ASS 默认
    `Alignment=2` 及 `_positionCueGroup` 里 `\pos` 分支的同名回落一致；解析层
    `anchor ?? cueStyle?.anchor` 已保证样式表 Alignment 会被带上）。**零新增分支**。
  - `\an5`（中中）的招牌本来对齐点就是盒中心，新旧同一个点，像素级不动。
  - `\fscx/\fscy` 与 `\fax/\fay` 共用这个 `Transform`，一并对齐到 VSFilter 语义
    （同样绕对齐点作用），方向一致。

- **[x] ② 已加自动化测试** —
  `hibiki/test/media/video/video_subtitle_vertical_font_test.dart` 新增
  「`\frz` 变换原点 = `\an` 对齐点」组 2 条（12 → 14 条）
  - 片源真值 `\an2\frz270\pos(10,360)`：喂 `debugVideoWidthOverride/HeightOverride`
    让 `\pos` 真正生效（不喂则 `_posScreen` 返回 null 回落锚点对齐，测不到绝对定位几何），
    容器 1280×720 == PlayRes 故断言可直写坐标；断言各字 `left ≥ 0` 且 `left ≥ 10`。
  - `\an5\frz30` 招牌几何不变——钉死这次改动不挪动居中锚点的既有行为。
  - **变异实测**：把 `alignment` 反向替换回 `Alignment.center`，「雨」的 `left` 实测
    **-8.125**（直接复现用户报的「左边出框」），该用例变红、`\an5` 用例仍绿；反向替换
    还原，未用 `git checkout --`。

### 备注

与 BUG-1331（`@` 字形预旋转）是同一现象的两半：1331 修「字躺倒」，本条修「列左移出框」。
与同批 BUG-1439（字幕列表链式合并）根因无关。
