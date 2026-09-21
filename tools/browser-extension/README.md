# Fushi 浏览器扩展（Fushi Reader Bridge）

在任意网页上用 Fushi 的词典查词、采集/加载流媒体字幕、批量制卡。扩展本身没有词典和
Anki 能力——一切经本机 Fushi 桌面 App 内置的 yomitan API server（默认
`http://127.0.0.1:19633`，HTTP + Basic auth）完成。**没有构建步骤**：纯 JS 散文件，MV3。

## 文件地图

| 文件 | 世界 | 职责 |
|---|---|---|
| `manifest.json` | — | MV3 清单；content script 注入顺序有语义（先桥后消费者） |
| `background.js` | service worker | 唯一网络出口：查词/制卡/字幕等所有 HTTP 请求 + 连接诊断 + 自更新执行 + 心跳 + Netflix 录制编排 |
| `content.js` | 隔离 | Shift 悬停查词、查词暂停、弹窗渲染/定位、高亮、挖词队列、字幕轨 provider（textTracks 收割 / DOM 采样兜底 / 整集拦截接收端）、Netflix/YouTube 批量制卡驱动 |
| `nested-popup-host.js` | 隔离 | 嵌套父子栈、子 iframe 定位、按层桥接、异步结果归属；只关闭根层时恢复视频 |
| `nested-popup.html/js` | 扩展 iframe | 每层独立的共享词典 renderer、选区、制卡和滚动状态；经专用 MessageChannel 与宿主通信 |
| `subtitle-panel.js` | 隔离 | 字幕轨状态控制器 + 视频覆盖层（鼠标经左侧拖柄 / 触屏按住整块挪位，位置按视频分数坐标存 `subtitleOverlayPosition`；右下角把手拖拽改底板大小、双击回随内容；点文字查词、鼠标在文字上拖是原生选区可复制；`subtitleOverlayBackground` 关掉只剩描边字）+ 外挂字幕安装 + 全轨时轴偏移 + 快捷键执行端；不渲染网页列表 |
| `i18n.js` + `locales/` | 隔离 + 扩展页 + SW | 界面多语言：`locales/en.js` 是源字典（同步装入），其余 16 种 `locales/<tag>.json` 按需 fetch；语言默认跟随 Fushi（见「多语言」） |
| `theme-palette.js` + `theme.js` + `theme.css` | 隔离 + 扩展页 | 调色板引擎（种子色 → 明暗两套 token、预设、自定义条目）+ 明暗/调色板唯一决议点 + 扩展自有界面的默认调色板（见「主题与颜色」） |
| `subtitle-style.js` | 隔离 + options | 视频上字幕外观设置（字体/大小/字重/间距/行高/对齐/颜色/描边/底板含宽高）→ 覆盖层 `--fushi-sub-*` 变量 + `applyBox` 宽高 + `fitTextInto` 自适应缩放（`--fushi-sub-fit`） |
| `study-tracker.js` | 隔离 | 网页视频沉浸时间：正片 `<video>` 播放时每秒把位置样本经 background 交给 app 记学习统计（见「沉浸时间」） |
| `side-panel.html/js/css` | 扩展页 | 浏览器原生 Side Panel 字幕列表；侧边栏内取词，默认把词交给宿主页用页面弹窗渲染（见「侧边栏查词跨出面板」），经 tabs 消息读取轨道并执行跳转/制卡/偏移，不把字幕列表注入网页 |
| `video-shortcuts.js` | 隔离 | 视频页快捷键判定（纯函数）+ 绑定；每个动作独立开关，动作交 subtitle-panel 执行 |
| `touch-lookup.js` | 隔离 | 触屏点按/长按查词：单指点正文=查词（默认开）、长按≈0.5s=查词（默认关）；复用 content.js 的 `fushiLookupAtPoint`，零新增查词链路，只认 touch 主指针，绝不影响鼠标行为 |
| `mobile-drawer.js` | 隔离 | 移动端字幕列表抽屉：安卓无 chrome.sidePanel，触屏视频页挂边缘 ☰ 钮 + 隐形手势带（点=开关、按住=拖宽自由停位）；横屏右挂仅全屏（页面态让位形态太杂已禁用）、竖屏底挂，内容为 iframe 内嵌 `side-panel.html?fushiEmbed=1`（选轨/跳转/偏移/制卡/查词全套复用）；全屏态压播放器让位并以 adopt 跟随其自重排，几何存 `mobileSubtitleDrawerGeom` |
| `player-controls.js` | 隔离 | 播放器内嵌字幕控制：把一颗 Fushi 按钮插进站点自己的控制栏（YouTube `.ytp-right-controls` / Netflix 全屏钮左侧），其余站点退回「悬停视频时右下角浮出」的通用钮；菜单是字幕开关（覆盖层 / 替代原生 / 全轨叠加 / 底色 / 隐藏）+ 字幕列表 + 时轴偏移 + 字幕外观快捷面板，全部写既有键或调既有执行端，不新增状态（见「播放器内嵌字幕控制」） |
| `netflix-bridge.js` | MAIN | Netflix 专用：JSON.parse hook 抓整集字幕 + 官方 player.seek（避开 DRM M7375） |
| `youtube-bridge.js` | MAIN | YouTube 专用：按 asbplayer 顺序读取播放器运行态 captionTracks（含 POT）→ Android Innertube → player response，并一次下载完整 srv3/json3 轨；只读、不改宿主 DOM |
| `stream-bridge.js` | MAIN | 通用流媒体字幕桥（asb 移植）：TVer / Bilibili.tv / Hulu JP / Prime Video 整集字幕拦截 |
| `THIRD_PARTY_LICENSES.md` | — | 随扩展分发的第三方版权与许可文本（当前含 asbplayer MIT） |
| `subtitle-adapters.js` | 隔离 | 纯函数字幕解析器：WebVTT/SRT、TTML、Bilibili JSON + Netflix 取词/标题 |
| `bridge-shim.js` | 隔离 | 垫掉 app 内 WebView 桥（`flutter_inappwebview.callHandler`）→ chrome 消息，复用 vendor/popup.js |
| `scan.js` | 隔离 | 取词纯函数（词窗扩展/句子抽取） |
| `self-update.js` | SW/options | 自更新决策纯状态机 + 状态文案（node 可测） |
| `connection-diagnostics.js` | SW/options | 连接六态分类 + 文案（纯函数，文案经 i18n 键） |
| `fushi-defaults.js` | SW/options | 安装助手写入的自动配置（host/port/token/build 指纹） |
| `offscreen.html/js` | offscreen | tabCapture MediaRecorder（Netflix 逐句回放录制） |
| `options.html/css/js` | options | 设置页：配色主题（跟随 Fushi / 预设 / 自定义编辑器）与明暗、语言、连接、字幕偏好、字幕外观（实时预览）、沉浸时间、查词框大小、逐动作视频快捷键、版本与更新卡片 |
| `popup-size.js` | 隔离 + 扩展页 | 查词弹窗尺寸盒的唯一决策器（纯函数）：扩展独立尺寸覆盖 + 视口不足时的收敛；页面弹窗与侧边栏弹窗共用 |
| `vendor/` | — | `popup.{js,css,html}`+`selection.js` = app 查词弹窗原样拷贝（上游 `fushi/assets/popup/`）；`dict-media.js` 允许扩展分叉；`content.css` 由生成器产出；`action-popup.*` 扩展独有 |
| `scripts/` | 开发 | `generate-content-css.mjs`（popup.css → 零特异性重根 content.css）、`sync-mirrors.mjs`（镜像同步） |

