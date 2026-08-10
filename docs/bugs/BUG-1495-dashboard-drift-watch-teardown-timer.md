## BUG-1495 · 首页 dashboard widget 测试全挂：drift .watch() 隔离清单漏了新增消费方
- **报告**：2026-08-11（用户：巡检发现 develop 常驻红）
- **真实性**：✅ 真 bug（测试挂死，非并发伪红）。`develop@0c6ca0a0fd` 上
  `fushi/test/pages/home_dashboard_page_test.dart` **每条用例**都
  `A Timer is still pending even after the widget tree was disposed.`
  （`package:flutter_test/src/binding.dart:2542`，`'!timersPending'`），随后
  `TimeoutException after 0:10:00`。34 条用例 × 10 分钟 ⇒ 整份文件跑不完，
  是「跑很久看似卡死」而不是普通断言红。
  - 挂起的 timer 出处（栈里逐帧）：
    `StreamQueryStore.markAsClosed (package:drift/src/runtime/executor/stream_queries.dart:156)`
    ← `QueryStream._onCancelOrPause (:305)` ← `StreamProviderElement.dispose`
    ← `ProviderContainer.dispose` ← `ProviderScopeState.dispose`
    ← `BuildOwner.finalizeTree` ← flutter_test 用来卸载整棵树的
    `runApp(Container())`（`binding.dart:1959`）。
    drift 在 `markAsClosed` 里排了个 `Timer.run(...)`（零延时），而
    `_verifyInvariants` 紧接着就检查 `timersPending`，中间**没有任何一帧**能让它跑掉，
    所以只要 widget 树里活着一条 drift `.watch()` 流，用例必红。用例体里补 pump 也没用
    ——卸载发生在用例体**之后**。
  - 根因 `file:line`：`fushi/lib/src/media/sources/reader_fushi_source.dart:28`
    的 `_epubBookKeysProvider` 是 drift `.watch()` StreamProvider。测试原本就知道这个
    陷阱、用 overrides 把它的两个派生消费方（`fushiBooksProvider` / `bookLastReadAtProvider`）
    打了桩；但 P3 Stage 1b/2（`7a3505ca7a` / `2ceccf8bda`）在
    `fushi/lib/src/pages/implementations/home_dashboard_page.dart:833` 新增了
    `ref.watch(epubBookUidByKeyProvider)`，而该 provider
    （`reader_fushi_source.dart:79`，内部 `ref.watch(_epubBookKeysProvider)` 在 `:81`）
    没被加进隔离清单 ⇒ drift 流真的开了。
  - 放大成因（真正该修的那一层）：这张隔离清单在
    `home_dashboard_page_test.dart` 里被**抄了三份**（`buildApp` + 两处内联
    `ProviderScope`）。新增一个消费方要三处同时被想起来，结果一处都没被想起来。
- **[x] ① 已修复** — 把三份抄写收成**一份**：新增 `bookStreamOverrides({books, lastReadAt})`
  helper（`fushi/test/pages/home_dashboard_page_test.dart`），三处 `ProviderScope`
  一律 `...bookStreamOverrides(...)`，并在其中补上
  `epubBookUidByKeyProvider.overrideWith((ref) async => <String, String>{})`。
  空表是安全默认：消费侧是
  `lastReadByKey[epubUidByKey[bookKey] ?? bookKey]`（`home_dashboard_page.dart:971`），
  空表即走 bookKey 回退，与 `lastReadAt` 的键域一致，既有断言语义不变。
  产品代码零改动——红的成因在测试宿主的隔离面，不是 dashboard 行为回归。
- **[x] ② 已加自动化测试** — 就是被修复的这份 widget 测试本身；因果链三点实测：
  1. 修前：VERDICT `FAILED`，`宽屏（1280）有数据…` / `窄屏（420）空 DB…` 均
     pending-timer + `TimeoutException after 0:10:00`；
  2. 只给 `buildApp` 补 override 后：前 3 条秒级通过，第 4 条（内联 `ProviderScope`
     的 `BUG-1018…`）仍以**同一条**栈失败 ⇒ 坐实「抄了三份」才是放大器；
  3. 三处统一走 helper 后：`FLUTTER TEST VERDICT: PASSED - 34 tests ran, all tests passed`。
- **备注**：这条与 BUG-1494 同批（清理 develop 上的常驻红）。留一条通用结论：
  **任何 widget 测试只要让 drift `.watch()` StreamProvider 活到 ProviderScope 卸载，
  就必然踩 `timersPending` 断言**；正确做法是把该流（或其全部派生消费方）在
  overrides 里打桩，且清单只留一份。
