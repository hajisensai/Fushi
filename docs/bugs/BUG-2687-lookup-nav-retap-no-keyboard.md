## BUG-2687 · 已在查词页再点查词不弹键盘
- **报告**：2026-09-26（用户：在查词模块下再按「查词」要弹起键盘）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_dictionary_page.dart` 的 `_clearSearch` / `_applyFocusRequest` 只调 `_searchFocusNode.requestFocus()`；移动端「焦点在、键盘不在」是常态（提交收键盘 BUG-2686、系统返回键收键盘），此时 requestFocus 是空操作，底栏再点「查词」框清空了键盘却不弹。
- **[x] ① 已修复** — 新增 `_focusSearchField()`：取搜索框的 `EditableTextState.requestKeyboard()`（没焦点就聚焦，有焦点就再向输入法要一次键盘，即「点一下输入框」的语义），`_clearSearch` 与 keepQuery / selectQuery 三处聚焦统一走它。提交：见 PR 分支 `pr/lookup-ime-submit`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dictionary_nav_tap_focus_test.dart`「BUG-2687 已在查词 tab、键盘已收起：再点「查词」重新弹起键盘」；源码守卫 `home_dictionary_pull_preserve_query_test.dart` 同步改为钉 `_focusSearchField();`。
- **备注**：未上真机复测。
