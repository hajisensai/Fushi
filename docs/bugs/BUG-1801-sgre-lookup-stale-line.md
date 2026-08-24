## BUG-1801 · SGRE 内嵌查词保留旧台词导致查询不实时
- **报告**：2026-08-24（用户：内嵌查词不实时，且角色台词与回顾界面都会取错句）
- **真实性**：✅ 真 bug。真机 ring 证明 UserHook1 `0x328e0` 会在当前画面仍显示上一句时连续发出当前句和后续多句；它是预排版脚本流，不能作为“当前可见句”的权威来源。`native/galgame_hook/hook/adapters/sgre_lookup.inc:63` 原实现把该流与稍后取得的几何拼接，因而会保留旧句或提前切到未来句。
- **[x] ① 已修复** — `native/galgame_hook/hook/adapters/sgre_lookup.inc:221` 改为在 TextRender `0x35aa0` 的真实 draw 边界复制 `visible_glyphs` 个已绘制字符和同一批几何；worker 直接使用一字一 glyph 的结果，不再等待 Luna 选线或归一化 UserHook1 文本（本提交）。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/adapter_structure_test.py:39` 守卫 draw 前快照、禁止恢复 UserHook1/Luna 控制码归一化依赖；定向结构测试通过（本提交）。
- **备注**：2026-08-24 真机新 DLL 已出现符号化诊断 `sensor_installed,geometry_observed`；命中内容和弹卡仍需在过滤版会话完成 Shift 门。