## 三份镜像与同步（改代码必读）

```
fushi/assets/popup/  ──(手动 cp，方向固定)──▶  vendor/popup.js 等四件套
tools/browser-extension/（真源，本目录） ──(node scripts/sync-mirrors.mjs)──▶ fushi/assets/browser_extension/（Flutter asset）
scripts/generate-content-css.mjs ──▶ 两处 vendor/content.css
```

- **任何改动后跑 `node scripts/sync-mirrors.mjs`**（或 `--check` 只校验）。`*.test.js`、
  `scripts/`、`README.md` 不进 bundle；`THIRD_PARTY_LICENSES.md` 必须进入 bundle 与安装目录。
- Dart 守卫（`fushi/test/build/browser_extension_*` 等 30+ 个）会把「两镜像字节一致」当
  最后防线，漏同步 CI 必红。
- 新增文件放本目录**平级**（或 `vendor/`）——`fushi/pubspec.yaml` 只声明了这两层 asset 目录。

## 安装（导入浏览器）流水线

1. 本目录随 app 以 Flutter asset 打包（镜像 `fushi/assets/browser_extension/`）。
2. app 扩展页「准备扩展」→ `browser_extension_installer.dart` 解压到
   `<appSupport>/fushi-browser-extension/`（改名前是 `hibiki-browser-extension/`；老用户浏览器仍按绝对路径指着旧目录，故旧目录存在时继续同步刷新），并把**当前 server 真值**（host/port/token）与
   **内容指纹 build**（全部文件排除 `fushi-defaults.js` 的 sha256 前 16 hex）写进
   `fushi-defaults.js` → 用户浏览器「加载已解压」后零配置可用。
3. 用户可在 options 页覆盖连接参数（chrome.storage.local 优先于内置默认）。

## 自更新流水线

```
app 升级
  └─ 启动时 refreshBundledBrowserExtensionIfStale()：磁盘副本指纹 ≠ 内置 → 整目录重解压（新 build）
浏览器侧（background.js + self-update.js 纯状态机）
  └─ SW 唤醒 / onStartup / onInstalled / 60s 心跳 / 每次查词响应 → 拿 server 下发的 extensionBuild
       decide(remote, local, reloadedFor, recording)：
         remote == local        → clear（清 stale 提示/角标）
         首见新 build           → chrome.runtime.reload()（从磁盘拉新；先置重注入标记）
         已 reload 过仍不一致    → stale：图标「↑」角标 + action-popup 提示 + options「版本与更新」卡片
         录制中                 → 跳过本轮（reload 会杀 offscreen 录制）
  └─ reload 后：fushiReinjectPending → 向已打开页面补注 content script（无需手动刷新）
可视化：options 页「版本与更新」卡片实时显示 当前 build / 自动更新状态 / 失效指引
        （self-update.js describeUpdateState，扩展自报版本走 /api/extension/status 请求体）
```

## 与 App 的通信（endpoint 速览）

全部 `POST http://<host>:<port>/api/...`，`Authorization: Basic base64('fushi:'+token)`。
查词 `/api/lookup/dictionary` · 单词音频 `/api/lookup/audio` · 制卡 `/api/mine` · 查重
`/api/duplicate` · 状态/心跳 `/api/extension/status` · 弹窗尺寸 `/api/extension/popup-size` ·
YouTube 整集字幕 `/api/youtube/captions` · 外挂字幕解析 `/api/subtitle/parse`。
服务端实现：`fushi/lib/src/sync/yomitan_api_server.dart`。

## 侧边栏查词跨出面板

Chrome 的 side panel 是浏览器自己的一份 web contents：**面板里的 DOM 画不出面板边界**，没有
CSS/JS 能突破。所以「侧边栏里的查词弹窗被那 ~400px 夹住」不是落点逻辑的问题，改落点永远
解决不了。唯一的真路径是把词交回宿主页：

    侧栏取词 → fushiSubtitleSidePanelShowLookup（tabs 消息，带该行精确时间窗）
      → subtitle-panel.js → content.js 的 fushiShowLookupFromSidePanel
      → fushiSendLookup（页面自己发查词） → 页面弹窗（Shadow host）

于是嵌套查词、发音、查重、制卡、「查词时暂停」全部沿用页面既有链路，与 Shift 划词同源。
几个必须成立的点：

- **落点跟着被点的那一行**：侧栏与宿主页是两个视口，绝对坐标没有意义，所以侧栏交的是
  `anchorRatio`（被点行在侧栏视口里的纵向比例），页面按自己的视口还原：横向贴右缘（紧邻
  侧栏），纵向落在那一行的高度上。固定糊在右上角会压住画面里正在读的文字。
