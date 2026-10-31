## BUG-3894 · 移动端转录弹层点外部或下拉即关闭并中断转录
- **报告**：2026-10-28（用户 🙃，QQ 群经 fushi-bot 代提，反馈 NrRPRDTprI；Android 平板骁龙 8 Gen3，转录约十分钟，转到一半误触遮罩直接中断）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/audiobook/asr_transcribe_sheet.dart:149`（基线 896d45a9b2）移动端走 `adaptiveModalSheet<String>`，而 `fushi/lib/src/utils/adaptive/adaptive_widgets.dart:335` 的 `adaptiveModalSheet` 没有可关闭性参数：所有分支（MD3 底部弹层 / 宽屏浮动面板 / Apple 移动与桌面 sheet / Cupertino popup）都固定点遮罩关闭、整块下拉与拖动条下拉关闭；弹层关闭即在下一个检查点暂停并释放会话。桌面分支早已 `barrierDismissible: false`。
- **[x] ① 已修复** — 036f3c66d8：`adaptiveModalSheet` 新增 `isDismissible`（默认 true，行为不变），false 时各分支关掉遮罩点击与下拉关闭（`showModalBottomSheet` 的 isDismissible / enableDrag、`FushiDialogRoute` / `showGeneralDialog` / `showCupertinoModalPopup` 的 barrierDismissible、`FushiM3eSheetBody` / `_LiquidSheetBody` 拖动条下拉只收回展开档不再 pop）；Esc / 手柄 B / 系统返回与弹层内按钮照常关闭。转录弹层移动端分支传 `isDismissible: false`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/adaptive_modal_sheet_dismissible_test.dart`（MD3 窄屏 / MD3 宽屏 / Apple 移动三种形态：isDismissible=false 点遮罩、下拉不关、maybePop 仍关；默认点遮罩关闭；源码钉住转录弹层移动端调用带 `isDismissible: false`——该分支在桌面测试宿主上走不到）。
- **备注**：未在 Android 真机验证（本机 widget 测试覆盖同一套路由参数）。系统返回键仍会关闭并暂停转录（明确意图，与桌面 Esc 一致）；是否加二次确认属于产品取舍，未做。
