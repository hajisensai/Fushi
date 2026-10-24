## BUG-3704 · 应用内浏览器 Android 上网页全屏冻结、退不出（YouTube 画质菜单点不开）
- **报告**：2026-10-24（用户：YouTube 画质点不开）
- **真实性**：✅ 真 bug（Android 真机 43f8ed58 手机竖屏形态必现）。非全屏时 YouTube 画质菜单正常；用户遇到的是全屏：画面冻结、点什么都没可见反应，退出全屏后整屏白、返回键救不回来。根因：`fushi/lib/src/pages/implementations/fushi_web_browser_page.dart` 的 `_buildNarrow` 在网页全屏时同时增删 Column 首尾的状态栏垫块与底栏，中间不带 key 的 `Expanded(child: _buildTabs(...))` 在 `Element.updateChildren` 里配不上旧元素，网页区整个卸载重挂、InAppWebView 销毁重建；正在全屏的 WebView 被拆掉后插件挂在 `android.R.id.content` 下的全屏 custom view 留在 app 上方（`InAppWebViewChromeClient.java` onShowCustomView），`onHideCustomView` 再也不会被调用。宽屏布局只增删排在前面的子节点，不受影响。同类问题：键盘避让 `_avoidKeyboard` 在有无键盘时换父节点类型，弹键盘也会重挂网页（表单输入丢失）。
- **[x] ① 已修复** — `63bb38799a`（网页区 `Expanded` 带 `ValueKey('web-browser-narrow-tabs')`；`_avoidKeyboard` 恒定树形只改数值）；`c82e2ee11d`（插件兜底：全屏期间 API 33+ 注册 `OnBackInvokedCallback` 退出全屏，`dispose` 时还在全屏先 `onHideCustomView`）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/fushi_web_browser_shell_test.dart`（「网页全屏进出不重挂标签页」390 / 1280 两档断言同一 Element；「竖屏弹软键盘」断言键盘开合前后网页元素不变）。
- **备注**：Android 真机复测通过：YouTube 进全屏 → 齿轮 → 画质 → 480p 生效 → 退出全屏 chrome 恢复；弹键盘 / 退出全屏 `window.__mark` 不丢（页面未重载）。API < 33 的返回键路径与 iOS 未实机验证。