- **锚点是权威的**：侧栏交来的词在宿主页上没有对应选区，`anchorRect.authoritative` 让
  `fushiRender` 跳过整段选区探测——否则 `highlightSelection` 的无选区兜底会把**上一轮**查词的
  bbox 当锚点，弹窗落到上一个词旁边、还会把那处重新点亮。
- **回落不可少**：宿主页没有内容脚本（`chrome://`、扩展页、标签正在跳转）时 tabs 消息拿不到
  回复，此时退回面板内那份窄弹窗——绝不能变成查不了词。设置页「查词结果显示在网页上」
  （`subtitleLookupOnPage`，默认开）关掉后也走这条。
- **关窗回执**：页面弹窗关掉（点页面空白 / 侧栏 Esc / 手动播放）时 content.js 定向发
  `fushiSidePanelLookupGone`，侧栏据此复位扫词去重键；没有它，鼠标停在同一个字上就永远
  重查不了。页面自身的 Shift 查词关窗**不**发这条。

- **关窗那一击不漏给站点**：Netflix 等把「点画面」当播放/暂停切换，用户点旁边只是想关弹窗，
  却连带把视频停了。关窗后在 capture 阶段截住紧随其后的那一个 click（不 `preventDefault`，
  聚焦/选区这些默认行为要留着）；没产生 click 时由定时器撤掉监听，不误吞后面的点击。
- **Esc 关弹窗**：页面弹窗此前根本不认 Esc。现在 capture 阶段先关窗并截住这次按键，站点自己
  的 Esc 处理不再同时发生。**全屏下的 Esc**（用户报「关查词框会连全屏一起退掉」）：Fullscreen
  API 全屏时浏览器进程先于渲染器用 Esc 退全屏，`stopPropagation`/`preventDefault` 都拦不住；
  正规出口是 **Keyboard Lock API**——有 `<video>` 的页面进全屏即
  `navigator.keyboard.lock(['Escape'])`，浏览器随即把单按 Esc 交给页面（长按 Esc 才退全屏）。
  分工由我们定：有弹窗 → 只关弹窗；没弹窗 → 我们代为 `exitFullscreen()`，单按退全屏体感不变；
  退全屏即 `unlock()`；popup.js 的模态（制卡操作单）开着时 Esc 归它。无该 API 的浏览器退回
  「弹窗一定被关掉、全屏照退」。守卫 `escape-lock-and-dedupe.test.js`。
- **同词不重查**（用户报「会重复查词」）：弹窗已在场且显示的就是这个词，再点它一次（Shift 悬停
  后顺手点、悬浮字幕自动查词后点、面板行连点）不重发请求也不重渲染；同词在途也不发第二笔。
  判据是 `fushiShownTerm`（渲染成功才置、关窗即清），**不是** `fushiLastTerm`（发起时就写、
  失败不回退）。关窗或换词照常查。

行为守卫：`side-panel-lookup-on-page.test.js`（两侧各一组，含落点跟随、锚点、回落、Esc、
关窗吞击、去重复位、点空白跳转）。

## 覆盖层：挪位、缩放、选区、底色

视频上的自绘字幕（`#fushi-subtitle-overlay`）是「文字层 `.fushi-subtitle-overlay-text` + 挪位拖柄
`.fushi-subtitle-overlay-grip` + 右下角缩放把手 `.fushi-subtitle-overlay-resize`」三个子节点。用户报「字幕无法选取复制」的根因有两处：拖动挪位曾
独占整块（鼠标在文字上一拖就 `removeAllRanges` 进入挪位），以及 tick 每 200ms 无条件
`fushiRenderCueText` 重建文本节点，刚拉出的选区立刻塌掉。现在：

- **鼠标**：文字上按下/拖动 = 浏览器原生选区（Ctrl+C 可复制），只有按在左侧拖柄（悬停时出现）
  才挪位；**触屏**没有拖选，整块仍可拖。
- **同一条 cue 不重建文本节点**（`st.overlayRenderedCue`），tick 只重摆位置。
- 拖选完松手的合成 `click` 不查词（`overlayHasNativeSelection()`），点两枚把手也不查词。
- **右下角拖拽改大小**（用户 2026-09-21，与查词弹窗右下角把手同一手势）：拖把手写的是
  `subtitleStyle.boxWidth/boxHeight`（与 options 两根滑杆**同一份真相源**，夹取都走 `boxFromPx` →
  同一组上下限）。覆盖层是「水平中心 + 底边」锚定的，而右下角把手该有的手感是「左上角钉住、
  右下角跟手」，所以一次拖拽同时改尺寸和位置（`subtitleOverlayPosition`），两者各自落进自己既有的
  真相源，不新增第三份尺寸存档。指针先夹进视频盒、百分比向下取整，底板永远不探出画面；
  拖得再小也只落到下限（宽 20% / 高 5%），绝不翻成「随内容」那个 0——**双击把手**才是回随内容。
  触屏没有 hover，挪位拖柄隐起来但缩放把手常显半透明（它是触屏上唯一的改大小入口）。
- `mousedown` 在覆盖层上 `stopPropagation`：站点把播放器上的 mousedown 当「点画面」，有的还
  `preventDefault` 把选区扼杀在起点。
- **底色**：`subtitleOverlayBackground`（options「字幕底色」，默认开）关掉 → `data-bare`，CSS 去
  底板/投影只剩描边字，像站点原生字幕那样不挡画面。
