## BUG-153 · 查词结果下拉释放应清空搜索且保持输入态
- **报告**：2026-06-09（用户确认目标：手机端点查词后应该弹出键盘/输入框；电脑端点查词后焦点应该在搜索框里；下拉释义动、松手，应该把搜索框清空）
- **真实性**：✅ 真 bug。根因：`hibiki/lib/src/pages/implementations/home_dictionary_page.dart` 曾把首页查词提交改成先 `_searchFocusNode.unfocus()`，并让返回优先只失焦，错误地把首页查词结果页当成纯浏览态。实际首页查词是输入态：提交后应继续让搜索框获得焦点；释义区的下拉释放才是清空当前 query 的用户动作。
- **[x] ① 已修复**：恢复 `HibikiSearchField.onSubmitted` 直接走 `_search`，移除提交时失焦和返回先失焦逻辑；给首页查词结果区增加下拉释放清空搜索的路径。
- **[x] ② 已加自动化测试**：`hibiki/test/pages/home_dictionary_pull_preserve_query_test.dart` 源码守卫锁定提交查词保持输入态、active query 返回直接清空、结果区下拉释放调用 `_clearSearch()`。
- **备注**：该修复覆盖首页查词 tab；书内/视频查词弹窗没有搜索框，不在本 bug 范围。
