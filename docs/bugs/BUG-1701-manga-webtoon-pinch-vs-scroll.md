## BUG-1701 · 手机端漫画条漫模式捏合缩放与上下滚动互相干扰
- **报告**：2026-08-17（用户：手机端漫画放大缩小好像跟上下滑动混了）
- **真实性**：✅ 真 bug。三条根因叠加，全在注入 WebView 的手势脚本
  `fushi/lib/src/media/manga/manga_overlay_html.dart` 里：
  1. **手势所有权**（`:1103` pointerdown / `:1127` pointermove，修复前行号）：捏合靠
     pointermove 里的 `e.preventDefault()` 挡原生滚动，但按 Pointer Events 规范
     pointermove 的 preventDefault **不阻止滚动**——滚动只由 `touch-action` 决定，且
     浏览器在第一个 touchstart 那一刻就按当时的值锁定手势。文档 CSS 只在框选模式
     临时设 `touch-action:none`，常规阅读是默认 `auto`，于是 webtoon 双指捏合与原生
     二指 pan 同时发生；滚动一接管，浏览器取消指针序列，`pointercancel` 处理器把
     `pinch=null`，缩放中途断掉。
  2. **纵向位置有两个拥有者**（`_zoomAbout` / `__mangaSetZoom`）：两模式共用
     `PAN_Y = innerHeight*(1-ZOOM)/2`。spread 是 100vh 定高视口，这是对的；webtoon 是
     竖滚文档，纵向本该只归 `window.scrollY`，多出的 PAN_Y 让每次缩放额外把整条长图
     平移一截——画面自己上下跳。
  3. **缩放后滚动坐标没换算**（`__mangaScrollToSpread` / `onMangaScroll`）：
     `offsetTop`/`offsetHeight` 是布局坐标，而 `#manga-canvas` 被 `scale(ZOOM)` 后
     scrollY 是视觉坐标（= 布局 × ZOOM）。定位与进度上报按比例错位，越往后错越多。

  另有同源的第四条：spread 放大后单指拖动被判成 swipe 翻页（`_end`），放大后根本
  无法平移查看页面各处，一拖就翻页。

  离线复现证据（stub DOM 跑真实生成的脚本，webtoon + zoom 150%）：修复前捏合把锚点
  下的内容位置从布局 1266 拽到 633（缩放直接把页面滑走一半）；`scrollToSpread(1,.25)`
  落到 1250 而非 1875；`onMangaScroll` 在同一位置回报 `fraction=1, topPage=0`（应为
  `fraction=0.25, topPage=1`）。修复后同一组断言全部通过。

- **[x] ① 已修复** — commit 见下。改法是消除「两套纵向坐标」和「两个手势拥有者」这两个
  特殊情况，而不是加分支：
  - CSS `html,body{touch-action:none;}` 全程生效，触摸手势归 JS 独占；框选模式里
    运行期切换 `document.body.style.touchAction` 的特例一并删除（对已开始的手势无效）。
  - webtoon 的 `PAN_Y` 恒 0，纵向唯一拥有者是 `window.scrollY`；缩放锚点补偿写回
    scrollY（`window.scrollTo(0, localY * ZOOM - ay)`）。`IS_WEBTOON` 声明前移到
    `_recenterPan` 之前——它在文档解析期就会被调用。
  - `__mangaScrollToSpread` 乘 ZOOM，`onMangaScroll` 把 scrollY 除回 ZOOM，两端与
    `offsetTop`/`offsetHeight` 同口径。ZOOM=1 时公式与旧版完全一致（存量进度不受影响）。
  - 原生滚动关掉后，webtoon 竖滚由 `_panBy` + `_startFlick`（惯性，每秒衰减到 0.2%）
    自己实现；惯性只给触屏，鼠标松手不继续滑。
  - `ZOOM>1` 时拖动一律是平移（`_panBy`），spread 的 swipe 翻页加 `ZOOM <= 1` 闸门；
    放大态翻页仍可用点击边缘 / 滚轮 / 音量键。

- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_overlay_html_test.dart` 新增
  group「BUG-1701 触屏缩放与竖向滚动的所有权」5 条守卫（touch-action 恒 none 且无运行期
  切换 / webtoon PAN_Y 恒 0 且 IS_WEBTOON 先于 _recenterPan 就绪 / 滚动坐标两端换算
  ZOOM / 自实现竖滚含惯性 / 放大态拖动不翻页）。5 条逐一变异实测均被杀死（变异后
  `FLUTTER TEST VERDICT: FAILED`，还原后源码 sha256 与基线一致）。
  `manga_rescan_overlay_contract_test.dart` 里断言旧 touch-action 切换的那条同步改为
  断言该特例已消除。`test/media/manga` 全目录 422 tests PASSED。

- **备注**：真机（手机）复测缺口未补——修复与证据都来自离线路径（node stub DOM 跑真实
  生成的脚本 + Dart 守卫）。webtoon 竖滚从原生改为 JS 自实现，惯性手感需要真机手感确认；
  参数集中在 `_startFlick`（衰减 0.002/s、停止阈值 40px/s、起飞阈值 80px/s）便于调。