- **外观**（options「字幕外观」）：`subtitleStyle` 一个对象存字体 / 大小（基准字号百分比）/ 字重 /
  字间距 / 行高 / 对齐 / 文字色 / 描边（none·soft·strong）/ 底板颜色·不透明度·圆角·内边距·宽·高。
  `subtitle-style.js`（`fushiSubtitleStyle.normalize / toCssVars / applyTo`）把它翻成覆盖层根上的
  `--fushi-sub-*` 变量（默认项 removeProperty 交还 CSS），`content-css-overlay.css` 的
  `#fushi-subtitle-overlay` 每一项外观都读这些变量并带默认值；设置页预览走同一份 `toCssVars`，
  预览节点默认值与覆盖层逐项一致（守卫 `subtitle-style.test.js`）。
  底板**宽 / 高**（`boxWidth` / `boxHeight`，视频盒的百分比，0 = 随内容）是例外：覆盖层是 fixed
  定位、CSS 百分比只对视口算，所以不走变量——`boxPx` 按视频盒折 px、`applyBox` 写 `style.width` /
  `min-height`，`placeOverlay` 每次重摆调一次（宽仍受视口 `max-width` 夹）；预览拿舞台盒当视频盒、
  同一算法。覆盖层与预览都是 `display:grid; align-content:center; box-sizing:border-box`，底板高于
  文字时文字垂直居中，文字层 `.fushi-subtitle-overlay-text` 因此是块级网格项。
- **自适应缩放**（`boxAutoFit`，options「自适应缩放」，默认开）：底板**有高度**时，`fitTextInto`
  按实测内容把整句缩放到盒里刚好放下，倍率写成 `--fushi-sub-fit`（font-size 的 calc 里乘在
  `--fushi-sub-scale` 之后）。盒子越大字越大、越小一屏装下的内容越多，所以拖右下角调的是「大小 +
  可展示内容多少」一件事。几个关键点：可用高取**设置里的底板高**而不是实测高（applyBox 写的是
  `min-height`，内容一溢出盒子自己就长高了，拿实测高当分母永远判不出「放不下」）；换行是非线性的，
  所以迭代 + 已知区间二分而不是一次外推，收手后再验一次；压到可读下限（`FIT_RANGE[0]`）仍放不下的
  超长句**停在下限**，剩下的交给 `min-height` 长高，字一个都不裁；量不到内容（节点未排版）时
  什么都不改。每 200ms 的 tick 按「句子 + 底板像素」记忆，没变就一轮不跑（每轮都要读 `scrollHeight`，
  那是强制同步重排）；设置页预览调的是同一个 `fitTextInto`，所见即所得。
- **字体是下拉不是手填**（用户 2026-09-20）：三组——本机字体栈（`FONT_SUGGESTIONS`）/ Fushi 字体库 /
  自定义（只回显旧版手填过的值）。字体真源在 app 的自定义字体目录：background `subtitleFonts` 消息
  `POST /api/extension/fonts` 拿 `{fonts:[{id,name,family,ext}], recommended:[{name,nameJa,description,
  license,installed}]}`，每条字体拼上 `GET /api/extension/fonts/file?id=&token=`（token 在查询串，同
  dict-media 图片；端点带 `Access-Control-Allow-Origin: *`，因为 `@font-face` 是跨源加载）。库字体存的值
  是 `"family"`；覆盖层选了字体时 `subtitle-panel.js` 向 background 要一次清单并把全部库字体以
  `@font-face`（`fushiSubtitleStyle.fontFaceCss`）挂进 `<head>`——浏览器只为真命中的 family 取字节，
  全量声明零额外下载；options 预览同样挂一份。「字体库」清单 = app 的推荐字体表，`下载` →
  `subtitleFontDownload` → `POST /api/extension/fonts/download {name}`，app 自己跑多源回退下载并入目录
  （与 app 内视频字幕共用），完成后自动选中。app 没开：下拉只剩本机组、清单换成「需要 Fushi 正在运行」。
- **源码不得含 Unicode 非字符**：`utf8-shippable.test.js` 按 Chrome `IsStringUTF8` 口径扫所有会进包的
  文本文件（BUG-2610：正则里裸 U+FFFF 让 Chrome 报「不是 UTF-8」拒装整个扩展）。要表示这些码位一律
  `\uXXXX` 转义。

守卫：`subtitle-overlay-drag.test.js` 后半段、`subtitle-style.test.js`、`utf8-shippable.test.js`。

## 主题与颜色

- **调色板只有一处**：`theme.css` 的 `--fushi-*` token（浅色 `:root`、深色在
  `@media (prefers-color-scheme: dark) :root:not([data-theme="light"])` 与 `:root[data-theme="dark"]`
  两处）。`options.css` / `side-panel.css` 只把自己的局部变量别名到它，工具栏菜单与嵌套查词壳直接
  用它；页内浮层（抽屉 / 字幕覆盖层 / 拖放提示 / 排队 chip / toast）由 `generate-content-css.mjs`
  把 `theme.css` 的 `:root` 重根到那几个 `#fushi-*` 宿主再拼进 `content.css`——绝不落到宿主页
  `:root`。此前四个表面四套颜色（options 绿、侧边栏暖米色、工具栏墨绿、抽屉硬编码 cream）。
- **明暗决议只在 `theme.js`**：设置 `extensionTheme` = `auto`（默认，跟随系统）/ `light` / `dark`。
  扩展自己的页面装入即把显式值写成根 `data-theme`（auto 摘掉属性交给媒体查询）；页内浮层按
  `fushiTheme.resolve(fallback)`；抽屉根写 `data-theme`。
- **调色板选择与 Fushi 本体同一套模型**（`theme-palette.js` + `theme.js`）：`extensionPalette` =
  `fushi`（默认，`theme.css` 原样）/ `app`（跟随 Fushi：`background.js` 把查词响应的 app 配色按
  明暗镜像进 `appThemeMirror`）/ 七款预设（与 app `theme_notifier.dart` 同名同种子：
  `light-theme` … `black-theme`，自带出厂明暗，选中时一并写 `extensionTheme`）/ `custom:<id>`
  （`extensionCustomThemes` 列表，每项 `{id, name, seed, surface?, text?, neutral}`，对应 app
  `CustomThemeEntry` 的 seed / surfaceColor / fontColor / neutralDerived）。一个种子色按 OKLCH 阶梯
  派生浅色与深色两套 `--fushi-*`（hex），落成一条 `<style id="fushi-theme-palette">`：扩展页面写
  `:root` 明暗两块，宿主网页里只写 `#fushi-*` 浮层宿主（与 `generate-content-css.mjs` 同一份清单），
  绝不碰宿主 `:root`。默认 `fushi` 不注入任何 style。
