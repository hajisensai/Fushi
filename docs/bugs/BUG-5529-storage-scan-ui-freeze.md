## BUG-5529 · 打开 设置 › 存储 扫描期间整窗冻结（有声书逐文件音频路径在 UI isolate 上 O(n²) 去嵌套）
- **报告**：2026-11-26（用户：截图，存储页「总计 0 B · 扫描中…」时整个窗口拖不动、点不了，一直卡到扫描完；Windows 安装版 3.4.0-debug.32705，已含 BUG-5187 的瘦投影修复）
- **真实性**：✅ 真 bug。取证链：
  1. 安装版主线程栈采样（`~/.claude/scripts/fushi-ui-stall/sample.py`，引擎帧用 GUID 一致的 `D:\fe350` PDB 符号化）：开页后连续忙 7.2 s / 10.3 s，Dart 与 VM 运行时各半（分配、`String::SubString`、GC 增量标记），不是安全点 / 锁等待。
  2. 排除项（用户真实数据实测，主 isolate 最长停顿均 ≤52 ms）：后台 isolate 递归扫盘（16.5 GB docs + 17 GB support）、`sync-data` 36,794 个文件的异步逐文件 `length()`、`getAllCollectionItems()` 85,042 行（约 260 ms）。
  3. profile 构建 + 测试根 `D:\hibiki-tmp\storage-repro`（用户库副本 + 同结构零字节文件），经控制通道 `config items storage.cli.categories ls` 跑同一套扫描、VM service `getCpuSamples`：主 isolate 4255 个样本里 3091 个（72%）在 `_scanBooks → resolveBookStoragePaths → _dedupeNestedPaths → _isWithinAny → p.canonicalize / p.isWithin`。
  - **根因**：`fushi/lib/src/storage/storage_usage_service.dart` 的 `_dedupeNestedPaths`（修复后位于 `:369`）对每条路径都临时拼一份「其余全部路径」的列表交给 `_isWithinAny`，后者对每个根重新 `p.canonicalize`——每本书 O(n²) 次规范化 + `isWithin`。有声书的 `audioPathsJson` 是逐文件清单（用户 22 本有声书登记了几千个音频文件），而 `resolveBookStoragePaths` 在 `_scanBooks`（`:865`）里、`Isolate.run` 之前，跑在 UI isolate 上 → 整窗冻结到这一步算完。
- **[x] ① 已修复** — `_dedupeNestedPaths` 改为每条路径只 `canonicalize` 一次：完全重复用 `Set` 判，嵌套改为沿规范化路径逐级 `p.dirname` 查 `Set`（`_hasProperAncestorIn`），O(n · 路径深度)，语义与旧的「`p.equals || p.isWithin` 任一其他路径」等价。复测（同一测试根、同一条控制通道扫描）：扫描 8.9 s → 5.3～5.6 s；主 isolate 采样 4255 → 110 / 839（剩余主要是无关的 TLS / HTTP 后台流量），`_scanBooks` 链 3091 → 36 / 51。
- **[x] ② 已加自动化测试** — `fushi/test/storage/storage_usage_service_test.dart`「resolveBookStoragePaths 去重去嵌套」组：语义用例（目录 + 其下文件 + 尾随分隔符 / `.` 段等价写法 + 同前缀兄弟目录 `Book` / `Book2` + 外部路径，断言保序结果）；规模用例 6000 条路径 < 3 s（旧实现实测 73,100 ms，红）。
- **备注**：`loadStorageVideoRefs` 仍把整张 `media_collection_items`（用户 85,042 行）读进 UI isolate 只为给视频分组，实测约 260 ms、主 isolate 停顿 ≤23 ms，不是本次冻结的原因；可改成 SQL 侧按 `media_type` 过滤 + 取最小合集 id，另行处理。
