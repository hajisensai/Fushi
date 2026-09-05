## BUG-2160 · iOS 导入大 MDX 词典闪退：整本词典在内存里物化，jetsam 直接杀进程
- **报告**：2026-09-05（用户：`C:\Users\wrds\Downloads\QQ\Wuliyanquan.mdx` iOS 导入闪退）
- **真实性**：✅ 真 bug。根因不是崩溃而是 **OOM 被系统杀**——iOS jetsam 对超预算进程直接 SIGKILL，没有异常、没有崩溃日志、Dart 侧 `_isMemoryError` 也捕获不到，表现就是"闪退"。

  样本词典实测（本机 Windows，同一份 C++ 引擎）：文件 389.5 MB（408,429,503 B），**3,898,901 条**，解压后正文 **8,845 MB**（22 倍压缩比）。

  导入链路上有 **四处**把「整本词典」同时留在内存里：
  1. `importer.cpp:1296` `import_mdx` 用 `std::vector<uint8_t> data(size)` 整文件读入 → 389 MB
  2. `mdx_reader.cpp:501` `parse_container` 把**全部** record block 解压进一个 `all_records` → 8.6 GB
  3. `mdx_reader.cpp:544` `parse()` 再为每条 entry 拷一份 `std::string` → 又一份 8.6 GB
  4. `importer.cpp:1863` `write_simple_dict` 先把**整个 glossary blob 区**攒进 `glossary_buf` 再一次性写出，
     而 `processed.glossaries`（hash → 压缩 blob 全量去重表）本身已经持有同一份数据 → 1.24 GB × 2

  实测峰值 private commit（jetsam 计的就是这个口径，mmap 的 clean page 不计）：
  | 路径 | 峰值 |
  |---|---|
  | `mdx_reader::parse()`（物化全部条目，旧设计） | **10,800 MB** |
  | 修复前完整 import | 装不下（本机 12.9 GB 量级） |

  iPhone 的 jetsam 预算约 1.2 GB（3 GB 机型）～3 GB（6 GB 机型），差了一个数量级，**必杀**。

- **[x] ① 已修复** — 四处「整本物化」逐个消除，导入峰值随**条目数**而非**正文体积**增长。
  - `import_mdx` 改走既有的 `memory::map_rd`（mmap）。mapped clean page 是 file-backed 的，
    OS 可回收，不进 private commit，整文件 buffer 归零。
  - `parse_container` 拆成 `parse_container_index`（只解码 header + key 表 + 块表）
    + `stream_records`（滑动窗口逐块解压、发出即弃）。`all_records` 消失。
  - `@@@LINK=` 重定向改在**索引层**解析：链路只走 key index，再按目标分组、
    用 `extract_records` 只解压含目标的块，正文只在回调期间存活。
  - `SimpleEntryAccumulator` 拿到打开的 `blobs.bin`，新 glossary 当场压缩写盘，
    内存只留 `hash -> (offset, size)`；`glossary_offsets` 回填数组与
    `glossary_buf`（blob 区的第二份全量副本）一并消失。
    落盘拆成 `open_simple_dict`（先建目录，供流式写入）+ `finish_simple_dict`。
  - 顺带修掉一个潜在缺陷：旧代码某 record 块解压失败时不追加字节却保留其跨度，
    会让**其后全部** entry 的切片错位；现改为跳过该块内 entry 并重新对齐。
  - StarDict / DSL 共用同一累加器，同样受益。公开 header `importer.hpp` 一字未改。
  - 提交：`f319af3b43`（解析侧）+ 本轮（写盘侧）

  实测（用户原文件，同一台机器）：
  | 阶段 | 峰值 private commit |
  |---|---|
  | 旧设计 `mdx_reader::parse()`（仅解析） | 10,799 MB |
  | 仅改流式解析 | 4,636 MB |
  | 再加 blob 边压边写 | 1,437 MB |
  | 再加就地偏移 + 预分配 | **1,210 MB** |

  产物正确性：`blobs.bin`(1,531,377,360 B) / `hash.table` / `bloom.filter` / `index.json`
  与改造前**逐字节相同**（SHA-256 一致），条目数 3,898,901 不变，耗时 21.5s 不变。

- **[x] ② 已加自动化测试** —
  - `native/fushidicts/tests/mdx_streaming_blocks_test.cpp`（新增，ctest 29/29）：跨块记录、
    滑动窗口进位、跨块正/反向重定向、跨块链式重定向、分块方式不影响结果、
    `parse` 与 `parse_streaming` 一致。`mdx_fixture` 新增 `build_mdx_record_splits`
    可指定分块边界——原有 fixture **全是单块容器**，结构上覆盖不到这些路径。
    **变异实测**：打断窗口进位后该测试全红，而 `mdx_redirect_lemma_lookup` /
    `mdx_encrypted_keyinfo` / `mdd_media_import` **依然全绿**，证明旧套件抓不到这类回归。
  - `fushi/test/dictionary/mdx_block_bounds_guard_test.dart`：OOB bound 守卫按新形状重写
    （不是绕过），并新增「不得再出现 all_records」。
  - `fushi/test/models/dictionary_multi_archive_import_test.dart`：BUG-1904 上限守卫改锚
    累加器类体；新增「整表入口与流式入口共用同一累加器」与「glossary blob 必须边压边写」。

- **备注**：
  - 该词典 389 万条 / 8.6 GB 正文属于极端体量。修复后 1,210 MB 仍**不是小数字**：
    6 GB 机型（jetsam 预算约 2.5–3 GB）应当能过，3 GB 老机型（约 1.2 GB）仍在边界上，
    **不宣称"任意大小词典都能在任意 iPhone 上导入"**。普通体量词典（十万条级）
    现在的峰值只有几十 MB。
  - 剩余大头已定位、本次未动：`keys` 表（389 万条 headword，约 300 MB，是解析必需的索引，
    要再降需把 headword 改成连续 blob + 偏移数组）；`records_.data`/`offsets`（约 210 MB）。
  - **iOS 侧未真机验证**：本次全部实测在 Windows 上跑同一份 C++ 引擎（内存行为同源，
    但 jetsam 判定是 iOS 特有的）。要坐实"用户那台设备不再闪退"，需在 iOS 真机复跑原始导入路径。
  - Yomitan 路径仍有同名 `glossary_buf`，但它是**按 bank** 缓冲（受单 bank 大小约束），
    不是整本词典，本次有意未改。
  - `low_ram` 形参只作用于 Yomitan 路径的线程数，MDX/StarDict/DSL 从来没有任何低内存适配；
    现在这条路径无条件低内存，不再需要开关。
  - 度量口径：`PeakPagefileUsage`（private commit）而非 `PeakWorkingSet`——后者含 mmap 的
    file-backed clean page，OS 可回收，不是被杀的原因。