- **查词弹窗**（`#entries-container`）不吃 `theme.css`：它的 `--md-*` 由 app 按当前主题下发
  （`browserExtensionThemeColors`）。auto 下弹窗跟 app 的 `--fushi-color-scheme`（现状，BUG-688）；
  显式 light/dark 时 `background.js` 把同一个值作为 `colorScheme` 提示带进
  `POST /api/lookup/dictionary`，app 按该明暗 `buildColorScheme` 生成配色返回，`data-theme` 与
  `--md-*` 永远同一明暗（否则就是 BUG-688 那种分裂）。旧 app 忽略该字段。选了预设 / 自定义调色板
  时，三处弹窗壳（`content.js` / `side-panel.js` / `nested-popup.js`）再经
  `fushiTheme.applyPopupPalette` 把 `--md-*` / `--text-color` / `--background-color` /
  `--fushi-card-bg-rgb` 等颜色项按同一款调色板覆盖，弹窗与设置页 / 侧边栏 / 字幕底板同色；
  `fushi` / `app` 下不动。

守卫：`theme-and-study.test.js`（决议、根属性、CSS 单一真相源、请求提示）、
`theme-palette.test.js`（预设/派生/自定义/注入范围/弹窗覆盖）。

## 多语言（跟随 Fushi）

- 引擎 `i18n.js`：`fushiT(key, {params})`；HTML 用 `data-i18n` / `data-i18n-html`（只给我们自己写
  的、含 `<kbd>`/`<b>` 的文案）/ `data-i18n-title` / `-placeholder` / `-aria-label`，扩展页面装入即
  `applyToDocument`（同时写 `<html lang dir>`，阿拉伯语 rtl）。各模块内的 `tr()` 在没装 i18n 的
  测试壳里退回键名不崩。
- **字典**：`locales/en.js` 是源（同步装入 content script / 扩展页 / SW，`importScripts`），其余
  16 种 `locales/<tag>.json` 按需 `fetch(chrome.runtime.getURL(...))`（列在 web_accessible_resources）；
  键集、占位符、`<kbd>/<b>` 标签集合逐键与英文一致，`i18n.test.js` 钉死，同时钉「HTML / JS 不再残留
  裸中文界面文案」。支持的 tag 与 app 的 Slang 清单（`fushi/lib/i18n/strings_<tag>.i18n.json`）一致。
  **新增文案**：先加 `en.js`，再逐个 json 补同键（守卫会红到补齐为止）。
- **语言决议**：`extensionLanguage` = `app`（默认）/ `browser` / 固定 tag。`app` 读 `appLocale`——
  `background.js` 从 `/api/extension/status` 响应的 `locale` 与查词响应的 `appLocale` 记下 app 当前
  UI 语言（心跳每 60s 一次，app 切语言 ≤60s 跟上）；拿不到（app 没开 / 旧 app）回落浏览器语言。
  `zh-TW/zh-Hant → zh-HK`、`pt → pt-BR`。
- 不翻译的东西：字幕轨 store key 里的 `外挂:` / ` (自动)` / ` →译` 前后缀（身份的一部分，改了会
  拆轨）；语言选项里的本地语名；console 诊断。

## 沉浸时间（视频，进 Fushi 学习统计）

`study-tracker.js` 只当一个「远端播放源」：正片 `<video>`（画面 ≥200×120、时长 ≥30s 或直播）播放
期间每秒、以及 play/pause/seeked/ratechange/ended 时刻，把
`{mediaKind:'video', mediaKey:'web:'+fushiVideoKey(), title, positionMs, durationMs, playing, speed, ended}`
经 background 的 `studySample` 消息 `POST /api/extension/study`（与 popup-size 同一鉴权；app 没开
时退避 15s）。**这里不算时长**：app 侧 `BrowserVideoStudyBridge` 为每个 mediaKey 建一个
`VideoWatchTracker + StudyClock`（显式记账、只计首次覆盖、覆盖并集按 `videoWatchCoveragePrefKey`
持久化），口径与 app 内视频页完全一致——回放 / 拖回 / 次日重看不计，切走标签仍在播照常计；`ended`
或 20s 无样本停表。YouTube 首页悬停预览、卡片预告片也是 `<video>`，尺寸/时长门把它们挡在外面。
总开关 `studyTrackVideo`（默认开）。

**字幕门**（`studyTrackVideoCondition`，默认 `fushiSubtitle`）：“有个视频在播”不等于沉浸——
没字幕的视频、或用户读的是站点自带字幕时，把时长计进去只会把沉浸曲线稀释成刷视频曲线。
三档（options 页下拉）：

| 值 | 什么情况计入 |
|---|---|
| `fushiSubtitle`（默认） | Fushi 抓到的整集轨或用户拖的外挂字幕**正在用**，且没被 Shift+H 藏掉 |
| `anySubtitle` | 这个视频有任何 Fushi 认得出的轨（含 DOM 采样 live 伪轨、按需加载占位轨） |
| `always` | 旧行为，任何正片都计 |

判据的唯一来源是 `subtitle-panel.js` 的 `window.fushiSubtitleStudyState()`：`showing` = 活动轨是
整集轨/外挂轨（非 live）且真有 cue；`any` = 这个视频在 store 里有任何一条轨。**不要直接数
`fushiEpisodeCues`**：Netflix 整集拦截会把几十种语言都拿进 store、`textTracks` 收割还会把 `disabled`
轨提权成 `hidden`，那个集合非空几乎恒真。门是**持续**判定的（每秒 + 设置/隐藏状态变化即判）：
字幕中途才到就从那一刻开表，中途关掉字幕立刻发 `ended` 停表（app 侧按 mediaKey 持久化覆盖并
集，停表再续不会重复计）。

守卫：`theme-and-study.test.js` 后半段（含字幕门四条）与 `subtitle-panel.test.js` 的状态出口契约两条。

## 字幕里的振假名

