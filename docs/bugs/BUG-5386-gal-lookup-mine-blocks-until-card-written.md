## BUG-5386 · 游戏内查词制卡要等写卡结束（约 10 秒）才能挖下一句
- **报告**：2026-11-24（应用内反馈 y90oiVojic：「游戏挖词很慢（约 10 秒，提示成功前不能继续挖）」）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart` `_mineFromLookup` 直接 `await _miningCoordinator.mineLine(...)`；`mineLine`（`fushi/lib/src/mining/gal_hook_mining_coordinator.dart`）虽已拆成采样 / 收尾两条队列，返回的却是收尾 Future——含 ffmpeg 动图编码（默认 avif 很慢）与写卡，弹窗按钮一直锁到写卡结束）
- **[x] ① 已修复** — 协调器新增 `startMineLine`，采样结束即返回 `GalHookMiningTicket`（`captured` + 收尾 `result`），`mineLine` 改为其包装；写卡失败（未配置 / 出错 / 引擎中止）的结果带 `retryWrite`，用已做好的画面与句音原样重写、不重抓窗口。查词弹窗制卡：新卡采样成功即回 `queued`（popup.js 画「已加入制卡队列」✓ 并解锁），落地时 toast 报结局、失败带「重试」、成功补记统计并发 `MinedStateSignal`；采样失败与覆写既有卡仍陪等（与在线视频后台制卡同一模式）
- **[x] ② 已加自动化测试** — `fushi/test/mining/gal_hook_mining_coordinator_test.dart` 「反馈 y90oiVojic」组（写卡被挡时回执已返回；采样失败 captured=false；写卡失败重试不重抓画面 / 句音；重复卡不给重试）+ `fushi/test/lookup/gal_lookup_mine_background_guard_test.dart`（控制器不得退回 await 整张卡）
- **备注**：遗留——后台写卡的结局只走主窗 FushiToast。游戏全屏时主窗在后台，**写卡阶段**的失败（如 Anki 没开）看不到（采样阶段的失败仍随回包在查词卡上就地说）。宿主目前没有往 app 外查词覆盖窗推「这张卡后来失败了」的通道（popup.js 只有 `fushiRefreshMineStates` 重问制卡态）；要补需给 GlobalLookupController 加一条推送 + popup.js 撤掉 `queuedLocally` 并就地提示。→ 已由 BUG-5427 补上（反馈 Va3bdT-X0r）。

### 根因

反馈 U9k4hlYaNZ / EJhUrX_mHY 时已把场景卡拆成 `_captureQueue`（采样，必须趁台词在屏）
与 `_finishQueue`（编码 + 写卡，后台串行）。但唯一入口 `mineLine` 返回的仍是收尾
Future，查词弹窗的 handler（`_mineFromLookup`）await 它后才回包，popup.js 在回包前
`dataset.mining='1'` 锁住按钮——于是拆队列只让「下一张卡的采样不排在上一张写卡后面」，
用户感知的「点了要等 10 秒才能挖下一句」没变。

### 修复

把「采样完成」作为一个可被等待的边界暴露出来（`startMineLine` → `GalHookMiningTicket`），
弹窗只陪到这里；收尾结果改由宿主后台结算。弹窗回包沿用在线视频后台制卡已有的
`queued` 形态，popup.js 无需改动。
