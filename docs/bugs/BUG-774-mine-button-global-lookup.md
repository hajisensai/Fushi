## BUG-774 · 剪贴板/选中查词缺少制卡按钮
- **报告**：2026-07-13（用户：剪切板查词和选中查词缺少了制卡按钮）
- **真实性**：✅ 真 bug（代码漂移 drift，非缺 flag）。根因 `hibiki/lib/src/pages/implementations/popup_settings_injection.dart:150`（原 `_globalLookupIconFontJs` 里的一行）。
  制卡按钮由 `assets/popup/popup.js:2302` **无条件**创建，唯一可见性门控在 CSS。app 外两个查词面（剪贴板面板 + 选中/覆盖窗）都经 `global_lookup_render.dart:60` 恒传 `PopupSettingsOptions(globalLookup:true)`，于是 `iconFontJs = _globalLookupIconFontJs`（`:266`）被注入，其 `<style id="hibiki-overlay-style">` 里带一句遗留 `.mine-button{display:none !important;}`（旧前提「no mining in the bare window」）。该前提早被推翻：
  - **制卡后端已接通**：TODO-1188 在 `overlay_bridge_handlers.dart`（`case 'mineEntry'`/`'duplicateCheck'` + `_mineEntry`/`resolveMineSentence`）实现了 app 外真 Anki 制卡路径，C++ `global_lookup_window.cpp` DEFER 这两桥；剪贴板面板 controller `:356` 与选中/覆盖窗都经共享 `maybeHandleOverlayDeferredBridge` 路由。
  - **CSS 明确要显示**：`popup.css:320`（BUG-751）`html.global-lookup .mine-button:not(:disabled){opacity:1}` 专为半透明面把制卡按钮提到全不透明——但 `display:none !important` 直接把它压掉（opacity 对 display:none 元素无意义），BUG-751 对制卡按钮那半条修复一直是空转。
- **[x] ① 已修复** — 删除 `popup_settings_injection.dart` 中 `_globalLookupIconFontJs` 的 `'.mine-button{display:none !important;}'` 注入行（保留同注入体的 icon-font 覆盖），让已接通的制卡后端在两个面上真正可点；同步更新文件头注释说明前提已被 TODO-1188/BUG-730/BUG-751 推翻。提交：7a0e83b3c
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/global_lookup_button_visibility_guard_test.dart` 新增 `BUG-774: global-lookup injection does NOT hide the mine button`：源码扫描断言注入体不再含 JS 字符串字面量形式的 `'.mine-button{display:none`（正则要求单引号前缀，避免匹配到守卫自身注释）。同文件既有 BUG-751 的 opacity:1 守卫一并保留；`test/lookup/` 全 414 例通过。提交：7a0e83b3c
- **备注**：单源文件，无 3-way 镜像（隐藏样式是 Dart 注入非 popup.css）。像素级可见 + 真制卡落库需真机复测（剪贴板查词 + 选中查词各点一次制卡，确认按钮出现且写穿 Anki）。与 BUG-751（同一半透明面按钮 opacity）互补：751 让它不透明，774 让它不 display:none。
