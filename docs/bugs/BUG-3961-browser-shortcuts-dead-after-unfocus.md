## BUG-3961 · 浏览器 Ctrl+F 等快捷键在焦点离开地址栏后失效
- **报告**：2026-11-01（用户：「ctrl+f 这种查找快捷键都没有，并且补齐常用快捷键」）
- **真实性**：✅ 真 bug（动作与默认键早已存在，按键到不了）。根因 `fushi/lib/src/pages/implementations/fushi_web_browser_page.dart` build 里承接快捷键的是 `Focus(canRequestFocus: false, onKeyEvent: _onKeyEvent)`：它自己不能持焦，Flutter 侧按键从 primaryFocus 往上冒泡，只有焦点在它子树里（地址栏 / 查找框）时才经过它。地址栏回车 / Esc 走 `unfocus()`，焦点交给路由 scope（在该节点之外），此后 Ctrl+F / Ctrl+T / Ctrl+W 等全部收不到；既有测试全是直接调 `runShortcut`，没有一条走真实按键派发。
- **[x] ① 已修复** — 改成 `FocusScope(autofocus: true, skipTraversal: true, onKeyEvent: …)`：页内任何 unfocus 都落回这个 scope，按键必经 `_onKeyEvent`。WebView 持 OS 焦点期间仍走 DOM 键盘桥；键盘桥改用 `bridgeToken` / `fromBridgeToken`（原来用 `serialize()`，小键盘键的 `#keyId` token 页内永远对不上）。同时补齐常用键：Ctrl+1…8 / Ctrl+9、Ctrl+PgUp/PgDn、Ctrl+F4、Alt+D / F6、F3 / Ctrl+G（Shift 反向）、Ctrl+Shift+N 无痕、Ctrl+H 历史、Ctrl+Shift+O 书签、Ctrl+Shift+Y 下载（Ctrl+J 是全局 AI 助手键）、Ctrl+小键盘 +/-/0；macOS 换 Safari 键位（⌘Y / ⌥⌘B / ⌥⌘L）。查找条已开时 Ctrl+F 回到输入框并全选。
- **[x] ② 已加自动化测试** — `fushi/test/pages/fushi_web_browser_shell_test.dart`「焦点离开地址栏后 Ctrl+F / Ctrl+T 真按键照样生效」：unfocus 后 `sendKeyEvent` 真按键，断言查找条打开、新标签建出。
- **备注**：WebView 持焦路径（DOM 键盘桥）在 Windows 真机上的复测待补。
