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

/// 生成拦截 [keys] 并回传 Dart 的 `keydown` 监听脚本。
///
/// - [handlerName]：`callHandler` 的 handler 名，Dart 侧须 `addJavaScriptHandler`
///   注册同名 handler。回调收到的首个参数是命中的 `event.key` 字符串。
/// - [keys]：要拦截的 `KeyboardEvent.key` 值（如 `' '`、`'ArrowLeft'`）。
///
/// 行为（对所有宿主一致，勿在调用侧另写一份）：
/// * 只拦**裸**按键——带 Ctrl / Shift / Alt / Meta 的组合一律放行，否则会吃掉
///   用户改键后的组合语义（如 Shift+Space 后退翻页、Ctrl+Space 播放/暂停）。
/// * IME 组字中（`isComposing`）放行，否则破坏日文输入。
/// * 焦点在 `<input>` / `<textarea>` / `contenteditable` 里时放行，否则打字打不出
///   空格。
/// * 命中才 `preventDefault()`，掐掉 Chromium 默认滚屏；未命中不干预页面。
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
String webViewKeyBridgeScript({
  required String handlerName,
  required List<String> keys,
  bool forwardRepeats = true,
  bool stopPropagation = false,
}) {
  assert(keys.isNotEmpty, 'a key bridge with no keys would be dead code');
  final String keyList = keys.map(_jsStringLiteral).join(', ');
  final String installFlag =
      _jsStringLiteral('__hoshiKeyBridgeInstalled_$handlerName');
  final String repeatGuard =
      forwardRepeats ? '' : '\n    if (e.repeat) return;';
  final String propagationGuard =
      stopPropagation ? '\n    e.stopImmediatePropagation();' : '';
  return '''
  ;(function () {
  if (window[$installFlag]) return;
  window[$installFlag] = true;
  var _hoshiBridgeKeys = [$keyList];
  document.addEventListener('keydown', function(e) {
    if (!e || _hoshiBridgeKeys.indexOf(e.key) === -1) return;
    if (e.ctrlKey || e.shiftKey || e.altKey || e.metaKey) return;
    if (e.isComposing) return;$repeatGuard
    var t = e.target;
    if (t) {
      var tag = t.tagName ? t.tagName.toUpperCase() : '';
      if (tag === 'INPUT' || tag === 'TEXTAREA' || t.isContentEditable) return;
    }
    e.preventDefault();$propagationGuard
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('$handlerName', e.key);
    }
  }, {capture: true});
  })();''';
}

/// 把 Dart 字符串转成安全的 JS 单引号字面量（键名可能含引号 / 反斜杠）。
String _jsStringLiteral(String value) {
  final String escaped = value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
  return "'$escaped'";
}
