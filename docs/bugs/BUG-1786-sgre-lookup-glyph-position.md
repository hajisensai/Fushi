## BUG-1786 · SGRE 内嵌查词读取错误字形坐标导致命中错位
- **报告**：2026-08-24（用户：查词位置很多时候不对，角色台词也受影响）
- **真实性**：✅ 真 bug。真机字形对象显示纹理盒宽高为 `80×80`，相邻日文字形布局锚点却只推进 `25`；`native/galgame_hook/hook/adapters/sgre_lookup.h:121` 原命中矩形直接使用 80 宽度，导致相邻矩形重叠并总是命中更靠左的字。真实 draw 函数还处理 `33×33` UI 小字和空 surface，未分流时会覆盖角色台词几何。
- **[x] ① 已修复** — `native/galgame_hook/hook/adapters/sgre_lookup.h:121` 以同一行下一个/上一个锚点的 advance 收窄命中格；`native/galgame_hook/hook/adapters/sgre_lookup.inc:63` 再按精确 vtable、80-unit 行高/字形和横向 advance 限定角色台词 surface（本提交）。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/sgre_adapter_test.cpp:77` 覆盖 80 宽/25 advance 的相邻字命中和 surface 正负筛选；定向 CTest 通过（本提交）。
- **备注**：角色台词固定设计原点已覆盖；回顾界面的父级动态变换尚未取得可复核坐标，因此本提交会拒绝非角色台词 surface，而不再把它错误映射到角色台词位置。
