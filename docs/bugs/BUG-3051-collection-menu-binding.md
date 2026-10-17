## BUG-3051 · 合集详情非拖排网格和列表右键菜单绕过快捷键绑定
- **报告**：2026-10-06（PR #1984，e975c16cfb9 的 CI shard 3 两条 context_menu_binding 源码守卫失败）
- **真实性**：✅ 真 bug。CI 精确报出 `media_collection_grid_detail_page.dart` 的两处裸 InkWell；沿真实路径确认 `fushi/lib/src/pages/implementations/media_collection_grid_detail_page.dart:1311`（普通网格）和 `:1415`（列表）直接用 onSecondaryTapUp 调 onMenu，绕过 ShortcutBindingScope：右键被 home 动作占用时仍弹菜单，菜单改绑中键时也不跟随。不是上游 native game stream 远端输入的豁免问题；既有拖排网格已走绑定仲裁，不是本次修复对象。
- **[x] ① 根因修复** — `5ca4ad48aea`：两入口统一包 ContextMenuTrigger，复用默认 home/global 解析阶梯及单次指针认领；保留原主键、长按和带坐标的成员菜单回调。未修改或豁免全树 context_menu_binding 守卫。
- **[x] ② 自动化测试已加入** — 同提交 `fushi/test/pages/media_collection_context_menu_binding_test.dart` 真实挂载合集详情页，分别命中普通网格与列表，验证默认右键只调用一次共享菜单、home 动作占用右键时菜单让位、菜单改绑中键后右键不弹且中键弹、主键仍打开条目。未放宽旧断言或增加 skip。
- **备注**：Dart format 与 git diff --cached --check 已完成；按用户要求不进入本地 heavy 队列，新增 widget 回归与全量 analyze 待 CI 验证，未宣称已运行通过。reader_study_clock_gate_guard_static_test 的另一个失败是统计面板 helper 提取后的旧锚点；同提交按 case → helper → onTogglePause 精确更新，保留全部停表/监听释放断言并新增 helper 不停表约束。
