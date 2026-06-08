## BUG-153 · 查词结果浏览时输入框保持聚焦导致返回/下拉后清空搜索
- **报告**：2026-06-09（用户：点查词会自动出来输入框；手机端弹输入框，电脑端焦点留在输入框；下拉释义并释放会清空搜索框）
- **真实性**：✅ 真 bug。根因：`hibiki/lib/src/pages/implementations/home_dictionary_page.dart` 的搜索提交直接把 `HibikiSearchField.onSubmitted` 接到 `_search`，没有退出 `_searchFocusNode`，结果页仍停留在编辑状态；同一页 `PopScope.onPopInvokedWithResult` 在有 query 时直接 `_clearSearch()`，没有先处理“输入框仍聚焦”的第一段返回/关闭键盘语义。移动端表现为查词结果出现时键盘/输入框仍打开，桌面端表现为焦点继续落在搜索框；用户在结果里下拉/释放或关闭输入状态时，页面会走清空 query 路径。
- **[x] ① 已修复**：新增 `_submitSearch()`，提交搜索时先 `_searchFocusNode.unfocus()` 再 `_search(query)`；`PopScope` 在 `_searchFocusNode.hasFocus` 时先只失焦，第二次返回才 `_clearSearch()`。
- **[x] ② 已加自动化测试**：`hibiki/test/pages/home_dictionary_pull_preserve_query_test.dart` 源码守卫锁定提交搜索必须释放焦点、返回先只退出输入状态、结果浏览层不从拖拽释放路径清空搜索。
- **备注**：该修复覆盖首页查词 tab；书内/视频查词弹窗没有搜索框，不在本 bug 范围。
