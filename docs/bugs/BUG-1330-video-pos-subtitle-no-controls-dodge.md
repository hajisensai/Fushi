## BUG-1330 · 带 \pos 的字幕不避让控制条、盖住暂停键

- **报告**：2026-08-01（用户：底栏出现时字幕不跟着移动；字幕层级比暂停键还高）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/media/video/video_subtitle_overlay.dart:1335`（旧 `\pos` 分支直接 `return Stack(Positioned(...))`）

### 复现片源真值

`[Nekomoe kissaten&VCB-Studio] Tensei Oujo to Tensai Reijou no Mahou Kakumei`，
`PlayResX 1280 / PlayResY 720`，OP 卡拉OK 每字一条独立事件（每集 175 条）：

```
Dialogue: 0,0:00:41.35,0:00:44.48,OP_JP,,0,0,0,,{\an7\pos(461,672)\fad(250,250)\blur2}手
```

`y=672/720 = 93.3%`，正是桌面进度条 + 按钮行那一条。控制条一出现就把整句 OP 歌词压在
底下；而字幕层在 Stack 里挂在 media_kit 控制条之上，于是歌词反过来盖住暂停/播放键。

### 根因

字幕层有两条互斥的定位分支：

- 锚点分支 → `_anchoredPadded` → `_paddingFor`：实现了「控制条可见时对 reserve 取下限」
  的避让契约（TODO-129/161、BUG-180/226/228/238/1069，产品语义是 **UI 赢重叠**）。
- `\pos` / `\move` 绝对定位分支 → 裸 `Positioned` + `FractionalTranslation`：
  `controlsVisible` / `controlsBottomReserve` / `controlsTopReserve` **一个都不参与**。

即避让契约被挂在了「定位分支」上，而不是「字幕层」上。定位方式是实现细节，避让是产品
契约，契约不该随分支消失——这是特殊情况分裂，不是缺功能。

`\pos` 的坐标映射本身没问题（按 PlayResX/Y 归一 + fit:contain letterbox 映射，已核）。

### 为什么不能用 `Positioned` 修

判断「盒底是否探进控制条带」需要**子盒真实尺寸**，而 `Positioned` 与
`FractionalTranslation` 都在布局前定位、拿不到尺寸。故改用 `CustomSingleChildLayout` +
`SingleChildLayoutDelegate`，在 `getPositionForChild(size, childSize)` 里定位与钳制一次算完。

### 修复

- **[x] ① 已修复** — commit `75e9ad012`
  - 几何真相源抽成纯函数 `resolveAbsoluteCueOffset()`（`video_subtitle_overlay.dart`），
    与 `_paddingFor` **严格同构**：取下限、不是加法、只单向移动。
    - 盒底越过 `height - bottomReserve` 才上抬（`math.min`，高位盒不被拽下）；
    - 盒顶越过 `topReserve` 才下压（`math.max`，低位盒不被顶上）；
    - 都不成立时坐标逐像素等于作者 `\pos`（招牌 / 画面中部特效外观不变）。
  - 控制条显隐用 `TweenAnimationBuilder` 在「作者位 ↔ 避让位」间插值，时长/曲线与锚点
    分支的 `AnimatedPadding` 同源（200ms / easeOut），两条分支跟手感一致。
  - `controlsVisible == null`（测试 / 有声书 / 无控制条）时避让进度恒 0，历史像素级不变。
  - **水平方向不做任何钳制**：横向出屏是另一个根因（`\fn@…` 竖排字体前缀未支持，见备注），
    钳到屏内只会把那个 bug 盖住。

- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_pos_dodge_test.dart`
  - 9 条行为测试用**片源真值**（`\an7\pos(461,672)`、1280×720 → 1080p）算，覆盖：隐藏时
    逐像素不变、可见时恰骑进度条上缘、取下限不加法、只上抬不下拽、顶栏对称、淡入淡出插值、
    x 不钳制、带高不足时顶部优先、`\an` 锚点换算。
  - 2 条源码守卫：`\pos` 分支不得退回裸 `Positioned` / `FractionalTranslation`；避让必须
    是 `math.min`/`math.max` 而非 reserve 加法。
  - 守卫已做**变异实测**（纪律要求）：① 去掉插值 → 插值那条真红；② 把分支退回旧的裸
    `Positioned` → 源码守卫真红。两次均反向替换还原，未用 `git checkout --`。
  - 回归：`test/media/video` 1993 条、`test/pages` 2484 条全绿。

### 备注

同一批用户报告里另外两条，已定性但**不在本次修复范围**：

1. **字幕列表全是单字**（图1）：不是 bug，片源就是每字一条 `\pos` 事件，列表 1:1 列事件。
   若要改善需在列表层把「同一行的逐字事件」合并回一句（新功能，非修 bug）。
2. **竖排歌词跑到屏幕左边外**（图3）：真 bug，独立根因——
   `{\fad(250,250)\blur2\fn@A-OTF Kaimin Tsuki Std H\an2\frz270\pos(10,360)}雨上がり…`
   里的 `\fn@` **`@` 前缀**是 ASS/GDI 的「竖排字体」约定（字形在字体内已预旋转 90°，配合
   `\frz270` 才得到「字正着、行竖排」）。`_resolveAssFontFamily`
   （`video_subtitle_overlay.dart:2244`）把 `@` 直接剥掉当普通字体名，竖排语义丢失，而
   `\frz270` 照转 → 整行躺倒、盒子几何错位到左边缘外。需单独立项支持竖排书写模式。