`<rt>` / `<rp>` / `<rtc>` 的内容**都不是正文**，只有 ruby base 是。两条采集路径都踩过这个坑
（用户报「振假名变成和文字一个层级」）：DOM 采样用 `textContent`（真实 DOM 的 textContent
**包含** `<rt>`），字符串路径 `stripCueTags` 只删标签保留内容——`<ruby>熱<rt>ねつ</rt></ruby>`
两边都变成「熱ねつ」，被污染的不止显示，查词、制卡 sentence、字幕匹配吃的都是这份 cue.text。
app 侧 `strip_html_tags.dart` 早为同一形状收过口（BUG-1161），扩展侧的正则判据逐条对齐它。

现在：`cue.text` 只有正文，读音单独留在可选的 `cue.ruby`（「正文段 + 可选读音」的序列）。
渲染由 `ruby-render.js` 一份实现负责，**字幕列表与视频覆盖层共用**。两条不变式：

- 段拼接恒等于 `stripCueTags` 的正文——畸形注音（`<ruby>漢<rt かん</ruby>` 这类缺 `>` 的输入）
  整行退回单段，宁可不画振假名，也不让「列表上看到的字」与「查到的词」分岔。
- 段与 `cue.text` 对不上时不挂 `ruby`：DOM 快照是整句，而逐字扩长被切行后 cue.text 只是后缀，
  照挂会把振假名标到别的字上。

点振假名不会查到读音：`vendor/selection.js` 的 `getCharacterAtPoint` 命中 `<rt>` 时经
`resolveRubyBase` 重定向到 ruby base。

## 查词后自动朗读

开关是 **app 的全局偏好**「查词后自动朗读」（`autoReadOnLookup`），扩展不另立一个——它随查词
响应下发（`data.autoReadOnLookup`），改一处三端一致。这个偏好此前只接了 app 内弹窗、app 外
瞬态浮窗和剪贴板面板三个表面，扩展是最后一个漏掉的（用户报「查词的时候单词音频没有自动
播放」）；而「同一个开关在一个表面生效、另一个完全无效」正是 BUG-1210 修过的病，所以补上时
**页面弹窗与侧边栏弹窗共用 `auto-read.js` 这一份**，不各写一份。

解析走点 ♪ 的同一条路径（`callHandler('resolveWordAudio')` → background → `/api/lookup/audio`），
播放走 popup.js 自己的 `playWordAudio`，音量、interrupt 语义和失败处理因此与手动点 ♪ 完全一致。
两条不变式：没有已启用的音频源就不空跑（那时连 ♪ 按钮都不渲染）；换词与关窗作废在途解析——
慢响应回来不得盖掉用户已经在看的那个新词。

## 字幕列表的点击分工

一行里三块区域各管一件事，互不抢：**时间戳**跳转、**文字**查词、**行内空白**跳转。
文字块占满整行宽度，点文字右侧的空白同样落在它身上，所以「点文字=查词」必须**取到词才**
`stopPropagation`；取不到词就把这一击让回给行的 seek。否则用户点空白既查不了词也跳不了，
只剩一条「未识别到可查词文字」的 toast（用户报「点击空白位置不会跳转到这句」）。

`lookupAtPointer(pointer, { explicit, announceMissing })` 的两个开关也是为此拆开的：`explicit`
（点击 / 按下 Shift）放行在途闸，`announceMissing` 才决定取不到词时是否提示——它们曾是同一个
参数，于是「点击」被迫既放行在途闸又必须弹那条 toast。

## 查词框大小（单一真相源 + 窄侧边栏自动收敛）

**尺寸真相源只有一个**：app 的 `extension_popup_max_width/height` 偏好（app 设置页「浏览器
扩展独立尺寸」开关 + 两个滑杆），经查词响应的 theme 变量 `--fushi-popup-max-width/height/zoom`
下发。**写入口也只有一条**：`POST /api/extension/popup-size {maxWidth,maxHeight}`——
① 页面弹窗右下角拖拽把手 ② 侧边栏弹窗拖拽把手 ③ 扩展设置页「查词框大小」，三处都发
background.js 的 `popupSize` 消息走它（app 侧统一 clamp 250-2000/200-1600 + 「拖即解锁」
`extensionPopupIndependentSize=true` + 只写扩展键）。扩展本地**不存**任何尺寸值；设置页
回显的是 content.js 每次查词镜像下来的 `popupSizeFromApp`（只读，不参与决策）。
边界常量 `FUSHI_POPUP_MIN/MAX_WIDTH/HEIGHT` 与 Dart 侧 `kLookupPopupMin/MaxWidth/Height`
逐个对齐，四条写入路径写同一个真值。

**窄侧边栏自动收敛**（`popup-size.js` 的 `fushiResolvePopupBox(theme, viewport)`，页面弹窗与
侧边栏弹窗共用）：侧边栏可以窄到 300px，而 theme 宽度是按 app 窗口定的，且这些 px 长度写在
CSS `zoom` **之下**——`zoom=1.4` 时 400px 渲染成 560px，连 `max-width: calc(100vw - 16px)`
这个上限本身也一起被放大，根本拦不住，右半边被 `overflow-x` 切掉。决策器把上限**折回基准
尺度**（渲染尺寸 = 基准 × zoom，故视口上限要 ÷ zoom）；压到最小可用宽度仍放不下时改压
zoom，让整窗等比缩小而不是切内容。侧边栏宽度可拖，`resize` 即重算。

行为测试 `popup-size.test.js`（含 zoom 折算的根因回归 + 「不得出现第二真相源」守卫）+
源码守卫在 `side-panel-performance.test.js`，均已变异实测。

## 字幕轨数据流（原生 Side Panel 零站点特例）

所有来源写同一个 store：`window.fushiEpisodeCues['${videoKey}|${lang}'] = [{startMs,endMs,text}]`，
新数据到达调 `window.fushiSubtitlePanelOnCues(key)`；Side Panel 通过扩展消息按需读取，不访问或
修改宿主网页 DOM。来源：
① Netflix 整集拦截（netflix-bridge）② 通用流媒体桥（stream-bridge，见下表）③ YouTube
播放器运行态完整 captionTracks（youtube-bridge；本地服务端仅作超时兜底）④ 原生
`video.textTracks` 收割 ⑤ DOM 字幕采样 live 轨兜底 ⑥ 用户外挂文件（`外挂:` 前缀轨）。
时轴偏移是**读取侧**的（store 永远存原始 cue），任意轨可偏移，会话内记忆。

