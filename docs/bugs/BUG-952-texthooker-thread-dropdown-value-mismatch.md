## BUG-952 · texthooker 线程下拉 value 与动态 items 失配触发 debug 断言红屏
- **报告**：2026-07-21（PR#295 落地审查 H3，fable5）
- **真实性**：✅ 真 bug（代码路径核验）。根因 `hibiki/lib/src/pages/implementations/texthooker_page.dart:786`：`value: selectedTextThreadKey ?? ''` 与由行 buffer 动态生成的 items 无生命周期联动；清空缓冲或 500 行上限淘汰掉该线程后 value 不在 items 里，debug 触发 DropdownButton 断言。
- **[ ] ① 未修复** — 修法方向：value 不在 items 时回退 null/占位项，或 items 恒含当前选中项。
- **[ ] ② 未加自动化测试** — widget 测试：淘汰选中线程后重建下拉不断言。
- **备注**：
