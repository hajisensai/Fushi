## BUG-1830 · mokuro 卷子目录布局导入必失败（img_path 裸文件名）
- **报告**：2026-08-24（用户：wrds）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/manga/manga_importer.dart:226`（修复前）
  `final Directory srcDir = mokuroFile.parent;` —— 页图根被**硬编码**成「`.mokuro` 同级」，
  但 mokuro 的 `img_path` 有两种并存惯例：
  - 惯例 A：`img_path` 自带卷名/`images/` 前缀（如已入库的「あつまれ！ふしぎ研究部」）→ 同级解析恰好命中；
  - 惯例 B：**卷子目录布局**，`img_path` 是裸文件名（`DLRAW.TO_00001.jpeg`），页图躺在与
    `.mokuro` 同名的子目录里 → 解析成 `<父目录>/DLRAW.TO_00001.jpeg`，文件不存在，
    `planMangaDestRels` 抛 `Missing manga page image`，整卷导入必失败。

  同一个错误假设**在三处各写了一遍**，所以远端来源库扫描（`source_library_scanner.dart`
  的 `_importMangaRemote` 按 `page.url` 直接查远端相对路径表）对惯例 B 同样必失败——
  这是同源分身，不是另一个 bug。

  更糟的是准入判定 `mangaImportCanImport` 会往下探**一层子目录**找图片，把惯例 B 判为
  「可导入」：**门放行、执行必失败**。门与执行是两套判据，这才是「一位两义」的来源。

  可观测性同时有两个洞，导致事后无从定位：
  - 批量导入把逐卷异常收进 `MangaBatchImportReport` 后**只 `debugPrint`**，
    `ImportFlowMixin.runImport` 那道 `ErrorLogService` 落盘永远拿不到真正的原因 →
    错误日志页 / `error_log.txt` 里翻不到；
  - 失败 toast 走默认 `Toast.LENGTH_SHORT`（桌面 2000ms，含两端 200ms 淡入淡出，
    实际可读约 1.6s），一条带路径的长错误读不完就消失。

- **[x] ① 已修复** — 提交哈希见下方「备注」补记。根因修复，不是加参数绕过：
  1. 新增**唯一**页图根解析原语 `resolveMokuroPageRoot` / `mokuroPageRootCandidates` /
     `joinMokuroPageRoot`（`fushi/lib/src/media/manga/mokuro_payload.dart`）。零 IO：
     存在性探针由调用方注入，本地传文件系统 stat、远端传相对路径查找表，于是
     **本地导入器与远端扫描镜像共用同一份判据**，不再各写一遍。
     候选**只有**两个（就地 / `<卷名>/`），卷名取自 `.mokuro` 文件名本身（与卷 1:1），
     不扫「任意子目录」——否则同批次里 `001.jpg` 这类无卷前缀的页名会误绑到别卷。
  2. `importFromMokuroPath` 改为**解析**页图根；顺手删掉它原先那道
     `mangaImportCanImport` 前置判据——那是真校验的一个更弱的重复副本，
     正是「门放行 / 执行失败」两义的产地。真校验 = 解析根 + 逐页存在性。
  3. `mangaImportCanImport` 契约写清：它是**载体分类**（廉价、宽松），不是导入成功的
     保证；真校验在导入器内。门保持宽松是有意分工，不是遗漏。
  4. `_importMangaRemote` 用同一原语解析远端页图根，并**连根一起原样镜像**到临时目录，
     使镜像布局与远端逐段同构、本地导入器再解析一次即命中。
  5. 两种惯例都不成立时，错误文案**逐条列出搜过的目录**
     （`Missing manga page image: X (searched: <同级>, <同级>/<卷名>)`），
     候选与文案共用 `mokuroPageRootCandidates`，日后加惯例不会只改一处让文案说谎。
  6. 逐卷失败原因落盘挪到**吞掉异常的那一层**（`_importOneVolume` 的 catch，
     source=`MangaBatchImport.volume`），而不是某一个对话框——报告有多个消费方。
  7. 导入失败 toast 提到 `Toast.LENGTH_LONG`（`ImportFlowMixin.runImport`）。

- **[x] ② 已加自动化测试** — 全部做过变异实测（去掉修复 → 变红；还原后 sha256 逐字节比对一致）：
  - `fushi/test/media/manga/manga_importer_test.dart`（4 条新增）
    - 卷子目录布局（裸 `img_path`）从 `<卷名>/` 解析页图并成功导入（含页图**字节**比对）
    - 准入判定放行的卷子目录布局，执行也必须真能导入（门与执行不再两义 —— 就是这个 bug 的成对复现）
    - 卷子目录只绑自己那一卷，不会误取同批另一卷的同名页图（钉死候选集不许扩成「任意子目录」）
    - 两种布局都不成立时，错误文案指名道姓列出搜过的目录
  - `fushi/test/media/source_library/source_library_scanner_network_test.dart`（1 条新增）
    - 远端漫画：卷子目录布局也能镜像并导入（变异下复现 `Missing manga page image: DLRAW.TO_00001.jpeg (searched: /remote/manga)`）
  - `fushi/test/media/manga/manga_folder_batch_test.dart`（2 条新增）
    - 坏卷的真实原因写进 `ErrorLogService`（含卷名），而不是只 `debugPrint`
    - 全成功时不往错误日志塞噪声

- **备注**：`importFromMangaJson`（内部 `manga.json` 格式）不在此列——它只有一种惯例，
  且页图根由调用方通过 `imageRootPath` 显式传入，没有「必须猜」的问题，刻意不动。
  用户报告里「snackbar 只活约 1.1 秒 + `error_log.txt` 不落盘」两条已分别由第 6、7 项处理；
  真机端到端复测未做（本轮为自动化测试覆盖，缺口如实记在此）。
