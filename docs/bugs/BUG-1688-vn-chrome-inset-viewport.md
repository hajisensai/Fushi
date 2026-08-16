## BUG-1688 · VN 模式忽略 chrome inset 与页面尺寸，正文被顶栏/底栏与刘海压住（iOS 最严重）
- **报告**：2026-08-16（用户：iOS 小说的 VN 模式基本处于不可用状态）
- **真实性**：✅ 真 bug。在 macOS live `InAppWebView`（同为 WKWebView，与 iOS 同一份 VN JS、同一条自定义 scheme 交付链）上复现，读数：
  `chromeTopInset=0 chromeBottomInset=0 pageWidth=0 pageHeight=0 innerHeight=697`，
  `.fushi-vn-screen` 的 client rect = `top=0 bottom=697`（= 整个视口），即 VN 屏完全无视 chrome 预留带。
  根因两处，同源：
  - `fushi/lib/src/reader/reader_visual_novel_scripts.dart:3013`（修复前）——host-compat shim 里
    `vn.setChromeInsets = function(topPx, bottomPx) { return null; };` 是空壳，Dart 侧
    `fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:1045` 每次下发的顶栏/底栏预留
    在 VN 下全部被丢弃；且 VN 自己的 `initialize()`（同文件 911 行起）也没有像分页/连续 shell
    （`reader_pagination_scripts.dart:2669-2687`）那样从 `C.chromeTopInset / C.chromeBottomInset /
    C.dartPageWidth / C.dartPageHeight` 写 `--chrome-top-inset / --chrome-bottom-inset /
    --page-width / --page-height`。于是 `reader_content_styles.dart:1000-1001` 的
    `.fushi-vn-stage { padding-top: calc(<margin>vh + var(--chrome-top-inset, 0px)) }` 恒取 0px 兜底。
  - `reader_visual_novel_scripts.dart:1380-1381`（修复前）——切屏量尺 `createScreenMeasurement` 用
    `var(--page-width, 100vw) / var(--page-height, 100vh)` 撑开，VN 下这两个变量同样从没人写，
    量尺恒等于**整个视口**，比真实 `.fushi-vn-screen` 大出整条 chrome 预留带；`updatePageSize(width,
    height)` 又整个忽略入参，永远补不回来。结果 `fitScreensToViewport` 把每屏都切成"刚好填满整个
    视口"，于是**每一屏**的首尾行都落进被顶栏/底栏覆盖的区域——不是偶发，是每屏必现。
  为什么 iOS 最严重：预留带 = 顶部进度条 + 顶栏 + 底栏 + **系统安全区**，iOS 的刘海与 home
  indicator 让这条带子最厚，被吃掉的行数最多，所以在 iOS 上直接表现为"基本不可用"。同一缺陷在
  Android/桌面上同样存在，只是被吃掉的比例小、更容易被当成排版偏紧。
- **[x] ① 已修复** — `fushi/lib/src/reader/reader_visual_novel_scripts.dart`：
  1. 新增 `applyViewportVars()`，与分页 shell 用同一份 `C` 字段、同一组变量名写
     `--chrome-top-inset / --chrome-bottom-inset / --page-width / --page-height /
     --reader-viewport-height`，并在 `initialize()` 里排在 `ensureStage()` / `buildScreens()` **之前**
     （晚一步就会先按错的盒切一遍屏）。
  2. `setChromeInsets` 从空壳改为真实实现：写这两个 inset 变量后调
     `refitScreensToCurrentViewport()` 按新可用盒重切屏（只改 padding 不重切会留下溢出的旧屏）。
  3. `updatePageSize(width, height)` 真正消费入参，写 `--page-width / --page-height /
     --reader-viewport-height` 后同样重切屏。
  4. `createScreenMeasurement` 的量尺改为**真实 `.fushi-vn-screen` 的镜像**（照它的 client rect 定
     left/top/width/height；`.fushi-vn-screen` 是 border-box，宽高原样搬过来即同一个内容盒），
     只在首屏极早期拿不到盒时才回退旧的 `var(--page-*)` 撑开。这条是根因修复的落点：量尺与真实
     渲染盒同源之后，chrome 预留带怎么变都不会再切出溢出屏。
  5. `applyImageMaxVars` 的"实际 VN 视口"同步改为读 `.fushi-vn-screen` 盒（原读
     `window.innerWidth/Height` 整视口，会把插图算到能盖住顶栏/底栏的尺寸）。
  提交：见本分支 `worktree/ios-vn-fix-20260816`。
- **[x] ② 已加自动化测试** —
  - `fushi/integration_test/reader_vn_chrome_inset_dom_test.dart`（最强可落地层：真实 WebView 读 DOM
    几何）。修复前红：`--chrome-top-inset` 实读 0.0；修复后绿：`chromeTopInset=52
    pageWidth=1206 pageHeight=697 screenTop=52 screenHeight=645`。
  - `fushi/test/reader/vn_viewport_geometry_bug1688_test.dart`（CI 可跑的源码守卫）：锁住四个变量确实
    有人写、`setChromeInsets` 不再是 `return null` 空壳、`updatePageSize` 真读入参、量尺照真实屏盒量，
    以及 `applyViewportVars` 必须排在建舞台/切屏之前。
- **备注**：
  - **iOS 真机门未过**：本机跑不了 iOS 构建——`fushi/ios/build_aidoku_runtime.sh:8` 硬性要求
    `PLATFORM_NAME=iphoneos`（模拟器直接报错退出），且本机 `rustup` 只装了 `aarch64-apple-darwin`，
    iOS/模拟器 target 都缺。验证因此落在 macOS 的 WKWebView 上（与 iOS 同内核、同 VN JS、同
    `fushi-reader://` 自定义 scheme 交付链），iOS 安全区叠加后的实际观感仍需真机复测。
  - 同批排查中发现、**本次未动**的相邻问题，另行记录/择期处理：
    - `reader_engine_config.dart:13` 的注释声称引擎已改成 `<script src>` 走 fushi.local 拦截器的静态
      资源，代码里并无 `ReaderEngineScript`，实际仍是 `onLoadStop` 后一次 `evaluateJavascript`
      （`webview.part.dart:2649`）。陈旧注释会把 iOS 排障带偏。
    - iOS/macOS 走 `CustomSchemeResponse`，没有 statusCode / headers 通道，`_notFound` 的 404/403 在
      iOS 上退化成"200 空白页"，且原生 `CustomSchemeHandler` 从不 `didFailWithError` → `onReceivedError`
      不触发，任何资源解析失误在 iOS 上没有任何错误信号。
    - `lyrics.part.dart:195` 的 `baseUrl` 硬编码 `https://fushi.local`，无平台分支；iOS 上该文档落在
      一个真实不存在的 https 源上，其引用的自定义字体是 `fushi-reader://` 跨源请求，而
      `CustomSchemeResponse` 下发不了 `Access-Control-Allow-Origin`。
    - `vn_click_advance` / `visualNovelRevealSpeed` 两个偏好当前无消费者（M0 在 `webview.part.dart:648`
      / `:655` 强制常量），VN 的 6 个子设置至今无 UI 入口（M1 范围）。
