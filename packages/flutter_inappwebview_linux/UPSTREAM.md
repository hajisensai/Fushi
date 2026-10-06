# flutter_inappwebview_linux（vendored）

- 上游：pub.dev `flutter_inappwebview_linux` **0.1.0-beta.1**（2026-02-04，
  https://github.com/pichillilorenzo/flutter_inappwebview/tree/master/flutter_inappwebview_linux），
  Apache-2.0。`example/` 未带入；`linux/test/` 原样保留。
- 为什么 vendor：上游这版依赖 `flutter_inappwebview_platform_interface ^1.4.0-beta.3`，
  只有把整套 `flutter_inappwebview` 升到 6.2.0-beta.3 才解得开；本仓 Windows / Android
  实现是基于 6.1.5 / 接口 1.3.0 的 fork（`packages/flutter_inappwebview_windows`、
  `third_party/flutter_inappwebview_android`），整体升 beta 会波及五个平台的阅读器与查词。
  所以只把 Linux 实现拿进来降到 1.3.0。
- 注册：6.1.5 的 `flutter_inappwebview` 不 endorse Linux，由 `fushi/pubspec.yaml`
  直接依赖本包完成注册。

## 本仓改动

### Dart 层降到 platform_interface 1.3.0

- 删除 1.4 才有的 `create*Static()` 覆盖里引用不存在类型的那几个
  （`PlatformWebNotificationController`、`DefaultInAppLocalhostServer.static()`），其余
  1.4 新增方法只去掉 `@override`（1.3.0 基类没有它们，保留无害）。
- `toMap({EnumMethod? enumMethod})` → `toMap()`（1.3.0 无 `EnumMethod`）。
- JS handler：1.3.0 只有 `JavaScriptHandlerCallback(List<dynamic> args)`；原生侧仍按 1.4
  形状发 `{args, origin, isMainFrame, ...}`，Dart 侧只取 `args`（`_LinuxJavaScriptHandlerData`），
  禁用名单按 Windows fork 的 `_JAVASCRIPT_HANDLER_FORBIDDEN_NAMES` 本地化。
- 1.4 才有的回调：`onDownloadStarting` 去掉（回落 `onDownloadStartRequest` / `onDownloadStart`）；
  `onShowFileChooser` 无 1.3 对应，直接返回 null（原生侧走默认处理）；
  `useOnAjaxReadyStateChange` / `useOnAjaxProgress` 设置项不存在，删掉推断。
- `requestFocus()` 去掉 1.4 的 `direction` / `previouslyFocusedRect` 参数；
  `getCacheModel()` 删除；`saveWebArchive` 断言去掉 `isSupported()`。

### 原生：薄注册层 + 运行时 dlopen WPE 实现

- 上游把整个插件（连同 libWPEWebKit）直接链进 runner：系统没装 WPE WebKit（Ubuntu 24.04
  官方源就没有）时**整个 app 起不来**。改为：
  - `fushi_wpe_loader.cc` → `flutter_inappwebview_linux_plugin`（runner 链接的就是它，
    不依赖 WPE），注册时从自身所在目录 dlopen `libflutter_inappwebview_linux_wpe.so`
    并调用改名后的 `fushi_inappwebview_wpe_register_with_registrar`；另注册
    `fushi/flutter_inappwebview_linux/runtime` channel 报告加载结果。
  - 上游全部源码编成 `flutter_inappwebview_linux_wpe`（编译期宏把公开注册函数改名，
    避免与薄层同名），作为 bundled library 装进 `bundle/lib/`。
  - CMake 里所有 WPE 侧依赖改为可选：缺失时只编薄层并给出 WARNING，而不是 FATAL_ERROR。