### 用 Fushi 字幕替代站点原生字幕（`subtitleReplaceNative`，默认关）

YouTube 的自动生成（ASR）字幕在 DOM 里是**逐词滚动**渲染的——一句话要好几秒才凑齐，
`⑤ DOM 采样 live 轨` 采到的因此永远是半句，划词和制卡都跟着残缺。而 `③ youtube-bridge`
早就把整集 srv3 轨（`<p>` 段 = 整句）预取进 store 了，只是渲染侧默认不用它（站点自带轨
不叠加，免得双份字幕）。打开这个开关后：当前活动轨是整集轨时，用自绘覆盖层显示整句，
并让 `content.js` 藏掉站点原生字幕层。

判定在 `subtitle-panel.js` 的 `replaceNativeEffective()`，四个条件缺一不可（面板启用 /
覆盖层启用 / 活动轨非 `live` / 该轨真有 cue）——任一不成立立刻放回原生字幕，绝不出现
「原生藏了、自绘也没有」。执行在 `content.js`：遮蔽状态是**原因集合**而非 bool，
`'manual'`（Shift+H / 设置开关）藏原生 + 自绘，`'replace'` 只藏原生。
行为测试 `subtitle-replace-native.test.js`（9 条不变式已变异实测）。

### 工具栏弹窗里的「Fushi 字幕」开关（`subtitleOverlayEnabled`）

自绘覆盖层的总开关（外挂轨 / 替代原生 / 全轨覆盖层都经它出画）原本只在 options 页有一个
「在视频上显示外挂字幕」开关，看片中途想在 Fushi 字幕 ↔ 站点自带字幕之间切要跑一趟设置页。
现在点工具栏 Fushi 图标 → 页脚第一项「Fushi 字幕 开/关」直接翻同一个键（同一个
`chrome.storage.local` 键，options 页开关、视频页都经 `storage.onChanged` 同步）。关→开时
顺带把总门 `netflixSubtitlePanel` 打开——覆盖层受它门控，从没开过侧边栏的用户单开覆盖层
等于什么都不发生；开→关只翻自己。它**不是** Shift+H：关掉后回到站点自带字幕，一句都不看的
纯听力模式仍用 Shift+H / options「隐藏字幕」。行为测试 `popup-overlay-toggle.test.js`。

## 播放器内嵌字幕控制（`player-controls.js`）

字幕开关和字幕外观此前只有两个入口：跑一趟扩展设置页，或者记住快捷键——**两条都要求用户把眼睛从画面上挪开**。
现在站点自己的控制栏里多一颗 Fushi 按钮（图标下一行 开/关 直读当前状态），点开即就近操作：

| 菜单项 | 落到哪 |
|---|---|
| Fushi 字幕 | `subtitleOverlayEnabled`；关→开顺带打开 `netflixSubtitlePanel`，与工具栏弹窗**逐字同一份写法** |
| 用 Fushi 字幕替代站点原生字幕 | `subtitleReplaceNative` |
| 所有字幕轨都用扩展覆盖层显示 | `subtitleOverlayAllTracks` |
| 字幕底色 | `subtitleOverlayBackground` |
| 隐藏字幕 | 转发 `window.fushiToggleSubtitleHiding()`（状态归 content.js 独占，这里不写盘） |
| 打开字幕侧边栏 | `fushiSubtitleShortcut('toggle-panel')` |
| 时轴偏移 −0.1 / ⟲ / ＋0.1 | `fushiSubtitleShortcut('offset-minus'/'offset-reset'/'offset-plus')` |
| 字幕样式 | 子页直改 `subtitleStyle`（大小 / 行高 / 对齐 / 描边 / 文字色 / 底板色 / 底板不透明度），上下限取自 `fushiSubtitleStyle.LIMITS` |
| 扩展设置 | background 的 `openOptions` 消息 |

几条定死的边界：

- **不新增任何状态**。每一项都写既有 `chrome.storage.local` 键或调既有执行端，设置页 / 工具栏弹窗 / 本菜单
  三处经 `storage.onChanged` 双向同步，永远是同一个值。文案也**复用既有 i18n 键**而不是另起一套 `pc_` 同义键
  （同一个开关三处必须同一个词；只有这里独有的概念——时轴偏移标题、样式子页的返回 / 恢复默认 / 全部设置、
  站点自带轨提示——才新增键）。
- **按钮进控制栏，菜单不进**。按钮插进站点控制栏，于是全屏、控件自动隐藏、站点自己的显隐节奏全部免费跟随；
  菜单是 `position: fixed` 浮层，挂 `fullscreenElement || body`（与查词弹窗 / 字幕覆盖层同一策略），
  否则会被控制栏的 `overflow` 裁掉。落点右缘对齐按钮、压在其上方，上方不够才翻到下方，最后夹进视口。
- **事件不漏给站点**。播放器把「点画面」当播放 / 暂停、把空格方向键当播放控制，所以按钮与菜单上的指针与
  键盘事件一律 `stopPropagation`（不 `preventDefault`——聚焦、滑杆拖动、取色要留着）。Esc 只在菜单开着时吞掉。
- **站点适配只有两条特例**，找不到锚点就退回通用浮动按钮（视频门：画面 ≥200×120、时长 ≥30s 或直播，
  与 `study-tracker.js` 同口径，挡掉首页悬停预览和卡片预告片）。Netflix 锚的是
  `[data-uia="control-fullscreen-enter"]` 这个契约而非逐版本变的 class 名。控制栏被站点重建（YouTube SPA
  导航）后由 1 秒一次的幂等「确保在位」补挂。
- **「开着却什么都不画」要说出来**：站点自带轨默认不叠覆盖层（`updateSubtitleOverlay` 的显示门），
  此时菜单里出现一条提示 + 一键改用 Fushi 字幕，而不是让用户以为开关坏了。
