## BUG-4935 · 浏览器扩展查词弹窗不跟随 App 的自动展开行数、词频聚合等显示偏好
- **报告**：2026-11-16（应用内反馈 `ujxK9piTb-`，Windows 3.3.0+24434：「浏览器扩展端未遵循软件内设定的行数限制，默认将词典内容全部展开」「软件内开启词频聚合，扩展查词仍按未聚合显示」）
- **真实性**：✅ 真 bug（沿真实代码路径定位，并用 node 真执行扩展的 `vendor/popup.js` 复现「全部展开」）。
  - 扩展弹窗与 app 内弹窗跑同一份 popup.js，它读一批 `window.*` 显示开关：
    `autoExpandRows`（`tools/browser-extension/vendor/popup.js:6577`）、`collapseDictionaries` /
    `collapsedDictionaryNames` / `expandedDictionaryNames`（`popup.js:6673-6679`）、
    `harmonicFrequency`（`popup.js:4555`）、`showExpressionTags`（`popup.js:4530`）、
    `compactGlossaries`（`popup.js:6764`）。app 内由
    `fushi/lib/src/pages/implementations/popup_settings_injection.dart:1355-1372` 注入。
  - **根因**：`fushi/lib/src/models/app_model.dart` `_browserExtensionThemeColorsFrom`（修复前 :6590）
    给扩展下发的 theme 通道里只有 `--fushi-dedup-pitch`（BUG-2397 只补了这一项），扩展
    `tools/browser-extension/content.js`（修复前 :3632 `fushiApplyTheme`）也只解这一项。其余开关在扩展里恒
    `undefined`：`collapseDictionaries` 缺 → `!window.collapseDictionaries` 恒真，**所有词典全展开**，
    自动展开行数形同虚设（这才是用户看到「全部展开」的直接原因，单补 `autoExpandRows` 修不好）；
    `harmonicFrequency` 缺 → 词频永不聚合；逐本折叠 / 展开名单、表达标签、紧凑释义同样不生效。
    侧边栏（`side-panel.js` `applyLookupTheme`）与嵌套层（`nested-popup.js`）连音调去重都没接。
- **[x] ① 已修复** —
  - app 侧：`popup_theme_css.dart` 新增 `PopupDisplayPrefs` + `buildPopupDisplayPrefsThemeVars`，
    显示偏好的唯一编码点（布尔 `'1'/'0'`、行数整数、逐本名单 JSON 数组）；`app_model.dart` 的
    theme 表展开它，App 当前设置与扩展所选配置视图两条输入路径都填（record 字段必填，漏一路编不过）。
    逐本名单与 in-app 同判据（`isCollapsed` / `isExplicitlyExpanded`，作品配置视图口径一致）。
  - 扩展侧：`vendor/dict-media.js` 新增 `applyFushiPopupDisplayPrefs(theme)`，唯一解码点；页面弹窗
    （content.js）、侧边栏、嵌套层三个渲染面都调它，content.js 原先单独解音调去重的那行并入。
    缺键（旧 app）一律按关 / 未设，与修复前扩展的实际表现一致。
- **[x] ② 已加自动化测试** —
  - `tools/browser-extension/popup-display-prefs.test.js`：解码器真执行；解码结果喂给真 popup.js，
    钉住修复前「全部展开」、自动展开 1/2/0 行、逐本折叠 / 展开压过自动展开、全局折叠关、词频聚合
    开 / 关的实际渲染分支；三个渲染面都经同一解码器。
  - `fushi/test/utils/popup_display_prefs_theme_vars_test.dart`：编码输出 + 编码键集合 == 两份
    dict-media.js 解码键集合（跨语言契约）+ app_model 两路输入接线。
  - `nested-popup-frame.test.js`：嵌套层按同一份 theme 落显示偏好；
    `fushi/test/pages/popup_pitch_dedup_patterns_ipa_test.dart` 守卫随解码点迁移更新。
- **备注**：未在真实浏览器里复测原始失败路径（行为由 node 真执行 popup.js 覆盖）。`hiddenDictionaryNames`
  不在此列：隐藏词典在服务端查词时已过滤（BUG-3454），扩展不需要这份名单。
