## BUG-4915 · 互联 host 代跑 OCR：写盘途中任务被取消，晚到的页图仍落进卷目录、状态写回 uploading
- **报告**：2026-11-20（路线图 #3722 第 3 节 c11 遗留「`uploadPage` 在任务被取消后仍把状态写回 uploading」）
- **真实性**：✅ 真 bug（代码路径坐实，无现场报告）。`packages/fushi_engine/lib/sync/fushi_manga_ocr_host.dart` 的
  `uploadPage`（修前 :319-344）只在入口检查一次状态，随后 `await dest.writeAsBytes` 直接写进卷目录，回来无条件
  `pagesUploaded += 1`、`state = uploading`。写盘那段 await 期间 `DELETE` 走 `cancelAndCleanup`（删光页图、出表）或停机
  `disposeAll` 清表，晚到的这页仍留在 `vol_<slug>` 里；同卷下一个任务按卷名落回同一个目录，OCR 枚举会把这张孤儿
  页当成自己的页一起识别，已取消的任务也被写回非终态。
- **[x] ① 已修复** — 先写本任务专属暂存名 `<页名>.<jobId>.part`（不是页图扩展名，枚举不收），写完同步复核
  `_acceptsUpload`（未终态、没在跑、仍是表里那一个），过了才同步改名到位并记账；不收了只删自己的暂存文件、回 `bad_state`，
  不碰同目录别的任务可能写下的同名页。源修改时间设在暂存文件上（改名不动修改时间）。
  同时 `cancelAndCleanup` 的删页改成逐项删、互不连坐：Windows 上在飞上传的子目录删不掉时，旧实现整个循环中止，排在后面的
  页图全留下（这条用例在 Windows worker 上首跑即红，暴露的就是它）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/fushi_sync_server_manga_ocr_test.dart`「page upload racing a cancel leaves no
  page and no uploading state」：上传在飞时取消，断言回 `bad_state`、状态仍是 cancelled、卷目录无文件，同卷新任务只看得到
  自己的页。
- **备注**：没有 HTTP 层的真并发用例（测试直接驱动管理器）；双设备互联复测见路线图第 4 节。