- 总开关 `playerControls`（options「播放器内的字幕按钮」，默认开）关掉后一个节点都不挂。
- 两个页内宿主 `#fushi-player-btn` / `#fushi-player-controls` 已进 `theme.js` 的 `IN_PAGE_HOSTS` 与
  `generate-content-css.mjs` 的同名清单（改动任一侧都要改另一侧并重生成 `content.css`，守卫钉死）。
  按钮用 scrim 系 token（画面上什么颜色都有，浮层要的是稳定可读），菜单用 surface 系。

真站点验证状态：YouTube 控制栏锚点与菜单已用离线壳（真实 `content.css` + 真实模块 + 仿控制栏）做过像素复核；
**Netflix 锚点与两站的真站点端到端仍为 `implemented_unverified`**——本仓开发环境无 Netflix 账号，
锚点找不到时退回通用浮动按钮，不会出现「按钮整个消失」。

行为守卫 `player-controls.test.js`（24 条，已变异实测：拿掉能力总门 / 自己写 `subtitleHidden` /
改成 `appendChild` / 默认不删键，四处破坏各自对应的用例都会转红）。

## 站点适配状态

| 站点 | 机制 | 验证状态 |
|---|---|---|
| Netflix | JSON.parse hook + 官方 seek（netflix-bridge） | ✅ 已真站点验证（既有） |
| YouTube | MAIN-world 运行态 captionTracks（POT）→ Android Innertube → player response；服务端 `/api/youtube/captions` 与 live 采样末级兜底 | 待本次真站点复验 |
| TVer | JSON.parse hook（stream-bridge，asb tver-page 移植） | ⚠️ implemented_unverified |
| Bilibili.tv（国际站） | JSON.parse hook，srt/bbjson | ⚠️ implemented_unverified |
| Hulu（日本） | XHR 响应旁路（ref_id + tracks） | ⚠️ implemented_unverified |
| Prime Video | 捕获 GetVodPlaybackResources 重放 → TTML | ⚠️ implemented_unverified |
| 其它站点 | 通用：textTracks 收割 + DOM live 采样 + 外挂字幕 | ✅ 通用路径既有 |

⚠️ = 提取逻辑逐行对照 asbplayer 已上线适配器移植、纯函数有 node 单测，但本仓库开发环境无对应
账号，未做真站点端到端验证；上线前请在真站点各过一遍（打开视频 → 字幕列表出现整集轨）。

**新增站点适配器步骤**：① `stream-bridge.js` 加纯函数提取器 + `siteForHost` 路由 + 对应
hook 安装；② `manifest.json` 的 stream-bridge matches 加域名；③ 新格式则在
`subtitle-adapters.js` 加解析器并在 `content.js` `fushiOnStreamCues` 分派；④ 加
`stream-bridge.test.js` 样例 JSON 测试；⑤ 跑 sync-mirrors。参考 asbplayer
`extension/src/entrypoints/*-page.ts`（MIT）。

## 快捷键（视频页，options 逐动作独立开关）

| 键 | 动作 |
|---|---|
| ← / → | 上一句 / 下一句字幕（仅当前视频有字幕轨时接管） |
| ↑ | 回当前句句首重播 |
| Shift+S | 打开浏览器原生字幕侧边栏（当前视频有 Fushi 字幕轨时） |
| Shift+H | 隐藏 / 显示字幕（站点原生字幕 + 扩展覆盖层；**不**需要 Fushi 字幕轨） |
| Ctrl+Shift+← / → / ↓ | 字幕偏移 −100ms / ＋100ms / 重置 |
| Ctrl+Shift+Z | 复制当前字幕句（配合 Fushi 剪贴板监看即查词） |
| Ctrl+Shift+[ / ] | 播放速度 −0.25x / ＋0.25x（0.25–4x） |

这里使用固定键位 + 纯函数判定；每个动作在扩展设置页各有自己的开关。站点输入框/可编辑区
一律放行；无轨时方向键及 Shift+S 均放行给站点原生行为。

`Shift+H` 的「隐藏」用 `visibility:hidden` 而非 `display:none`：扩展的取词、逐句制卡、caret
兜底命中都要读字幕节点的 textContent / 几何，`display:none` 会把它们摘出布局，隐藏字幕就
等于顺手废掉制卡。状态存 `chrome.storage.local.subtitleHidden`，与 options 页的「隐藏字幕」
开关双向同步（守卫见 `subtitle-hide.test.js`）。

## 制卡快捷键（查词弹窗打开时）

| 键 | 动作 |
|---|---|
| Ctrl+Enter | 制卡 = 点弹窗里的「＋」（Anki 三态 ＋/✓/✓↩︎ 与鼠标点击完全同源） |

不受上面的「视频页快捷键」总开关影响——它属于查词弹窗而不是视频页。按键判定在共享的
popup.js 中；app 内由宿主分发快捷键，浏览器扩展没有绑定注入通道，使用内置默认值
Ctrl+Enter。Windows app 外按焦点分流：可聚焦的剪贴板面板只有在用户点入并获得键盘焦点后，
才使用 Fushi 设置 → 快捷键 → 查词弹窗 → 制卡里的可改键绑定；永不抢焦点的瞬态查词覆盖窗
带 `WS_EX_NOACTIVATE`，收不到键盘事件，因此没有制卡快捷键，也不注册全局热键，避免让当前
游戏失焦。只有真的点到了按钮才吞掉按键，IME 组词期间与输入框内一律放行。

## 测试

```
node --test            # 本目录全部 *.test.js（node 内置 runner，零依赖）
```

Dart 侧守卫（跑法见仓库根 CLAUDE.md）：`fushi/test/{build,lookup,mining,sync,...}/browser_extension_*`
做镜像字节一致 + 功能链存在性扫描。扩展 JS 单测目前不在 CI，提 PR 前请本地跑过。

行为测试历来按中文文案断言：模块里的文案现在走 i18n 键，测试壳要注入
`scripts/i18n-fixture.js` 的 `makeFushiT()`（默认装 zh-CN 字典）到 `window.fushiT`（纯函数模块
设 `globalThis.fushiT`）；没注入的壳里 `tr()` 退回键名。
