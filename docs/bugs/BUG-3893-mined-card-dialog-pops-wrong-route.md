## BUG-3893 · 已制过卡对话框与「未适配视频」提示叠栈后两个都关不掉
- **报告**：2026-10-23（用户：反馈 -EruTk-rWo，Windows，日志 10:33:38 / 10:33:44 两条类型错）
- **真实性**：✅ 真 bug。`fushi/lib/src/anki/anki_mined_card_action_sheet.dart:126`（`_runMineNew`）/ `:152`（`_runOverwrite`），同形还有 note viewer `_overwrite` 与「无法核对」对话框的两个出口：`await` 制卡回调期间，制卡链路经 `onSynchronizedClipTemplateFallback`（`fushi/lib/src/mining/mining_image_mode_target.dart:34`，fire-and-forget）在根导航器上叠出 Kiku「未适配视频」`showAppDialog<bool>`；回调返回后 `Navigator.of(context).pop(AnkiMinedCardActionResult)` 弹的是**栈顶**那个 bool 路由 → `type 'AnkiMinedCardActionResult' is not a subtype of type 'bool?'`；再点提示的按钮 `pop(false)` 落到操作对话框 → 第二次类型错，两个对话框都关不掉。
- **[x] ① 已修复** — 新增 `popAppDialog<T>(context, result)`（`fushi/lib/src/utils/misc/show_app_dialog.dart`）：只关 `context` 所在的路由——是栈顶就 pop，不是就 `navigator.removeRoute(route, result)`；本文件四个「异步动作后关闭自身」的出口全部改用它。提交见 PR pr/fb-mining。
- **[x] ② 已加自动化测试** — `fushi/test/pages/anki_mined_card_action_sheet_widget_test.dart`（「反馈 -EruTk-rWo」两条：新增重复卡 / 覆写期间叠出降级提示，结果回传、操作对话框关掉、提示仍可正常关闭并带回自己的结果、无异常）。
- **备注**：Windows 真 app 未复测（widget 测试按真实叠栈顺序复现）。
