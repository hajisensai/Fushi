## BUG-3272 · 自动重排失败原因被吞且整牌组请求走交互超时
- **报告**：2026-10-10（用户反馈：Anki 绑定 Fushi 的卡组「一直自动重排失败」，附错误日志 `fushi_error_log (4).txt`）
- **真实性**：✅ 真 bug（诊断链断裂，确定）+ ⚠ 超时预算不匹配（真实契约缺陷，是否就是该用户的直接成因未证实）。
  - 用户上传的错误日志（6469 行，Windows）里**一行 Anki 记录都没有**：只有 UpdateChecker / FlutterError / WGC / ffmpeg。
  - 根因一：`fushi/lib/src/anki/anki_auto_reposition.dart` `_runDeck` 两条失败路径——逐卡写回被拒时 `outcome.failures`（每张卡的拒绝原因）被直接丢掉，只调 `_onFailure(deckName)`；整轮抛异常时原因只进 `debugPrint`（release 不可见）。注入点 `anki_view_model.dart` `_withAutoReposition` 只弹「「$deck」自动重排失败」toast。于是用户看到反复失败、开发者拿到的日志里没有任何原因，无从定位。
  - 根因二：`packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart` `listNewCards` / `setNewCardPositions` 走交互用的 10 秒单请求预算（`_getService()`）。它们是整牌组规模：`cardsInfo` 每张卡带渲染好的问答 HTML，本机实测（AnkiConnect，eggrolls-JLPT10k 牌组 10144 张新卡）一批 200 张返回 18.5 MB；写回是每卡一条 `setSpecificValueOfCard` 打成 100 条一批的 `multi`。媒体去重早在 BUG-2824 就因同样理由改走 `kLongTaskTimeout`（5 分钟），重排漏了。大牌组 / 慢机器上会稳定超时 → 每次制卡后都「自动重排失败」。
  - 未复现：本机 Fushi 卡组为空，快机器上单批 0.47 s，未能在本机重现用户的具体失败；用户侧的真实原因要等新版本日志确认。
- **[x] ① 已修复** — 失败上报通道改为 `(deckName, error, stack)`：写回被拒包成 `AnkiAutoRepositionWriteFailures`（失败数 / 尝试数 / 第一条原因），异常原样带堆栈；注入点写进 `ErrorLogService`（`AnkiAutoReposition[<牌组>]`），toast 不变。重排的取卡与写回改走 `_getLongTaskService()`。
- **[x] ② 已加自动化测试** — `fushi/test/anki/anki_auto_reposition_test.dart` 组「失败上报必须带出真实原因（BUG-3272）」：写回被拒时上报计数与原因、整轮抛异常时原异常与堆栈原样上报。超时预算的切换未加测试（`_getLongTaskService` 在注入固定服务时直接返回该服务，单测观测不到超时值；源码扫描守卫价值太低）。
- **备注**：用户可立即在 设置 › Anki › 「按词频重排新卡」手动跑一次——手动路径会把失败原因直接显示在提示条里（`anki_reposition_failed` / 首条失败原因），能先拿到原因再判。
