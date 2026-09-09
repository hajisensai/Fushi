## BUG-2368 · 「设为常驻来源」选到已登记文件夹时只播裸路径 toast 就返回
- **报告**：2026-09-09（用户：Android 端「导入文件夹 → 设为常驻来源」，「闪了一下文件选择，然后就强制回来了」，随后弹出一条只有 `/storage/emulated/0/Fushi` 的提示）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/media_sources_view.dart:812`（修复前行号）——
  用户选中的文件夹**已经是一条本地来源**，`addLocalFolder` 的去重分支执行
  `FushiToast.show(msg: norm, severity: ToastSeverity.warning)` 后直接 `return`。
  提示语是**归一化路径本身**，没有一个字说明发生了什么，用户视角就是「选完文件夹被强制弹回」。
  全仓只有两处会播这种纯路径 toast（同文件的本地与网络去重分支），本地那处与用户截图逐字对应。

  两层缺陷：
  1. **信息层**：撞重复没有可读提示。同语义的拖放落点早有人话文案
     `drag_drop_folder_source_exists`（`home_video_page.dart:1679`），选择器这条入口漏了。
  2. **行为层**：撞重复直接 `return` 是死胡同。同一个文件里的 `importLocalFolderOnce`
     撞同根时是 `_rescan(row)` 重扫已有行——同一个「文件夹已在库」，两条入口行为不一致。
     用户点「设为常驻来源」的真实意图是「让这个文件夹的内容进库」，根已登记时的正确落地
     是重扫那一行，而不是什么都不做。
- **[x] ① 已修复** — `media_sources_view.dart` 三条撞重复分支（本地 `addLocalFolder`、
  一次性 `importLocalFolderOnce`、网络 `_addNetworkSource`）统一成「说明原因 + 重扫已有行」：
  提示走新增 i18n key `media_source_root_already_added`（路径作参数），随后 `await _rescan(row)`。
  `importLocalFolderOnce` 原本静默重扫，也补上同一条提示——重扫在快速导入区没有可见痕迹。
- **[x] ② 已加自动化测试** — `fushi/test/pages/media_source_duplicate_root_rescan_test.dart`：
  经生产同款入口（`GlobalKey<MediaSourcesViewState>` + `debugRealDirectoryPathOverride` 注入
  选中路径）触发两条本地入口，断言**不插入第二条来源行**且**已有行的 `lastScannedAt` 被推进**
  （`SourceLibraryScanner.scan` 收尾一律写该字段，旧的 `return` 行为下它恒停在预置值）。
  加一条源码守卫钉住「提示不得是裸路径」——桌面 toast 走全局 navigatorKey，widget 测试的树里
  永远没有它，断言 toast 文案是空壳，只能在源码层钉。
- **备注**：`addLocalFolderAsSource`（`media/source_library/add_local_folder_source.dart`）的
  文档注释声称「来源页的『添加本地文件夹』按钮和拖放落点」共用它，实际来源页手写了另一份
  （多一步 `_pickVideoGroupingMode`，去重查 `_rows` 而非 DB）。本次未合并两份实现，只在注释上
  纠正事实，避免下一个人照注释推断行为。
