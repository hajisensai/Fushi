## BUG-1500 · 词典手动下载与静默自动更新无互斥，共用 import_temp 互相删除
- **报告**：2026-08-11（BUG-1499 修复过程中沿代码路径查出的独立缺陷）
- **真实性**：✅ 真 bug（结构性，未收到用户报告但可达）。两条词典写侧流程各有一个**互不感知**的再入守卫：
  - 手动下载/更新：词典页私有 `bool _isDownloading`
    （旧 `fushi/lib/src/pages/implementations/dictionary_dialog_page.dart:80`，判重在 `:646/1681/1740/1844`）；
  - 启动静默自动更新：`AppModel` 私有 `bool _autoUpdateInProgress`
    （旧 `fushi/lib/src/models/app_model.dart:4085`，喂给 `shouldAutoUpdateDictionaries` 的 `isBusy`）。

  两者谁也挡不住谁，而两条流程的导入**共用同一个** `<词典资源目录>/import_temp` 暂存目录：
  `fushi/lib/src/models/dictionary_import_manager.dart:341-346`（文件路径）与 `:210-215`（目录路径）
  都是「若存在则 `deleteSync(recursive: true)` 再 `createSync`」。并发时后进者会把先进者正在写的
  暂存整棵删掉；更糟的是两边都会「删旧目录 + `deleteDictionaryMeta` 再 publish」（`:391-394` / `:400-408`），
  交错执行可以落成**旧词典已删、新词典没落地**。启动时自动更新与用户点「更新」在时间上完全可能重叠
  （自动更新是 app init 后台起的，不阻塞 UI，用户此刻正好能打开词典页）。
- **[x] ① 已修复** — 两条流程收进同一把锁：app 级 `DictionaryDownloadController.run`
  （`fushi/lib/src/models/dictionary_download_controller.dart`，挂 `AppModel.dictionaryDownloadController`）。
  `run` 在 `isBusy` 时直接返回 false（不排队、不并发）；词典页的 `_isDownloading` 改为读 controller，
  `maybeAutoUpdateDictionaries` 的 `isBusy` 判据也改成 `dictionaryDownloadController.isBusy`，整批跑在 `run` 里。
  手动发起撞上正在跑的静默更新时给一条 `dict_download_busy` 提示（不再静默 return）；
  自动更新撞上手动下载则跳过本轮（check-due 语义，下次启动重来，零损失）。
- **[x] ② 已加自动化测试** —
  `fushi/test/models/dictionary_download_controller_test.dart` 的「BUG-1500 互斥」组（3 条：
  第二次 `run` 被拒且第二个 body 一行不执行、任务结束锁释放、body 抛异常也释放锁）；
  `fushi/test/dictionary/dictionary_download_cancel_guard_test.dart` 的
  「静默自动更新与手动下载共用同一把锁」源码守卫（已变异实测：把 `isBusy` 判据改回本地常量即变红）。
- **备注**：与 BUG-1499 同一批修复落地（同一个 controller 既是任务所有权持有者，也是唯一互斥点）。
