## BUG-1703 · 扩展安装/加载失败的根因被 Android 原生 toast 截成 2 行，用户永远看不到
- **报告**：2026-08-17（随 [BUG-1702](BUG-1702-mihon-r8-kotlin-keep.md) 的用户截图暴露：整条错误只显示到 `MihonRuntimeException (LOAD_FAILED): Unabl…`）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/misc/fushi_toast.dart:39`——`FushiToast.show()` 在 `Platform.isAndroid || Platform.isIOS` 时走 `Fluttertoast.showToast`，即**系统原生 Toast**：Android 12+ 强制「app 图标 + 最多 2 行 + 省略号截断」，且不可复制、不可延长、不可交互。调用点 `fushi/lib/src/media/manga/mihon/mihon_extensions_page.dart` 的 5 处 `catch` 全部把原始异常整个塞进这个通道。

  为什么这不是「显示得难看一点」而是功能缺陷：扩展加载失败的可操作信息，全在链式根因的**最深一层**（宿主缺哪个类），也就是消息尾部——恰好是被截掉的那一半。develop 上 `03c98a0828` 已经把完整链式 cause 拼进了异常消息，但**投递通道装不下**，所以修了等于没修；用户既看不到，也无法转述或截图给开发者，只能报「装不上」。BUG-1702 的根因因此只能靠拆 release APK 的 dex 反推，而不是读一行错误。

- **[x] ① 已修复** — 新增 `fushi/lib/src/utils/misc/error_details_dialog.dart` 的 `showErrorDetails()`：全文可滚动 + `SelectableText` 可选中 + 一键复制到剪贴板。把「短状态提示」和「诊断错误」拆成两条通道——前者继续走 toast，后者走对话框。`mihon_extensions_page.dart` 5 处失败路径（加仓库 / 本地安装 / 商店安装 / 预览 / `commitInstall`，其中 `commitInstall` 正是 LOAD_FAILED 的落点）全部改走新通道，该文件已无 `FushiToast` 引用。新增 i18n key `mihon_extension_error`（走 `tool/i18n_sync.dart --add`，17 份齐全后 `dart run slang` 重生成）。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/error_details_dialog_test.dart`（widget 行为层）：① 断言呈现的是完整错误原文且 `maxLines` 为空（不设行数上限）；② 断言点「复制」后写进剪贴板的是**完整**错误。变异实测：给 `SelectableText` 加回 `maxLines: 2`（复刻原生 toast 的截断）→ 测试立刻由绿转红（`Expected: null / Actual: <2>`）；还原后源文件 sha256 与变异前逐字节一致。
- **备注**：
  - 本次只改了 Mihon 扩展页这一处调用点。其余仍把长诊断错误塞进 toast 的路径（Aidoku 扩展页、桌面 Mihon runtime 等）**未**一并迁移，避免把范围扩到未复现的界面；后续按同样形状替换即可，`showErrorDetails` 已是共享入口。
  - 未做：把「诊断错误不得走 toast」升级成全仓源码守卫。判据不好界定（同一个 `FushiToast.show` 既服务短提示也服务错误），过早收紧会误伤大量合法调用点。
