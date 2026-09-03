## BUG-1732 · manga-ocr-engine-picker-and-model-accounting

- **报告**：2026-08-19（用户：截图两张 + 「这里说一下每个的特点，比如谷歌需要网，但是速度快，质量较本地差」「同时应该支持删除 ocr 模型之类的」「这里显示不对，用的谷歌的怎么还能下载模型」「有这个但好像就删了 450mb 实际上应该有几个 G 好像下的时候」）
- **真实性**：✅ 真 bug（三条症状，同一处设置区）

### 症状与根因

| # | 用户症状 | 根因 `file:line`（修前的 develop `788482ecce`） |
|---|---|---|
| 1 | 引擎下拉只有五个裸名字，挑不出该用哪个 | `fushi/lib/src/media/manga/manga_ocr_settings_section.dart:337-365` —— `items` 每项只有一个 `Text(标签)`，联网/上传/质量/下载量这些**唯一有意义的差别**一个字都没写 |
| 2 | 选了 Google Lens，页面还在劝你下 450 MB 本地模型 | 同文件 `:306` —— 模型块的显示条件只有 `widget.service.isSupportedPlatform`，**与引擎选择完全脱钩**；一个永远用不到本地模型的用户被一直劝下载，且换引擎后那几百 MB 在 UI 上无处可删 |
| 3 | 「删了 450 MB，可下的时候好像有几个 G」 | 两处合力：<br>① `fushi/lib/src/ocr/manga_ocr_service_impl.dart:464-487` —— `downloadedBytes` 只累加**清单里列出且已就绪**的文件，中断留下的 `.part`、上游换档后的遗留档既不显示也不计入，于是「页面上的 450 MB」和「磁盘实际少了多少」是两个数；<br>② 同文件 `:496` —— `deleteModels()` 返回 `void`，删完只弹一句「模型已删除」，**不回报释放量**，用户只能自己去看磁盘；<br>③ 设置区 `:161-192` —— 下载进度直接照搬下载器的**按文件**事件（`event.receivedBytes / event.totalBytes`），一根进度条来回跑四趟（11 MB + 343 MB + 117 MB + 30 KB），把一套 450 MB 的模型感知成「好几个 G」 |

清单四个文件之和 = 11,120,765 + 343,454,249 + 117,480,262 + 30,216 = **472,085,492 B ≈ 450 MiB**，正是用户看到的那个数——所以删除并没有漏删清单内容，对不上的是**记账口径**（清单 vs 磁盘）与**进度呈现**（逐文件 vs 总体）。

### 修复

- **[x] ① 已修复** — commit `<填>`
  - `manga_ocr_service.dart`：`MangaOcrModelStatus.downloadedBytes` → `diskBytes`（语义改为**模型目录真实递归占用**，含 `.part` 与遗留档）+ 新增 `hasAnyFiles`；`deleteModels()` 返回 `Future<int>`（实际释放字节）。
  - 新增 `fushi/lib/src/utils/misc/directory_bytes.dart` 的 `measureDirectoryBytes`：占用统计的单一真相源，不跟随符号链接，单条目 stat 失败跳过。
  - `manga_ocr_service_impl.dart`：`modelStatus()` 按目录实测；`deleteModels()` 先量后删并返回释放量；`ocrFolder` 的就绪闸门改走新的 `_manifestComplete()`（只 stat 清单文件），**不让热路径为了展示去递归扫盘**。
  - 设置区：引擎下拉每项补一句取舍说明（`selectedItemBuilder` 保证闭合态仍是单行）；本地模型区按引擎分三态（用得到 → 完整块 / 用不到但磁盘有文件 → 「用不到 + 占用 + 删除」/ 用不到且干净 → 整块不渲染）；进度按文件名归并成**总体**进度并显示「已下 / 总量」；删除 toast 报实际释放量；模型不全但有残留时同样给删除入口。
  - i18n 经 `fushi/tool/i18n_sync.dart --add` 加 10 个键 × 17 语言 + `dart run slang` 重生成。
- **[x] ② 已加自动化测试** — commit `<填>`
  - `fushi/test/media/manga/manga_ocr_settings_section_ui_test.dart`：`engine dropdown spells out each engine trade-off` / `Google Lens engine never prompts for a local model download` / `local models left on disk stay deletable under a cloud engine` / `ready row reports real disk usage, not the manifest total` / `download progress aggregates every file into one total`。
  - `fushi/test/ocr/manga_ocr_service_impl_test.dart`：`清单外的残留档一样计入占用，并计入删除释放量` / `模型不全但残留占着磁盘：hasAnyFiles 为真，可被删除释放` / `目录不存在：删除返回 0 而不是抛错`。
  - `fushi/test/utils/directory_bytes_test.dart`：4 条（不存在 / 空目录 / 递归 / `.part` 计入）。
  - **变异实测**：把 `_buildLocalModelArea` 的 `if (_localModelsUsedByEngine)` 改成 `if (true)`，`Google Lens engine never prompts for a local model download` 与 `local models left on disk stay deletable under a cloud engine` 立刻转红；反向替换还原后源码 sha256 与变异前一致（`24b93f39ee3338f549406623d5d541100a19560c4328fb169a519457b4cbcb65`）。

### 备注

「下的时候好像有几个 G」还有一条**未被本次修复覆盖**的可能来源：下载器 `_finalizePart` 在长度校验不符时会删掉 `.part` 整文件重下（`manga_ocr_model_downloader.dart:176-183`），网络不稳时**累计流量**确实可能达到几个 G，而落盘恒为 450 MB。本次改动让「要下多少 / 已下多少 / 占了多少 / 释放了多少」四个数字都变成可见且一致的真实值，但没有改重下策略本身；若后续用户仍报「下载量远超 450 MB」，应从这条重下路径查（考虑保留部分 `.part` 或按分块校验续传）。
