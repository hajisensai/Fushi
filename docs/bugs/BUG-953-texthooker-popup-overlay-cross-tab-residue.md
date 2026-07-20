## BUG-953 · games tab 保活时查词弹窗与 barrier 跨 tab 残留遮挡
- **报告**：2026-07-21（PR#295 落地审查 H4，fable5）
- **真实性**：✅ 真 bug（代码路径核验）。根因 `hibiki/lib/src/pages/implementations/texthooker_page.dart:961-999` + `home_page.dart:898-902`：games 加入 `_keepAliveTabs`（Offstage 保活不走 `deactivate`），而查词浮层/全屏 barrier 插在 root Overlay 且 `_overlayInert` 只在 deactivate/activate 翻转——开着弹窗切到其它 home tab 时弹窗 + barrier 残留覆盖新 tab。home 层保活仍是 Offstage 非 IndexedStack，BUG-750 红线未违反。
- **[ ] ① 未修复** — 修法方向：tab 可见性变化（Offstage 切换）时同步收起/inert 浮层，不能只依赖 deactivate。
- **[ ] ② 未加自动化测试** — widget 测试：games tab 开弹窗→切 tab→断言 Overlay 无残留 barrier。
- **备注**：
