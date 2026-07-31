/// 在 WebView **内容层**捕获按键并交回 Dart 的 JS 桥。
///
/// 为什么需要它（TODO-1078 / BUG-136 / BUG-402 同源）：桌面 Windows 上 fork 的
/// `flutter_inappwebview_windows` 只把鼠标转给 WebView2、**不转键盘**，且任一指针
/// 手势后 WebView2 就抢走 OS 键盘焦点。此后 Flutter 侧 `Focus.onKeyEvent` 收不到
/// 按键，页面的快捷键整体失效；而浏览器自己还会对这些键跑默认行为（裸 Space =
/// `scrollByPage` 向下翻屏），于是表现为「按了没反应 / 按了乱跳」。
///
/// 焦点侧的修复（把焦点抢回来）由 `PageFocusOwnership` 负责；但焦点归 WebView2
/// 期间按下的键仍然只存在于 DOM 里，只能在内容层截获后 `callHandler` 交回 Dart。
/// 两者互补：OS 焦点归 Flutter 时 DOM 收不到 `keydown`，故本桥与页面的
/// `onKeyEvent` 天然互斥、不会双触发。
library;

/// 生成拦截 [keys] / [mouseButtons] 并回传 Dart 的输入监听脚本。
///
/// - [handlerName]：`callHandler` 的 handler 名，Dart 侧须 `addJavaScriptHandler`
///   注册同名 handler。回调收到的首个参数是命中的 **token** 字符串。
/// - [keys]：要拦截的键盘 token。token 形如 `[Ctrl+][Shift+][Alt+][Meta+]<键名>`，
///   键名可以是 `KeyboardEvent.key`（`' '` / `'ArrowLeft'`）**或** `KeyboardEvent.code`
///   （`'Space'` / `'KeyD'` / `'Escape'`）——后者与 `InputBinding.serialize()` 的键名
///   逐字同名（`_knownKeys` 的标签就是按 DOM `code` 取的），所以注册表里的绑定可以
///   **原样**当 token 用，不需要中间映射表。修饰键前缀顺序固定 Ctrl→Shift→Alt→Meta，
///   与 [ModifierKey] 的 `index` 序、[InputBinding.serialize] 完全一致。
/// - [mouseButtons]：要拦截的 `MouseEvent.button`（1=中键 / 2=右键 / 3=后退 /
///   4=前进）。命中回传 `'Mouse<n>'`，与 `MouseBinding.deserialize` 直接对接。
///
/// 行为（对所有宿主一致，勿在调用侧另写一份）：
/// * 裸键与组合键统一按 token 匹配——表里只有裸 token 时，带修饰键的按下天然算不
///   命中而放行（等价于旧版「带 Ctrl/Shift/Alt/Meta 一律放行」），但表里写了
///   `'Ctrl+KeyD'` 就能真正拦到组合键。旧版把「放行组合键」写成独立分支，于是绑成
///   组合键的动作在 WebView 持焦时永远收不到——这条特殊情况现在消失了。
/// * IME 组字中（`isComposing`）放行，否则破坏日文输入。
/// * 焦点在 `<input>` / `<textarea>` / `contenteditable` 里时放行，否则打字打不出
///   空格。
/// * 命中才 `preventDefault()`，掐掉 Chromium 默认滚屏 / 中键自动滚动 / 侧键历史
///   导航 / 右键菜单；未命中不干预页面。
///
/// 生成结果整体裹在 IIFE 里：同一 document 里可能注入**多份**桥（阅读器一份、漫画
/// 页规划中再一份），键表若留在脚本作用域就是全局 `var`，后注入的一份会把先注入的
/// 键表整个覆盖掉，而两个 listener 都还在——表现为「某一页的键突然全不响应了」，
/// 且极难定位。裹进 IIFE 后每份桥各自闭包持有自己的键表，多份共存互不相干。
/// 前导 `;` 是拼接安全惯例：本脚本被插进一大段 setup 脚本中间，前一条语句若少了
/// 分号，裸 `(function…` 会被解析成对它的调用。
/// [forwardRepeats] 为 false 时丢弃长按产生的 `KeyRepeatEvent`（`e.repeat`）。
/// 漫画页要的是「按住方向键不堆翻页风暴」，阅读器则保留连发，故做成参数而不是
/// 二选一写死。
///
/// [stopPropagation] 为 true 时额外 `stopImmediatePropagation()`，用于宿主文档里
/// 还有别的 keydown 监听、且这些键必须**独占**给 Dart 的场合。
///
/// 生成的脚本自带按 [handlerName] 派生的幂等安装守卫：宿主可能对同一 document
/// 反复注入（漫画每次换加载窗口都重新 evaluate 一次），没有守卫就会叠加多个
/// listener → 一次按键回传多次 → 翻页翻两页。
///
/// **键表可热更新**：token 表存在 `window` 上按 [handlerName] 派生的槽里，每次
/// 注入都覆盖该槽，但 listener 只装一次。查词弹窗这类「热槽 WebView 跨查词长期
/// 存活、用户随时可能在设置里改键」的宿主，必须靠这条才能让改键立即生效——旧版
/// 键表闭包在首次注入时冻结，改键后 WebView 持焦期间仍按老键位响应。
///
/// [installMouseListeners] 为 true 时额外装 `mousedown`/`auxclick`/`contextmenu`
/// 监听。默认 false：只用键盘的宿主生成的脚本里完全不含鼠标块（零行为变化）。
/// 注意它与 [mouseButtons] 是否为空**无关**——弹窗要在「用户当前没绑鼠标键、之后
/// 才绑上」时也能生效，listener 必须恒装、只让表变。
///
/// [deferToPopupModal] 为 true 时，`window.__hoshiPopupModalDepth > 0`（popup.js 里
/// 有模态面板开着，如「已制卡动作」面板）期间整座桥让位。**查词弹窗必须打开它**：
/// 桥是 capture 阶段且在 `onLoadStop` 就注册，比模态自己的 capture 监听早得多，不
/// 让位就会抢走模态的 Escape——用户想关面板，结果整个查词窗被关掉（popup.js 那处
/// 监听的注释正是「面板自己吃掉 Esc，否则会把整个查词窗一起关了」）。与放行输入框 /
/// IME 同一类守卫：弹窗内有更高优先级的消费者时，宿主不抢。
String webViewKeyBridgeScript({
  required String handlerName,
  List<String> keys = const <String>[],
  List<int> mouseButtons = const <int>[],
  bool installMouseListeners = false,
  bool deferToPopupModal = false,
  bool forwardRepeats = true,
  bool stopPropagation = false,
}) {
  assert(
    keys.isNotEmpty || installMouseListeners,
    'a keyboard-only bridge with no keys would be dead code',
  );
  final String keyList = keys.map(_jsStringLiteral).join(', ');
  final String buttonList = mouseButtons.join(', ');
  final String installFlag =
      _jsStringLiteral('__hoshiKeyBridgeInstalled_$handlerName');
  final String keysVar = _jsStringLiteral('__hoshiKeyBridgeKeys_$handlerName');
  final String buttonsVar =
      _jsStringLiteral('__hoshiKeyBridgeButtons_$handlerName');
  final String repeatGuard =
      forwardRepeats ? '' : '\n    if (e.repeat) return;';
  // 模态让位对键盘与鼠标同时成立：面板开着时点它上面的按钮，侧键也不该把整个查词窗
  // 关掉。故各监听体内统一先判这一条。
  const String modalGuard =
      '\n    if ((window.__hoshiPopupModalDepth || 0) > 0) return;';
  final String popupModalGuard = deferToPopupModal ? modalGuard : '';
  final String propagationGuard =
      stopPropagation ? '\n    e.stopImmediatePropagation();' : '';
  final String mouseListeners = installMouseListeners
      ? '''
  document.addEventListener('mousedown', function(e) {
    if (!e || e.button === 0) return;$popupModalGuard
    if ((window[$buttonsVar] || []).indexOf(e.button) === -1) return;
    e.preventDefault();$propagationGuard
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('$handlerName', 'Mouse' + e.button);
    }
  }, {capture: true});
  document.addEventListener('auxclick', function(e) {
    if (!e) return;$popupModalGuard
    if ((window[$buttonsVar] || []).indexOf(e.button) === -1) return;
    e.preventDefault();$propagationGuard
  }, {capture: true});
  document.addEventListener('contextmenu', function(e) {
    if (!e) return;$popupModalGuard
    if ((window[$buttonsVar] || []).indexOf(2) === -1) return;
    e.preventDefault();$propagationGuard
  }, {capture: true});
'''
      : '';
  return '''
  ;(function () {
  window[$keysVar] = [$keyList];
  window[$buttonsVar] = [$buttonList];
  if (window[$installFlag]) return;
  window[$installFlag] = true;
  function _hoshiBridgeTokens(e) {
    var mods = '';
    if (e.ctrlKey) mods += 'Ctrl+';
    if (e.shiftKey) mods += 'Shift+';
    if (e.altKey) mods += 'Alt+';
    if (e.metaKey) mods += 'Meta+';
    var out = [];
    if (e.key) out.push(mods + e.key);
    if (e.code && e.code !== e.key) out.push(mods + e.code);
    return out;
  }
  document.addEventListener('keydown', function(e) {
    if (!e) return;
    if (e.isComposing) return;$repeatGuard$popupModalGuard
    var t = e.target;
    if (t) {
      var tag = t.tagName ? t.tagName.toUpperCase() : '';
      if (tag === 'INPUT' || tag === 'TEXTAREA' || t.isContentEditable) return;
    }
    var _keys = window[$keysVar] || [];
    var _cand = _hoshiBridgeTokens(e);
    var _hit = null;
    for (var i = 0; i < _cand.length; i++) {
      if (_keys.indexOf(_cand[i]) !== -1) { _hit = _cand[i]; break; }
    }
    if (_hit === null) return;
    e.preventDefault();$propagationGuard
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('$handlerName', _hit);
    }
  }, {capture: true});
$mouseListeners  })();''';
}

/// 把 Dart 字符串转成安全的 JS 单引号字面量（键名可能含引号 / 反斜杠）。
String _jsStringLiteral(String value) {
  final String escaped = value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
  return "'$escaped'";
}
