## BUG-679 · 分页多列图片挤压/溢出盖住相邻列正文（TODO-1285 图片复诉）

- **报告**：2026-07-09（用户复诉 TODO-1285：「每页列数还是不行·并且如果是图片的话会被挤压」+ 图）
- **真实性**：✅ 真 bug（图片部分）。**每页列数本身在 develop 已生效**（BUG-634 结论，本次用 headless Blink 复验：横排/竖排 × N=0/1/2/3 每屏真渲染 N 列，见 `tool/reader_pitch_headless/columns_per_page_proof.mjs` 全 PASS）；用户看到的「列数不生效」实为**整页插图溢出盖住相邻列正文**造成的视觉错乱。真根因 = 图片 max 约束用整 content-box 而非子列 → 多列时插图越界。

### 根因

分页多列(`pageColumns>=2`)时 CSS multicol 把「turn 轴」（横排=宽 / 竖排=高）切成 N 个子列（`reader_content_styles.dart:227 columnWidthForColumns` 均分子列宽，已生效）。但图片 max 约束在 JS 里恒按**整 content-box** 算：

- `hibiki/lib/src/reader/reader_pagination_scripts.dart`（修复前 4 处内联 + `_resetImageMaxVars`）：
  `--hoshi-image-max-width = floor(cs.w * ratio)`、`--hoshi-image-max-height = cs.h`，其中 `cs = _contentSize()` 返回**整** content-box（`body.clientWidth/Height − padding`，`reader_pagination_scripts.dart:2308/3112`）。
- CSS `img.block-img{ max-width/height:var(--hoshi-image-max-*); width/height:auto; object-fit:contain }`（`reader_content_styles.dart:435`）在 `.block-img-wrapper`(flex) 里。

后果：整页插图按**整页 turn 轴**（横排整页宽、竖排整页高）撑开，远超单个子列（N=2 时子列只有约半个 turn 轴）→ 图片溢出本列，横插图直接横跨两列**盖住相邻列正文**（headless 截图坐实：宽插图覆盖左列文字）。宽高比未变形，但用户观感 = 「图片被挤压/糊成一团」，且多列排版看似「不生效」。

headless Blink 实测（`Page.captureScreenshot`）：横排 N=2 + 1200×500 横插图 → 图片 912px 宽压在 469px 子列上、横盖左列正文（bug 复现）。

### 修复

- **[x] ① 已修复** — `hibiki/lib/src/reader/reader_pagination_scripts.dart`：新增共享 helper `hoshiReader._imageMaxBox()`（放进 `_sharedJs`，两 shell 共用），turn 轴的图片 max 改用**浏览器 used 子列宽** `getComputedStyle(document.body).columnWidth`（与 `getScrollContext` 读的同一权威真值：横排=子列宽、竖排=子列高），图片正好收进本列不越界；block 轴（横排=高 / 竖排=宽）仍用整 content-box（每列在 block 轴填满整页），不变。仅当 used 子列**明显窄于**整轴（`usedColW < turnFull - 1`，真 `pageColumns>=2`）才夹到子列；单列 / 连续 / VN（无 `column-count` → `columnWidth=='auto'`→NaN，或子列≈整轴）回退整轴、与旧 `cs.w/cs.h` 字节等价（零回归，不碰 TODO-729/753/792 分页几何、不引 BUG-169、不破 BUG-652 翻页不漏）。4 处内联 image-var（分页/连续 initialize+updatePageSize）+ `_resetImageMaxVars` 统一改走 `_imageMaxBox()`。
- **[x] ② 已加自动化测试**：
  - 渲染层 headless 守卫 `tool/reader_pitch_headless/image_multicol_fit_probe.mjs`：headless Chrome(=Blink) 复刻真实多列 CSS + `_imageMaxBox` 子列夹取逻辑，横排/竖排 × N=0/1/2/3 × 纵/横插图，断言**图片 turn 轴渲染尺寸 <= 子列 turn 范围（不溢出）+ 宽高比保持**；并跑「旧整-content-box 逻辑」牙齿对照（多列宽插图 turn 溢出子列 → 断言溢出，证明守卫有牙齿）。全 PASS。
  - CI 可跑的源码扫描守卫 `hibiki/test/reader/reader_image_multicol_fit_guard_test.dart`：锁 `_imageMaxBox` 存在、读 `getComputedStyle(...).columnWidth`、含子列门控 `usedColW < turnFull - 1`，且所有 `--hoshi-image-max-*` setProperty 都经 `_imageMaxBox`（无残留裸 `cs.w * ratio` 图片赋值）。

- **备注**：
  - 「每页列数不生效」本身非本次改动范围——develop 上横排竖排都真生效（BUG-634 五层验真 + `columns_per_page_proof.mjs` 复验）；本条只修图片越界（那才是用户实际看到的坏视觉）。用户更新到含本修复的构建即可。
  - 未碰 `reader_content_styles.dart` 的 ruby-position（BUG-673 已修）；只动图片 max 变量的 JS 计算源。
