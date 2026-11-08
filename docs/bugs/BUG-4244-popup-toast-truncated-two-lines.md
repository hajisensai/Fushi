## BUG-4244 · 「保存到」退回主机默认的提示被截断 / 被结果提示顶掉
- **报告**：2026-11-08（服务端 Fushi 复习端到端测试：「保存到」退回主机默认的提示在查词弹窗里只显示到「Cards now go to …」）
- **真实性**：✅ 真 bug，两层。
  - 根因一（截断）：`fushi/lib/popup_main.dart` 的查词弹窗进程从没给 `FushiToast.navigatorKey` 装 key（只有 `main.dart:1227` 装了），`FushiToast.show`（`fushi/lib/src/utils/misc/fushi_toast.dart` 的 `overlay == null` 分支）在弹窗里一律退回原生 Fluttertoast，Android 12+ 的系统文字 toast 最多两行。不是文案问题。
  - 根因二（被顶掉）：这句提示是 `anki_view_model.dart`（修复前 `:762`）在 `onTargetUnavailable` 回调里单独弹的一条 toast，紧接着制卡结果 toast 到来；应用自绘通知只有一个槽位，后到的顶掉先到的。主 app 里一直如此（提示一闪即没），弹窗改用自绘通知后同样。原生 toast 排队，所以之前在弹窗里还能看到被截断的版本。
- **[x] ① 已修复**
  - 弹窗词卡页的 `MaterialApp` 挂一把只给 toast 用的 navigator key（`popup_main.dart:98`、`:238`，`initState` 里交给 `FushiToast`，`:104`），弹窗内提示画成应用自己的通知胶囊（不限行）。不复用 `AppModel.navigatorKey`：那把挂着主 app 的全局弹窗入口。
  - 提示改跟制卡结果走同一条通知：`MineOutcome.success` 加 `notice`（`packages/fushi_anki/lib/src/anki_models.dart`），`RemoteMiningAnkiRepository` 在主机回 `targetUnavailable` 时填上注入的本地化文案（`remote_mining_anki_repository.dart:148`，本类仍无 Flutter 依赖），`describeMineOutcome` 把它接在结果后面并按 `addedWithWarning` 弹（`error_log_service.dart:701-705`；关掉「制卡成功提示」也照样弹）。「保存到」退回默认仍由 `AppModel.createRemoteMiningClient` 做。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/fushi_toast_popup_overlay_test.dart`（自绘胶囊在手机宽度下完整画出三行以上的长句；源码守卫钉住弹窗入口装 key）；`fushi/test/anki/remote_mining_anki_repository_test.dart`「BUG-4244: a reset save location rides on the success outcome…」（含旧主机本地牌组名降级路径）；`fushi/test/anki/describe_mine_outcome_test.dart`「BUG-4244 success + notice」。
- **备注**：模拟器复测：选「保存到 · E2E」，在手机上把 E2E 改名并同步到服务端，弹窗里制卡，结果通知完整显示「Card exported to 『Default』. The paired device no longer offers your chosen save location. Cards now go to its default.」（三行、警示色），「保存到」退回主机默认。已知取舍：自绘提示画在弹窗窗口里，提示消失前关掉弹窗会一起消失。结果为重复 / 失败时不附这句（「保存到」照样退回，设置行可见）。
