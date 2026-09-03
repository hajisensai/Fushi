## BUG-1783 · 移动端章节标记与进度条基准分叉：标记层多套一层 SafeArea，刘海横屏下整排斜切错位

- **报告**：2026-08-23（用户：截图一张 + 「手机上的章节标记有问题」；安卓 debug rolling `12067-075d4f3`，横屏 2532×1170，`[VCB-Studio] Yuru Yuri [05]` 23:56）
- **真实性**：✅ 真 bug（纯移动端；桌面两条路径都恰好等价，从不暴露）

### 症状

进度条上方那排章节竖线整体对不上轨道：首章明显右偏、末章左偏，中间某处反而是准的。用户主观描述成「右边两条溢出轨道」，但像素数据不支持溢出——实测最右一条在 x≈2350，轨道右端在 x≈2478，是**被压在轨道内侧**。

### 根因

`fushi/lib/src/pages/implementations/video_fushi/chapter.part.dart:98`（修前）的 `SafeArea`。

标记层与 seek bar 轨道用了**两个不同的水平基准**：

| | 水平基准 |
|---|---|
| 标记层（修前） | `padding.left + 16 + f·(W − 32 − padding.left − padding.right)` |
| 真实轨道（vendored fork `third_party/media_kit_video/.../controls/material.dart:1210-1216` + `seekBarMargin`） | `16 + f·(W − 32)`，**不含任何安全区** |

误差 `Δ(f) = padding.left − f·(padding.left + padding.right)` 随比例线性变化——**不是整体平移而是仿射斜切**：左端右推、右端左拉、中间 `f = P_l/(P_l+P_r)` 处恰好蒙对。这正是它长期没被一眼看出的原因。

两个前提缺一不可，而移动端两个都满足：

1. **轨道恒零内缩**：fork 的真相源是 `_theme(context).padding ?? (isFullscreen(context) ? MediaQuery.padding : EdgeInsets.zero)`。Hibiki 的移动 / 桌面 controls theme 都没设 `padding` 字段，而移动端视频**永不进 media_kit 全屏路由**（BUG-221，`_toggleVideoFullscreen` 移动端 no-op），于是恒走 `EdgeInsets.zero` 分支。
2. **`MediaQuery.padding` 非零**：`fushi/android/app/src/main/res/values*/styles.xml:9` 全局 `windowLayoutInDisplayCutoutMode=shortEdges` → 画面画进刘海区，**横屏时 cutout 落在左 / 右短边**。Scaffold body 之上没有任何 SafeArea/removePadding，padding 原样到达标记层。

而 `SafeArea` 恒吃 `MediaQuery.padding`，只在「真的处于全屏路由」时才与上式等价。桌面窗口态 padding=0（SafeArea 空转）、桌面全屏走 media_kit 全屏路由（两边都吃 `MediaQuery.padding`）——**桌面两条路径恰好都等价，所以这个 bug 只在移动端存在**，与用户说的「手机上」吻合。修前注释（`chapter.part.dart:80-81`）写的「与 media_kit 控制条 padding 对齐，保证窗口 / 全屏两条路径都不错位」只在桌面成立。

**坐标反算佐证**：按错误基准反推 `padding.left ≈ 45` 逻辑 px 时，6 条线落在 `0:00 / 1:25 / 2:51 / 11:00 / 21:39 / 23:27`——序 + OP（86s，标准 90s）+ A パート + B パート + ED + 次回预告，教科书式动画章节表；按「无 bug」假设反推则是 `1:21 / 2:37 / 3:55 / 11:19 / 20:59 / 22:37`，**没有 0:00 章**（BD/TV remux 的 mkv 第一章恒为 `00:00:00.000`），且多出一个来路不明的 3:55。前者远更自洽。

**同源的第二处**：`_buildThumbnailPreviewOverlay`（同文件）有一模一样的 `SafeArea`，其文档声明「几何与章节刻度层同源」。它目前桌面 only 所以没暴露，但声明同源就不能两处各写一套。

**次要同源缺陷（一并消除）**：竖直方向 `band.bottom` 里的 `_videoBottomSystemInset()` 已经算过一次 `viewPadding.bottom`，`SafeArea` 又扣一次 `padding.bottom` → 系统栏可见时**双重计数**，标记会浮到轨道上方。同一个 `SafeArea` 拿掉后一并消失。

