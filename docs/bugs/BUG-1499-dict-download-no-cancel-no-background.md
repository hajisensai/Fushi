## BUG-1499 · 词典下载进度框无法取消也无法后台化
- **报告**：2026-08-11（用户：「没有取消而且没有隐藏」）
- **真实性**：✅ 真 bug。两条根因都在 `fushi/lib/src/pages/implementations/dictionary_dialog_page.dart`：
  - **不能取消**：`DictionaryDownloader.download` 早就有 `cancelToken` 形参
    （`packages/fushi_dictionary/lib/src/formats/dictionary_downloader.dart:818`，直接透给
    `dio.download`），但**三个调用点一个都不传**（旧 `:929` 在线下载、`:1652` 单本/批量更新、
    `fushi/lib/src/models/app_model.dart:4157` 静默自动更新），进度框也没有任何按钮。
  - **不能隐藏**：任务活在 `_runWithDownloadProgressDialog`（旧 `:1022`）的 `await body(...)` 里，
    进度框 `barrierDismissible: false`，而收尾 `finally` 无条件 `Navigator.pop(context)`（旧 `:1053`）
    ——就算给用户开个口子把框收起来，收尾那一 pop 会**弹掉词典页本身**。任务所有权绑死在对话框上，
    是「收不起来」的结构性原因。
- **[x] ① 已修复** — 把任务所有权从对话框上移到 app 级 `DictionaryDownloadController`
  （新文件 `fushi/lib/src/models/dictionary_download_controller.dart`，挂在
  `AppModel.dictionaryDownloadController`）。对话框退化成它的一个视图：
  - **取消按阶段分权**：`DictionaryDownloadPhase{idle, downloading, importing}`。下载阶段
    `cancelToken` 一置位就断流、temp 目录 `finally` 整棵删（不留半个 zip）；**导入阶段取消按钮禁用**
    并显式说明「导入阶段无法中断」。这不是偷懒——`fushidicts_import`
    （`native/fushidicts/fushidicts_ffi.cpp:250`）起原生线程后 `join(INFINITE)`，C++ 侧零 abort flag、
    零进度回调，Dart 侧还是 `Isolate.run`（`packages/fushi_dictionary/lib/src/engine/fushidicts.dart:465`）
    拿不到句柄；**中途硬断还会落在 `dictionary_import_manager.dart:393` 「删旧目录 + 删 meta」与
    `:405` publish 之间，把用户已有的词典毁掉**。取消的可达时点因此只有两个，且都天然一致：
    下载传输中（词典库一个字节没动）、批量的本间边界（上一本已完整发布）。
  - **隐藏 = 任务与视图解耦**：进度框加「后台继续」按钮（`Navigator.pop` 自己），任务继续在
    controller 里跑；结果 toast 由 controller 自己发（`DictionaryDownloadOutcome`），页面 dispose 了也送达。
    收尾不再由发起方 pop —— 改由活在 dialog route 内的 `DictionaryDownloadProgressAutoCloser`
    监听 `phase == idle` 关自己，用户已手动收起时它早已 dispose，绝不误弹别的路由。
  - **回程入口**：词典管理页顶部新增下载状态行（`_buildDownloadStatusRow`），显示当前进度文案 +
    「查看进度」按钮；无任务时零高度。
  - 新增 i18n：`dict_download_hide` / `dict_download_progress_show` / `dict_download_cancelled` /
    `dict_download_import_uncancellable` / `dict_download_busy`（走 `i18n_sync.dart --add`，17 语言）。
- **[x] ② 已加自动化测试** —
  `fushi/test/models/dictionary_download_controller_test.dart`（11 条：互斥、异常释放锁、下载阶段可取消、
  **导入阶段 requestCancel 是 no-op 且 cancelToken 不被置位**、取消状态每轮重置、outcome 送达、收尾清状态）；
  `fushi/test/pages/dictionary_download_dialog_test.dart`（新增 4 条 widget 测试：取消按钮可点/置灰+说明、
  **收起进度框后任务照跑且词典页不被弹掉、结果仍送达**、任务结束进度框自己关只弹自己）；
  `fushi/test/dictionary/dictionary_download_cancel_guard_test.dart`（5 条源码守卫，四条主张各做过变异实测：
  每个 `DictionaryDownloader.download(` 必须传 `cancelToken:`、任务收尾处禁 `Navigator.pop(`、
  自动更新必须走同一把锁、导入链路禁接受取消令牌）。
- **备注**：用户这次遇到的「30MB 包直连 GitHub 极慢」那条慢因由 BUG-1493 接代理修掉；本条修的是
  与它正交的「等的时候没法退出」。并发缺陷单列 BUG-1500。
