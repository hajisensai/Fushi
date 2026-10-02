## BUG-2877 · 查词弹窗常驻非 passive touchmove 让词典滑动卡顿
- **报告**：2026-10-02（用户：「滑动词典卡卡的」）
- **真实性**：✅ 真 bug。BUG-2415 为墨水屏「瞬时滚动」的触摸半边，在 in-app 弹窗 document 上
  **常驻**挂了 `touchmove`（`passive:false`）（`fushi/assets/popup/popup.js` 原 6714 行，三镜像同），
  而该开关默认关——关着时回调第一行就 return，监听本身却始终在场。document 级触摸监听一旦
  显式 `passive:false`，Chromium「document 级触摸监听默认 passive」的干预不再生效：每次起滑都要
  等主线程跑完 JS 应答，合成器才开始滚动。词典页结果区与查词弹窗都是 popup.js（`home_dictionary_page.dart`
  的 `DictionaryPopupWebView`），滚动期间主线程本来就在解码图片、跑词条状态探测、重排 masonry，
  弱 CPU 机型（墨水屏手机尤甚）上滑动跟不住手、惯性被吞。
  真机证据（HiBreak，Android 14，Chrome 152 / 同版 WebView，`adb shell input swipe` 真触摸，
  主线程忙 1.2 s 时滑同一下，3 次中位）：纯净页无监听 901px vs 挂 `passive:false` touchmove 473px；
  换成**真实 popup.js** 加载：改前 471px、改后 895px。主线程空闲时两者无差别。
- **[x] ① 已修复** — 本提交：非 passive `touchmove` 改由 `__fushiInstallPopupEinkTouchMoveGate()`
  按开关挂卸——把 `window.__fushiPopupInstantScroll` 换成访问器属性，注入（`popup_settings_injection.dart`
  的赋值，可能早于或晚于 popup.js 执行、也随设置变更重写）每次写入即同步：true 挂、false 卸并复位
  触摸状态。开关关着时弹窗不再有任何阻塞式触摸监听；touchstart/touchend/touchcancel 本就 passive，
  照常常驻。扩展镜像分支不变（从不挂 document 级触摸监听）。Dart 注入侧无需改动。
  真机（真实 popup.js，`getEventListeners(document)`）：改前加载即 `[{passive:false}]` 且写 false
  卸不掉；改后默认 `[]`、写 true → `[{passive:false}]`、写回 false → `[]`、注入先于脚本为 true
  → 加载即挂。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/popup_touchmove_passive_gate_test.js`（Node 真执行
  popup.js，记录 document 实际挂着的监听：默认不挂 / 写 true 恰好一个 passive:false / 同值不重复挂 /
  写 false 卸掉 / 预置 true 加载即挂 / 扩展分支不挂），由
  `fushi/test/dictionary/popup_touch_instant_scroll_guard_test.dart` 在 `flutter test` 内驱动，同文件
  另加源码守卫：阻塞 touchmove 只能在门控函数里挂、全文件只有一个挂载点。共享假 DOM
  `test/pages/_popup_dom_host.js` 补 `removeEventListener` 并加 `beforeRun` 钩子。
- **备注**：滚轮那条 `wheel`（`passive:false`）是桌面端有意重做滚动（BUG-260/2834），不在本条范围。
  未在 Fushi app 内真机复测（装机为非 debuggable 构建，无法注入新 popup.js）；真机证据来自同一设备
  同版 Chromium 加载真实 popup.js。
