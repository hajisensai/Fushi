## BUG-5427 · 游戏内查词后台写卡失败，app 外查词卡上看不到（BUG-5386 遗留）
- **报告**：2026-11-25（应用内反馈 Va3bdT-X0r：开发者问 BUG-5386 备注里的遗留谁去执行——「后台写卡的结果只在主窗弹 toast，游戏全屏时写卡阶段的失败（Anki 没开）看不到」）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart` `_landLookupMineInBackground`（修前约 :3010）：后台写卡的结局只经 `_reportLookupMine` → `FushiToast.showMine` 画在主窗 Overlay 上；查词卡（`GlobalLookupController` 的 native WebView2 窗口）手里只有 `queued` 回包，宿主没有任何通道告诉它「这张卡后来失败了」，popup.js 的 `queuedLocally` 一直挂着「已加入」✓）
- **[x] ① 已修复** — 后台写卡有了编号：`_mineFromLookup` 回 `queuedPopupReplyFor(job)`（`queuedJob`）。落地 / 失败 / 重新排队经 `GlobalLookupController.settleQueuedMine` 推给当前在场的查词卡（`global_lookup_host.js` `queuedMineSettled` 转进每个卡片 realm → popup.js `window.fushiQueuedMineSettled` 按编号认按钮）。失败：撤掉 `queuedLocally`、就地 `showInlineHint` 说原因；可重试时再点「+」= `retryQueuedMine` 桥，用已做好的画面与句音重写（不重抓已换掉的游戏画面）。查词卡与主窗 toast 的「重试」共用 `QueuedMineJobs` 里同一个一次性入口，不会写两张；入口已失效也回推一条失败说明。落地直接画 ✓（宿主的确定结果，不回查）。主窗 toast 照旧
- **[x] ② 已加自动化测试** — `fushi/test/lookup/queued_mine_settlement_test.dart`（编号 / 一次性重试 / 容量 / wire / 桥接在 deferred 分派之前）；`fushi/test/utils/misc/popup_asset_behavior_test.js`「queued mine settlement」段（node 真跑 popup.js：失败就地提示 + 点 + 走重试不重制、落地画 ✓、toast 重试推 requeued、不可重试 / 重复卡不提示重试、别的编号不认；负向验证过）；`fushi/test/lookup/global_lookup_host_test.mjs`（host 转发进所有已装好的帧、坏载荷不注入）；`fushi/test/lookup/gal_lookup_mine_background_guard_test.dart` 新增 Va3bdT-X0r 用例
- **备注**：推送只送当前在场的查词卡；发起这张卡的查词卡已关 / 已换词时（用户挖完就关卡推进剧情）按编号认不到按钮，结局仍只有主窗 toast——这一段要「下一张查词卡上补报上一张的失败」或游戏内其它表面，属于新 UI，已登记拍板台待定，不在本修复里。真机（游戏全屏 + 关 Anki）复测未做，见 PR。

### 根因

BUG-5386 把查词弹窗的陪等缩到采样为止，写卡结局改由宿主后台结算，但结算只有主窗
toast 一条出口。gal 查词卡是独立的 native WebView2 窗口，游戏全屏时主窗压在后面；
弹窗收到的 `queued` 回包之后再无任何宿主 → 卡片的消息。

### 修复

给 `GlobalLookupController` 加「后台写卡结局」推送（脚本经现有 render 通道下发、
宿主 JS 转进各帧），popup.js 按 `queuedJob` 编号收；失败重试走一次性入口。

审查补（PR #4413）：写卡链路自己的 `MineResult.queued`（本机待发队列 / 批量模式 / 复习
后台队列）`success` 为假，初版把它当 `failed` 推回查词卡——撤掉「已加入」翻回 +、说
「制卡失败」，用户再点就在待发队列里多制一张。改由 `queuedMineOutcomeOf` 判：进队列不推
（查词卡上的「已加入」本来就是真话），测试见 `queued_mine_settlement_test.dart`
「queuedMineOutcomeOf」组与 guard。
