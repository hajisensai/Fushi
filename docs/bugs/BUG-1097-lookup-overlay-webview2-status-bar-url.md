## BUG-1097 · 查词浮窗左下角冒出 `https://hibiki.popup/popup.html?query=…&wildcards=off`

- **报告**：2026-07-26（用户：）
- **真实性**：✅ 真 bug。那不是我们拼的字符串，是 **WebView2 的 status bar（链接地址预览）**。
  虚拟域名 `hibiki.popup` 全仓只注册在 runner 自有的裸 WebView2 `GlobalLookupWindow`
  （不走 flutter_inappwebview 插件）：`hibiki/windows/runner/global_lookup_window.cpp:1106-1108`
  （composition 路径）/ `:1172-1174`（windowed 路径）`SetVirtualHostNameToFolderMapping`。
  URL 里的 `?query=…&wildcards=off` 是 **Yomitan 结构化内容的词典内链**被原样写进 href
  （`hibiki/assets/popup/popup.js:1807` `element.setAttribute('href', node.href)`）；onclick 的
  preventDefault 只拦点击，**拦不住 hover 预览**。看着像「主窗口左下角」是因为覆盖窗是撑满
  整个级联包围盒的 topmost 无边框窗（`global_lookup_window.cpp:461-481`），status bar 画在它
  自己的左下角。
- **[x] ① 已修复**（提交 fceb21443）— `hibiki/windows/runner/global_lookup_window.cpp` 的 `ConfigureWebView()`
  函数体开头（null guard 之后）加 `get_Settings` + `put_IsStatusBarEnabled(FALSE)`，并把失败的
  HRESULT 经 `ReportOverlayError` 记进 native 日志（不静默吞）。`put_IsStatusBarEnabled` 在
  **基类** `ICoreWebView2Settings` 上，不需要 QI 新版本接口。`ConfigureWebView()` 是两条创建
  路径（composition / windowed）与 BUG-693 自愈重建的唯一漏斗，一处覆盖全部 surface。
  href 保持不动（点击处理要用它，且 preventDefault 本就拦不住预览）。
- **[x] ② 已加自动化测试** — 源码守卫
  `hibiki/test/lookup/global_lookup_status_bar_guard_test.dart`：断言 `put_IsStatusBarEnabled(FALSE)`
  出现在 `ConfigureWebView()` 函数体内（而不是散在某一条创建路径里），且失败被上报而非丢弃。
- **备注**：native C++ 改动已用 `flutter build windows --debug` 真编译验证；真机肉眼复测
  （hover 词典内链看左下角是否再无 URL）待补。
  相关但**未动**：`docs/bugs/BUG-842-popup-native-title-tooltip-flies.md` 是同一根因家族
  （原生 OS 提示窗定位），当年明确把「词典内容来源的 title」划在范围外，本轮只关 status bar。