- 不再把系统的 libWPEWebKit / libwpe / libWPEBackend-fdo 拷进 bundle：上游只拷库本体，
  不带 WPEWebProcess / WPENetworkProcess 辅助进程（按编译期 libexec 路径查找）与依赖树，
  在没装 WPE 的机器上本来就跑不起来，只会把 bundle 钉死在构建机的 WPE ABI 上。
  WPE WebKit 改为发行版运行时依赖。
- Dart：`lib/src/fushi_runtime_status.dart`；`LinuxInAppWebViewWidget.build` 在后端不可用时
  显示安装提示，`LinuxHeadlessInAppWebView.run` 抛 `LinuxWebViewUnavailableException`。

### 原生：首屏加载事件竞态（上游 bug）

- 上游在 `InAppWebView` 构造函数里就开始初始加载，此时 channel 还没 `AttachChannel`、
  Dart 控制器也还没装 handler；`initialData` 走 `load_bytes`，加上 `loadData()` 自己转一圈
  主循环，几乎同步载完，`onLoadStart` / `onLoadStop` 全被丢掉——Dart 永远等不到页面载完
  （实测 `dict_style_preview_null_reply_crash_itest` 卡死在 `onLoadStop`）。URL 加载只是靠
  网络延迟碰巧赶上。
- 修法：widget 路径（`InAppWebViewManager::CreateInAppWebView`）设
  `deferInitialLoad = true`，构造时只记下初始内容；Dart 在
  `LinuxInAppWebViewWidget._onPlatformViewCreated` 里控制器构造完（handler 已就位）后发
  `fushiLoadInitialContent`，原生 `LoadInitialContent()` 才开载，顺序与其它平台一致
  （`onWebViewCreated` 之前触发、事件在之后到达）。headless / 多窗口 / InAppBrowser 路径
  不变（它们的 handler 在创建前就已装好）。
- `WEBKIT_CHECK_VERSION(2, 50, 0)` 守住 `webkit_web_view_get_theme_color`（Debian trixie 的
  WPE 2.48 没有它，2.48 上返回「无主题色」）。

### 原生：自定义 scheme 按 context 只注册一次、按 web view 分发（上游 bug）

- 上游每个 `InAppWebView` 都以 `this` 为 user_data 在**共享的** `WebKitWebContext` 上
  `webkit_web_context_register_uri_scheme`；WebKit 拒绝同一 context 重复注册同一 scheme，
  于是之后所有 web view 的该 scheme 请求都路由给**第一个** `InAppWebView`——它被 dispose
  之后就是悬空指针。实测：同一会话第二次打开书，`fushi-reader://` 请求打到已关闭的阅读器，
  章节永远载不出（content ready 超时、停在 `about:blank`）；嵌套查词弹窗的
  `image://` / `dictmedia://` 由外层弹窗应答。
- 修法：每个 context 每个 scheme 只注册一次（已注册集合挂在 context 的 GObject data 上，
  随 context 销毁），回调不带 user_data，按 `webkit_uri_scheme_request_get_web_view`
  在 `WebKitWebView* → InAppWebView*` 登记表里找归属；析构时注销。

### Dart：平台视图不再 autofocus

- 上游 `CustomPlatformView` 的 `Focus(autofocus: true)` 让每个 WebView 一挂载就抢走 Flutter
  焦点，而它的 `onKeyEvent` 对所有键返回 `handled`、全部转给 WPE——宿主页快捷键（阅读器里
  Esc 关查词弹窗等）被整个吞掉。改为 `autofocus: false`：与 Windows WebView2 一致，键盘
  默认归 Flutter，用户点进 WebView（`onPointerDown` 里 `requestFocus`）后才进 DOM，由宿主的
  键盘桥交回 Dart。

## 升级

上游发正式版且本仓整体升到 `flutter_inappwebview` 6.2+ / 接口 1.4 时，删掉本目录，改回
pub.dev 依赖，但**保留薄注册层的做法**（或确认上游已改成可选加载），否则 Ubuntu 用户
又会回到「缺 WPE 就整个 app 起不来」。
