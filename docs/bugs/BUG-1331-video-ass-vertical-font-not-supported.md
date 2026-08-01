## BUG-1331 · \fn@ 竖排字体未支持导致整行躺倒出屏

- **报告**：2026-08-01（用户：「这左边的字都出去了」）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/media/video/video_subtitle_overlay.dart:2244`
  （`_resolveAssFontFamily` 把 `@` 前缀当噪声剥掉，无人承接竖排语义）

### 复现片源真值

`[Nekomoe kissaten&VCB-Studio] Tensei Oujo to Tensai Reijou no Mahou Kakumei`，
`PlayResX 1280 / PlayResY 720`（每集 OP 各一条）：

```
Dialogue: 0,0:02:00.02,0:02:09.36,OP_JP,,0,0,0,,{\fad(250,250)\blur2\fn@A-OTF Kaimin Tsuki Std H\an2\frz270\pos(10,360)}雨上がり　君は　君の目で答えを探してほしい
```

### 根因

GDI/VSFilter 约定：字体名以 `@` 开头 = **竖排字体**，其字形逆时针预旋转 90°（字顶朝左）
存储，而文本**仍按水平方向排版**。字幕组据此写出竖排的标准组合：

- `\fn@…` → 字形躺倒（逆时针 90°）
- `\frz270` → 整行顺时针 90°：行方向由水平变竖直（自上而下），字形同时被转回正立

两次旋转互相抵消，才得到「字正着、行竖排」。

`_resolveAssFontFamily` 剥掉 `@` 这一步**本身是对的**（DirectWrite 家族名确实不含 `@`，
不剥就查不到字体），但剥掉之后没有任何地方承接竖排语义；而 `\frz270` 照转不误 —— 于是
只剩下单向的 90° 旋转：整行躺倒，盒几何随之错位到画面左缘外。

### 修复

- **[x] ① 已修复** — commit `（见下方补记）`
  - 新增判据纯函数 `isAssVerticalFontName()` 与渲染侧 `_applyVerticalGlyphRotation()`：
    对 `@` 字体的**每个字形**绕自身中心逆时针转 90°（`Transform.rotate(-π/2)`；Flutter Z 轴
    视觉正方向为顺时针，取负与 `_applyAssTransform` 里 `\frz` 的取负同源）。
  - 关键取舍：**忠实建模「字形预旋转」本身，而不是新造一套竖排排版分支**。这样
    `\pos` / `\an` / `\frz` / `\fad` / 分组 / 逐字命中登记**全部照旧生效**，零特例分支——
    竖排是「字形属性」而非「布局模式」，按 ASS 原语义它本就该落在这一层。
  - 行内 `\fn` 优先于样式表 `Fontname`，与 `_styleForGrapheme` 的字体优先级同源。
  - 纯字幕模式（`respectAssStyle` 关）位置/样式语义整体归零，竖排一并不生效。

- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_vertical_font_test.dart`
  - 3 条纯函数判据 + 5 条渲染行为 + 2 条源码守卫，共 10 条。
  - 行为测试用**片源真值**（`\fn@A-OTF Kaimin Tsuki Std H\an2\frz270\pos(10,360)`）逐层
    累乘祖先 `Transform` 矩阵，断言字形轴向：`@`+`\frz270` → 净 0（正立）；只有 `@` →
    逆时针 90°；**无 `@` 的普通字体 + `\frz270` → 仍单向躺倒**（招牌类字幕既有语义不被改）。
  - 守卫已做**变异实测**：把方向写反成 `+π/2` → 3 条测试同时红（2 条行为 + 1 条守卫）；
    反向替换还原，未用 `git checkout --`。
  - 回归：`test/media/video` 2003 条全绿。

### 已知近似

`Transform.rotate` 不改变布局尺寸，而 GDI 竖排字形的 advance 是宽高互换的。CJK 全角字
（含全角空格）宽≈高，逐字盒几何几乎不变；`@` 字体本就是 CJK 竖排专用，混排窄拉丁字符时
会有半字宽级别的偏差，接受。

另：`\frz` 目前绕**盒中心**旋转（`_applyAssTransform` 的 `Alignment.center`），libass 绕
**对齐点/`\org`** 旋转。本条不改（既有招牌字幕依赖当前行为，且与本 bug 的躺倒无关），
差异体现为长文本旋转后有半个行高级别的位移。若日后发现旋转招牌位置偏移，从这里查。

### 相关

- BUG-1330：同批用户报告的另一条（带 `\pos` 的字幕不避让控制条），根因不同、已单独修复。
