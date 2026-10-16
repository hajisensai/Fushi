## BUG-3450 · 浏览器扩展字幕底板在全屏下与屏幕同高、缩放后整块上移飞出屏幕
- **报告**：2026-10-16（用户反馈 PwaXAbruCT：桌面端 anichan.to 字幕向上飞出屏幕；移动端全屏时底板高度调不了、一直与屏幕同高，一调整就整块上移甚至飞出屏幕，竖屏非全屏正常；希望参照 asbplayer 从定位机制上解决，不只给 anichan 加特例）。同轮追加：视频上的扩展悬浮按钮会乱飘。
- **真实性**：✅ 真 bug。真 Chrome for Testing 加载扩展，在 anichan.to 真站与本地复刻页上复现，三处根因叠加：
  1. **站点通配规则把底板撑成满屏高**：anichan 全屏时给全屏元素 `.wp-stage` 加 `.fs`，CSS 有 `.wp-stage.fs>*{height:100%;aspect-ratio:auto}`；覆盖层全屏时挂进全屏元素当直接子节点，`#fushi-subtitle-overlay` 规则（`tools/browser-extension/scripts/content-css-overlay.css` 的覆盖层规则块）没写 `height`，于是底板高 = 屏幕高（真站移动端 915×412 全屏实测：minHeight 33px，盒高 412px、top −78px）。底板是底边锚定、向上长的，所以整块飞出屏幕上沿。
  2. **缩放把手按「设想高」算底边**：`subtitle-panel.js` `overlayResizePointerMove` 用 `d.top + hpx`（hpx = 设置里的 min-height）当新底边。底板实测比 min-height 高时（上面的站点规则、或自适应缩放压到下限仍放不下的长句），多出来的那截全往上长：每缩放一次左上角就上移一截（真站桌面实测连续三次缩小：上缘 428→424→420→415）；全屏里实测高 = 屏幕高，一次就把 y 算成负数夹到 0。
  3. **坏位置全站共用且摆放时不设防**：位置存档 `subtitleOverlayPosition` 是全站共用的一份分数坐标，摆放（`placeOverlay`）只在拖动时夹取、摆放时不夹。一次在全屏里算出的 y≈0 之后在所有站点、包括非全屏，都让字幕长在视频顶缘上方——用户桌面录屏里 anichan 非全屏字幕底边恰好贴在视频顶缘、只露出最后一个词，就是这个状态。
  4. **（悬浮按钮 / 字幕「飘」）重摆只靠事件与轮询**：覆盖层是 `position:fixed`，只在 200ms tick 重摆；悬浮按钮只在 scroll / resize / 悬停 / 1 秒轮询时重摆。播放器尺寸或位置变了但没有 scroll / resize 事件时（剧场模式、SPA 换片、侧栏收起），二者停在旧位置直到下一次轮询。本地复刻页实测：切剧场模式后按钮偏 482–492px 持续到 300ms，字幕偏 (243, 162)px 持续 200ms；滚动后字幕第一帧偏 250px。
- **方案对比（现实现 vs asbplayer，2026-10-16 浅克隆只读核对 `extension/src/services/element-overlay.ts`、`entrypoints/video.content/video.css`、`common/settings/settings-provider.ts`）**：

  | 维度 | 改前 Fushi | asbplayer | 本次采用 |
  |---|---|---|---|
  | 几何基准 | `video.getBoundingClientRect()` | 同 | 同（不变） |
  | 挂载点 | 字幕：全屏元素 / `<html>`；按钮：全屏元素 / `<body>` | 非全屏 body；全屏时 video 祖先里第一个能被 `elementFromPoint` 点到的元素，退路全屏元素 / body | 两者统一：全屏元素（它本身是 `<video>` 时退回 `<html>`）/ `<html>`。不取 body（站点常给 body 加 transform / scroll-lock） |
  | 定位方式 | `position:fixed` | `position:absolute`，按 offsetParent 折算 + 滚动 | 视频在文档流里 → absolute（文档滚动由合成器跟随，不靠脚本追帧）；视频有 fixed 祖先（全屏 / 迷你播放器）→ fixed。包含块原点一律用同定位方式的零干扰探针量（含站点 transform 与滚动） |
  | 重算时机 | 字幕 200ms tick；按钮 scroll/resize/悬停 + 1s 轮询 | 1s `setInterval` + fullscreenchange + 一次 rAF | 共享 rAF 帧观察：每帧只读一次正片矩形，变了才回调；原有 tick / 轮询保留作兜底 |
  | 站点样式隔离 | 选择器只写了部分几何属性 | `!important` + 内联 style，不用 shadow DOM | 定位三项（position/left/top）写内联 `!important`；JS 不写的几何属性（height/max-height/min-width/right/bottom/margin/aspect-ratio/float/transform）在 ID 规则里 `!important`。不用 shadow DOM：覆盖层文字要走 content.js 的 caret 取词 |
  | 位置存储 | 视频盒分数坐标（x 中心、y 底边），全站一份 | 像素偏移（距视频底 / 顶 75px），按 profile 一份，不分站 | 保留分数坐标（全屏 ↔ 非全屏按比例不变，存档格式不变、无需迁移）；摆放时按实测高夹回视频内（坏存档只夹显示、不改写），缩放按实测高落底边 |
