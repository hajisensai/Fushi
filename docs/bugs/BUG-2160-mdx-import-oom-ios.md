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

- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：
  - 该词典 389 万条 / 8.6 GB 正文属于极端体量，修复目标是让峰值**随条目数**而非**随正文体积**增长；即便修好，超大词典在低内存 iPhone 上仍可能吃紧，不宣称"任意大小都能导入"。
  - 度量口径：`PeakPagefileUsage`（private commit）而非 `PeakWorkingSet`——后者含 mmap 的 file-backed clean page，OS 可回收，不是被杀的原因。
