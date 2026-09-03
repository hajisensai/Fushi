## BUG-2090 · overlay 悬浮高亮窗口类每次重建都漏一个 GDI brush
- **报告**：2026-09-03（BUG-2086 引入分层高亮窗后的代码审查副产物，不是用户报告）
- **真实性**：✅ 真 bug（静态追链确认，未做真机 GDI 句柄计数）。**hook DLL 常驻在游戏进程里**，泄漏跟着游戏会话累积。
- **根因**：`native/galgame_hook/hook/lookup_overlay_window.inc` 的 `ApplyLookupHoverHighlight` 里，窗口类注册写在「每次(重)建窗口」的路径上：

  ```cpp
  wc.hbrBackground = CreateSolidBrush(kHoverHighlightColor);
  if (RegisterClassExW(&wc) == 0 &&
      GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return;                    // ← 路径①：注册真失败，brush 没人接管
  }                            // ← 路径②：ALREADY_EXISTS，类不接管这一份
  ```

  而 `DestroyLookupHoverHighlight` **只销毁窗口、从不 `UnregisterClass`**，所以类一直在。overlay 线程 Stop→Start 一轮后 `g_hover_highlight.window == nullptr`，再走一遍这里：`CreateSolidBrush` 成功 → `RegisterClassExW` 返回 0 / `ERROR_CLASS_ALREADY_EXISTS` → **新建的这把 brush 无主**。窗口类只接管注册**成功**那一次传进去的那个句柄。

  路径①是同一个形态的另一条腿（真失败时同样不删）。两条腿的共因是：**资源在「所有权转移」之前无条件创建，而转移只是有时发生**。
- **[x] ① 已修复** — 把「建 brush → 交给类」收敛成**一次性**块（`static bool s_hover_class_registered`），窗口类按其真实语义处理：进程生命期的不可变全局，注册一次即可。类名提成 `kHoverHighlightClassName` 常量，`CreateWindowExW` 不再依赖 `wc` 变量作用域。两条没完成转交的路径就地 `DeleteObject`——全函数只此一处持有未转移所有权的句柄，**不存在第二条泄漏路径可写漏**。
  - 线程安全：本函数只被 `LookupOverlayProc` 的 `WM_TIMER` 调到（overlay UI 线程单线程），故用朴素 `static` 标志而非函数内 magic static——后者首次初始化要拿一把锁，hook DLL 里能免则免（BUG-2046 的教训：hook 进程内的锁会撞 MinHook Freeze）。
  - DLL 卸载时 Windows 连同 `hInstance` 一起注销该类，重新加载后本标志也重置为 false，两者同步，不会出现「标志说已注册、类其实没了」。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/overlay_gdi_ownership_guard_test.py`（源码守卫，已登记 `tools/run_guards.ps1`）：GDI 创建原语在本文件必须**恰好一次**且落在一次性块内；块内创建之后必须有 `DeleteObject`，且创建之后的**每一条 `return` 都必须在 `DeleteObject` 之后**。带扫描规模哨兵（文件长度下界 + 块长度下界 + 「零命中判红」）。
  - **为什么是源码守卫而不是单测**：`lookup_overlay_window.inc` 不进任何 CTest 编译单元（被 hook DLL 的实现文件 `#include`，测试目标不链接它），且症状是「进程常驻期内 GDI 句柄缓慢增长」——单测里既造不出 overlay 线程 Stop→Start 的真实时序，也没有断言点。
  - **登记验证**：故意不登记时 `galhook_workflow_test.py` 元守卫**变红并点名**该文件（本仓踩过「守卫文件存在但 runner 清单没登记 = 从未执行」，BUG-2025）。
- **验证**：x64 与 x86 双架构 `cmake --build` 均 exit 0；两架构 `ctest` 全过；`run_guards.ps1` 全绿。
- **备注**：同文件 `:670` 的 `FushiLookupOverlay` 类注册**没有** `hbrBackground`，不涉及本条；全 native 树只有这一处 `CreateSolidBrush`。**未做真机 GDI 句柄计数复验**——修的是可静态证明的所有权缺口，不是靠观测到的增长曲线。