- **[x] ① 已修复** — `442e03bd97`
  - `tools/browser-extension/video-target.js`：新增视频锚定 `window.fushiVideoAnchor`——`overlayHost()` / `anchorMode()`（带 1 秒缓存）/ `placeAt()`（内联 `!important`）/ `watch()`（共享 rAF 帧观察）；`probeOrigin(parent, mode)` 泛化原 fixed 探针，探针几何也写 `!important`。
  - `tools/browser-extension/subtitle-panel.js`：`parentForOverlay` / `placeOverlay` 走视频锚定（`setOverlayPoint`）；`placeOverlay` 摆放后按实测高把底边夹到「视频顶缘 + 盒高」以下（`renderedOverlayHeight`）；缩放把手按实测高重落底边；覆盖层显示期间订阅帧观察（`watchOverlay` / `replaceOverlay`）。
  - `tools/browser-extension/player-controls.js`：悬浮按钮挂载点（`floatingHost`）、摆放（`placeFloatingButton`）走视频锚定并订阅帧观察（`watchFloating`）；从悬浮态切到站点控制栏时清掉内联定位。
  - `tools/browser-extension/scripts/content-css-overlay.css`：`#fushi-subtitle-overlay` 钉回几何默认值（见上表），`transform` 加 `!important`；重新生成 `vendor/content.css` 并同步 `fushi/assets/browser_extension/` 镜像。
- **[x] ② 已加自动化测试** — `tools/browser-extension/subtitle-overlay-resize.test.js`（「实测比 min-height 高时缩放仍钉住左上角、连拖三次不上爬」「存档 y≈0 摆放不探出视频顶缘且不改写存档」「content.css 覆盖层规则钉回几何默认值」，三条在改前代码上均红）；`tools/browser-extension/video-target.test.js`（挂载点、定位方式、placeAt 的滚动折算与 `!important`、帧观察只在矩形变化时回调且退订即停）。
- **验证（真 Chrome for Testing 153，单实例）**：
  - anichan.to 真站：移动端视口（915×412，dpr 2.625，触屏模拟）进全屏，改后底板高 23px（minHeight 21px），不再与屏幕同高；改前同条件 412px、上缘 −78px。
  - 本地复刻页（照抄 anichan 的 `.wp-stage` / `.plr` 结构与上述 CSS，全屏挂在 `.wp-stage`）与普通播放器页：滚动、剧场模式往返、SPA 换 `<video>`、播放器缩放、容器全屏进出、`<video>` 自身全屏进出，在动作后第 1 / 2 / 6 帧与 300ms / 1300ms 采样，字幕中心 / 底边与按钮位置相对视频的误差均为 0px（按钮显隐动画 `scale:0.8↔1` 造成的 ≤5px 是测量包围盒缩放，不是位移）；桌面全屏里连续三次缩放，底板左上角钉在 (480, 795) 不动。
- **备注**：CDP 合成输入在「设备模拟 + 全屏」下打不进页面（窗口级捕获监听也收不到），所以移动端全屏下的触屏缩放没有在真浏览器里驱动，靠单测 + 桌面全屏缩放覆盖。站点给全屏元素子节点写 `width:…!important` 这类会压过 JS 内联 width / min-height（底板尺寸）的规则时仍可能影响底板宽高——那两项必须让 JS 内联值生效，不能在样式表里 `!important`。移动端全屏时悬浮按钮（视频右上角）与抽屉把手（屏幕右缘）可能贴得很近，未改。
