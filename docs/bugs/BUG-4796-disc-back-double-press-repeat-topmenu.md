## BUG-4796 · 原盘正片快速连按两次返回会重复发 topMenu，第二次失败会整盘退出
- **报告**：2026-11-17（维护者自提：PR #3511（BUG-4755）合入后只读核实的遗留缺陷）
- **真实性**：✅ 真 bug。PR #3511 后 `fushi/lib/src/pages/implementations/video_fushi/disc_menu.part.dart:233-239` 的 `_discSessionReturnToMenuOnBack` 每次都 `unawaited(_returnToDiscMenu())`，没有在途标记。`discMenuKey` 要等命令 + 命令后快照（`fushi/lib/src/media/video/video_disc_menu.part.dart:405-410`）才完成，在菜单快照把 `_discSessionSurfaceActive` 翻成 true 之前 `_discSessionBackRoute()` 一直是 `returnToMenu`，第二次返回就再发一次 topMenu；这次若在菜单切换途中失败，会和 BUG-4795 一起落进「任何异常都退会话」的 catch。libbluray 在菜单切换中再收到 menu call 的具体行为未实测。
- **[x] ① 已修复** — `DiscMenuReturn.handleBack`（`fushi/lib/src/media/video/disc/disc_session_controls.dart:178`）在发 topMenu 前置在途标记，在途期间返回直接吞掉（返回 true），完成 / 失败 / 同步抛错后都清标记；已在退出会话（route 为 null）时不拦退出。页面 `_discSessionReturnToMenuOnBack`（`disc_menu.part.dart:234`）委托给它。提交 67249dab0b。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/disc/disc_session_controls_test.dart` 的 `DiscMenuReturn` 组：在途时连按只发一次、完成后下一次照常再发、同步失败也清标记、退出中不被在途请求拦住。撤掉在途判断时变红，已实测。
- **备注**：实盘复测未做（本轮不做真机验证）。页面级按键链只有源码接线守卫，原因见 BUG-4795 备注。