### 修复

- **[x] ① 已修复** — commit `<填>`
  - 新增纯函数 `videoControlsChromeInsets`（`fushi/lib/src/media/video/video_subtitle_style.dart`，与 `videoSeekBarTrackBand` 同处）：把 fork 的 `_theme.padding ?? (isFullscreen ? MediaQuery.padding : EdgeInsets.zero)` 收成**页面与测试同源的单一真相**，消掉「控制条侧和刻度侧各写一遍、迟早分叉」这个特殊情况。
  - 新增 `_isVideoFullscreenRoute` / `_videoControlsChromeInsets()`（`fushi/lib/src/pages/implementations/video_fushi/fullscreen.part.dart`）：刻度层是 controls Builder 的**兄弟**、拿不到 media_kit 的 Fullscreen InheritedWidget，只能经 `_videoControlsContext` 反查；移动端按 BUG-221 直接短路 `false`，避开「兄弟层在同帧早于 Builder 回调执行、只能读到上一帧 context」的时序依赖——移动端恰恰是唯一暴露面，不能让它的正确性挂在帧序上。
  - `chapter.part.dart` 两处 `SafeArea` → `Padding(padding: _videoControlsChromeInsets())`。
- **[x] ② 已加自动化测试** — commit `<填>`
  - `fushi/test/media/video/video_chapter_markers_test.dart` 新增 `videoControlsChromeInsets (BUG-1783)` 4 条：非全屏路由水平贡献恒零 / 全屏路由吃系统安全区 / theme 显式 padding 两条路径都以它为准 / **刘海横屏下刻度层与轨道左右边界逐像素相等**（把 bug 的数学形式直接写成断言，`f ∈ {0, .25, .5, .75, 1}` 逐点比对，而不是断言某个字面量存在）。
  - 同文件源码守卫新增一条：两个兄弟层（刻度 + 缩略图预览）都**不得**出现 `SafeArea`、且必须走 `_videoControlsChromeInsets()`。
  - **变异实测（双向）**：
    ① 把纯函数改成 `themePadding ?? systemPadding`（= SafeArea 语义）→ 2 条转红，含「逐像素相等」；还原后 `video_subtitle_style.dart` sha256 `b4ec1cba9520ec175974dc4eac9c4e3f46074006dab732aed4733ffd653ee157` 与变异前一致。
    ② 把刻度层 `Padding(padding: _videoControlsChromeInsets())` 改回 `SafeArea(` → 源码守卫那条转红；还原后 `chapter.part.dart` sha256 `bd2ea808b19f99d0d220a215611cff9fe52f16709d0a5eceaf5a3d89996d8cf2` 与变异前一致。还原后 18 条全绿。
  - **写守卫时踩到并已修掉的两个坑**（都真实红过，不是假设）：① 裸 `contains('SafeArea')` 会命中**修复自己的注释**（注释里必须解释「原本是 SafeArea」），故断言前 `maskComments`；② 用「下一个方法签名」做切片，会因两个 builder 的先后顺序而把整段剩余语料吞进 body，负向断言随即失效——改用 `methodBody()` 自己做花括号配对。

### 备注

- 「左边挤 3 条」不是 bug：无论按哪种基准反算，这三条都落在 0:00–4:00，就是「序 + OP + A パート」的正常密度。数据本身如此。
- 章节数据链本身没问题：`video_player_controller.dart:2259 refreshChapters()` 逐条读 libmpv `chapter-list`，交给纯函数 `parseChapterList`，时间戳是容器原值不经换算，且 `_refreshChaptersWhenDurationReady` 保证 `duration > 0` 后才读。
- **旧守卫为什么是假绿**：`fushi/test/media/video/video_chapter_markers_test.dart:239-268` 的源码守卫断言 builder 体里出现字符串 `left: 16` / `right: 16`——`SafeArea` 就叠在它外面，字符串照样命中。「看起来对齐了」的字符串守卫拦不住基准分叉，补测必须断言**两侧基准相等**而不是某个字面量存在。
