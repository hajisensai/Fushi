## BUG-952 · texthooker 线程下拉 value 与动态 items 失配触发 debug 断言红屏
- **报告**：2026-07-21（PR#295 落地审查 H3，fable5）
- **真实性**：✅ 真 bug（代码路径核验）。根因 `hibiki/lib/src/pages/implementations/texthooker_page.dart:786`：`value: selectedTextThreadKey ?? ''` 与由行 buffer 动态生成的 items 无生命周期联动；清空缓冲或 500 行上限淘汰掉该线程后 value 不在 items 里，debug 触发 DropdownButton 断言。
- **[x] ① 已修复** — `texthooker_page.dart` 下拉 `value` 改为：仅当 `selectedTextThreadKey` 仍在当前 `textThreads` 里才用它，否则回退占位 `''`（「全部」），保证 value 恒在 items 内。
- **[x] ② 已加自动化测试** — `test/pages/texthooker_page_test.dart`「选中线程被行上限淘汰后重建下拉不触发断言（BUG-952）」：先把 session 选到 service 里不存在的线程 key，pump 后 `expect(tester.takeException(), isNull)`。
- **备注**：
