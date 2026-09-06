## BUG-2144 · KiriKiri2/BCB 上 TJS 抛的 Borland 异常穿透 MSVC catch(...)，注入的每帧求值把游戏打成致命错误框并强制写快速存档
- **报告**：2026-09-04（自查，ceshi 批 galgame 适配 Fate/stay night[Realta Nua] 真机）
- **真实性**：✅ 真 bug，真机复现两次。根因 `native/galgame_hook/hook/adapters/kirikiri_adapter.inc`（改前）`ExecuteTjsExpressionGuarded` / `ExecuteTjsScriptGuarded` / `KiriKiriLookupBootstrapCallback::OnContinuousCallback` 三处用 C++ `try { … } catch (...)` 包住引擎调用。**MSVC 的 `catch(...)` 只认自家异常码 0xE06D7363**；Borland C++ Builder 构建的 KiriKiri2 从 `TVPExecuteExpression` 抛出的是 Borland 异常（SEH 码 0x0EEDFADE），直接穿透我们的 catch 回到引擎事件循环。症状：游戏弹 `Information / 下記のエラーが発生しました … メンバ "fushiLookupNotify" が見つかりません`，并**把当前状态写进用户的快速存档 0 号**（`Documents\FateRealtaNua_savedata\data959.bmp`），控制台 `krkr.console.log` 记 `exception: (object …)"メンバ "fushiLookupNotify" が見つかりません"`。触发路径是稳态的：`PumpKirikiriLookup` 每 30 帧求值一次 `global.fushiLookupNotify` 来探"传感器建立了没"，而传感器未建立时该成员本就不存在——**把 TJS 异常当正常时序信号用**，在 MSVC 上没事，在 BCB 上每次都炸。
- **[x] ① 已修复** — 提交 `3d35edfa02`。(a) 引擎 ABI 边界改用 SEH：新增 `CallTjsExecuteExpressionSeh` / `CallTjsExecuteScriptSeh`（`__except(EXCEPTION_EXECUTE_HANDLER)` 对两家编译器的异常码一视同仁；函数体内不放带析构对象以避开 C2712），`ExecuteTjsExpressionGuarded` / `ExecuteTjsScriptGuarded` / bootstrap 回调三处改走它。(b) 探测方式改成**不依赖异常**：传感器未建立时用 `(typeof global.fushiLookupNotify == "Integer") ? 1 : 0`——TJS2 对不存在的成员 `typeof` 返回 "undefined" 而不抛。两条一起才算修好：只加 SEH 会把异常吞成静默失败，只改 typeof 则别处求值仍可能抛。
- **[x] ② 已加自动化测试** — 真机是唯一能证伪的层（异常码由编译器决定，离线构造不出 Borland 异常）。因此测试落在**可测的不变式**上：源码守卫 `native/galgame_hook/tests/kirikiri_lookup_source_guard_test.py` 的 `find_engine_calls_on_hook_worker` / `find_missing_main_thread_identity_check` 继续锁住调用边界；新增 [[BUG-2121]] 的 `find_addhook_in_bootstrap_precondition` 等规则共 145 条全绿；双架构 CTest 58/58。**真机复验通过**：修复前 helper `c892859b…` 之前的构建 2/2 弹错误框；修复后 helper `2b63903a…` 起同一游戏、跑满 8 轮探针 + 8 次 Enter 推进，`visible windows` 只剩 `TTVPWindowForm` + `TApplication`（无 `#32770` 对话框）、控制台无新 exception 行、游戏正常渲染台词。
- **备注**：影响面是**所有 BCB 构建的 KiriKiri2 游戏**（`ConstSeg/DataSeg/CodeSeg` 段布局那一类），不限本样本。教训写进 [[reference_tjs2_class_member_patch_invisible_to_instances]] 同域：注入代码调宿主 ABI 时，宿主用什么编译器就决定了 `catch(...)` 有没有用；跨编译器边界只能用 SEH。

- **审查补修（2026-09-05 集成时）**：本 bug 的结论适用于**这条边界上的每一次调用**，不只是求值。
  `TJSAllocVariantString` / `tTJSVariantString::Release` 在 KiriKiri2 上同样是 BCB 编译的，
  原实现仍用 MSVC `try/catch(...)` 包着它们（其中一处还跑在 `WH_GETMESSAGE` 钩子过程里，异常会
  穿回 user32 的消息派发帧）。新增 `CallTjsAllocStringSeh` / `CallTjsReleaseStringSeh`，5 处调用
  全部改走 SEH。守卫 `find_cpp_catch_on_tjs_string_abi` 禁止包装之外的裸调用，它当场就抓出一处
  漏网的 `g_lookup_release_string(script)`。详见 [[BUG-2121]]。
