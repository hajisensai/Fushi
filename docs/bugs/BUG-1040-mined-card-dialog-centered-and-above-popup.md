## BUG-1040 · 「卡片已在 Anki 中」是底部 sheet 且层级低于查词弹窗（被盖住看不见）
- **报告**：2026-07-23（用户：qqbotxiaoxiao，原话「并且不应该是底部弹窗，应该是中间的弹窗。层级也不对，他的层级比查词弹窗的低。导致看不见」，附视频页截图：sheet 贴在窗口下沿、进度条被窗口边缘裁掉）
- **真实性**：✅ 真 bug，两个独立缺陷叠在同一个 UI 上。
  1. **形态**：`hibiki/lib/src/anki/anki_mined_card_action_sheet.dart` 的
     `showAnkiMinedCardActionSheet` 用 `showModalBottomSheet`。这是个「必须当场做决定」的
     模态选择（覆写哪张 / 新增重复卡 / 去 Anki 看），不是可下拉浏览的内容面板；贴屏幕下沿
     在视频页会被播放器控件与窗口边缘裁掉半截。同族的 `showAnkiNoteViewer` /
     `SentenceContextDialog` 本来就是居中 `AlertDialog`，形态不一致。
  2. **层级**：查词弹窗是**原生平台视图**（桌面 `flutter_inappwebview_windows` 的 WebView2 /
     Android `InAppWebView` platform view），靠 airspace **永远画在 Flutter 层之上**——不是
     `OverlayEntry` 顺序问题，改成根 Overlay 顶层 entry 也照样被盖。这与
     [BUG-797](BUG-797-sentence-context-dialog-behind-popup.md)（「选择句子上下文」对话框被
     弹窗盖住）是**同一个根因**，只是当时只给那一个对话框打了补丁：
     `base_source_page.dart` / `dictionary_page_mixin.dart` 各有一个 `bool
     _sentenceContextDialogOpen`，只与句子上下文对话框接线，`runAnkiMinedCardAction` /
     `openMinedCardInAnki` 这两条同样弹 Flutter 对话框的路径没接上 → 照样被弹窗盖住。
- **[x] ① 已修复** — 两处一起根治：
  - **形态**：`showAnkiMinedCardActionSheet` 与 `showAnkiOpenNotePicker` 都改走 `showAppDialog`
    居中 `AlertDialog`（`_MinedCardActionSheet` → `_MinedCardActionDialog`）。命中列表放在
    有界高度的 `Flexible + shrinkWrap ListView`（多张时列表自身滚动），「新增为重复卡」升为
    对话框 action 按钮并补「取消」。制卡/覆写有副作用，故 `barrierDismissible: false`，
    误触遮罩不会丢掉整次操作。窄屏取可用宽度九成、宽屏 420，避免横向溢出。
  - **层级**：把 BUG-797 的单一布尔**泛化**为可嵌套的计数 `int _popupHidingDialogDepth` +
    统一入口 `runWithLookupPopupHidden<T>(body)`（两车道各一份，收口 setState 增减，
    `finally` 复位不漏）；`parkedPopupLayer` 的 `visible` 改与 `_popupHidingDialogDepth == 0`
    相与。改计数而非布尔是必需的：动作对话框里还能再叠一层 note viewer 对话框，用布尔会被
    内层 `finally` 提前复位、外层对话框当场被弹窗盖回去。
    新增可选参数 `LookupPopupHiddenRunner? runHidden` 传进 `runAnkiMinedCardAction` /
    `openMinedCardInAnki`，两车道四个调用点全部接上。刻意**只包住对话框可见那一段**、
    不包 `findMatchingNotes`——反查是网络往返，Anki 不可达时会等到超时，若一起藏就会出现
    「弹窗凭空消失好几秒又回来、期间什么都没弹」的空窗。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/sentence_context_dialog_zorder_guard_test.dart`
  （原 BUG-797 守卫扩写）：钉死两车道的计数字段、统一入口签名、setState 增减、
  `parkedPopupLayer.visible` 相与表达式，以及三个调用点都接上入口（`runHidden:` 至少两处）；
  新增一条钉死「本文件不得再出现 `showModalBottomSheet`、动作框与选择框都走 `showAppDialog`、
  且禁用 barrier 关闭」。airspace 是原生合成层，无头测试照不到，故仍用源码扫描守卫。
- **备注**：**待用户真机复验**（Windows 视频页）：查词 → 点「✓」→ 对话框居中显示且完整可见、
  查词弹窗在对话框期间让位、关闭后回位；「在 Anki 中打开」命中多张时的选择框同理。
  性能侧（制卡/覆盖巨慢）是另一根因，见 [BUG-1039](BUG-1039-native-tier-gif-explodes-mining.md)。
