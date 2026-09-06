## BUG-2110 · 一次性导入大量词典后启动转圈中途闪退

- **报告**：2026-09-04（用户：手机上一次性导入太多词典后，点 fushi 一直转圈进不去、没有任何报错；转到一半应用自己退出）
- **真实性**：✅ 真 bug。启动路径上有四处与词典数量成正比的缺陷，其中第一处能单独解释「无报错静默退出」这个症状。

### 根因（四处，均在启动的词典装载链上）

1. **FFI 边界没有异常闸门** — `native/fushidicts/fushidicts_ffi.cpp`（修复前 23 个 `FUSHI_EXPORT` 只有 `fushidicts_import` 一个带 try）。
   `extern "C"` 不是异常边界：C++ 异常从导出函数逃出去 = `std::terminate` → SIGABRT → 进程当场消失。Dart 侧的 try/catch、错误屏、日志落盘全都够不着，所以用户既看不到崩溃提示也拿不到日志。词典越多，启动经过 `add_*_dict` / `lookup` 的次数越多，撞上 `bad_alloc` / `filesystem_error` 的概率线性上升。
   同一现场还有一批未检查返回值的 `malloc`：失败后照样往 null 指针里写 = SIGSEGV，同样静默。
2. **每本 kanji 词典每次启动都被全表重扫** — `fushi/lib/src/models/app_model.dart` 的 `_migrateDictionaryTypes` → `native/fushidicts/fushidicts_src/query.cpp:716` `probe_dict_content`。
   探测把整张 hash 表扫完、逐槽随机跳读 `blobs.bin`，早停条件是「term + kanji 都找到」，纯 kanji 词典永远凑不齐，扫的就是全表。而探测结果**只在需要改判类型时**才写 metadata，于是「没探过」和「探过、无需改判」在数据上不可区分，每次启动重来一遍。手机冷缓存下是每本几万次随机页访问。
3. **写一次词典元数据就全量重建一次引擎（O(N²)）** — `dictionary_repository.dart` 的 `_onCacheRebuild` → `app_model.dart` `_rebuildDictPathsCache` → `FushiDicts.initializeTyped`。
   重建 = 卸掉全部词典的文件映射再逐本装回，代价与当前总词典数成正比；而写元数据是逐本发生的（导入每本、类型自愈每本）。导第 100 本要把前 99 本卸了再装回去。
4. **启动期词典工作全在主 isolate 同步跑，两层看门狗因此失效** — `app_model.dart` 的 `_rebuildDictPathsCacheAsync` / 启动预热。
   装载与 lookup 都是同步 FFI。`_guardInitIo` 的 12 秒超时和 `main.dart:684` 的 20 秒「加载太久」逃生 UI 都是 Timer，被同步代码堵住的事件循环根本轮不到它们——于是「慢」变成「无逃生口地卡死」，正是用户看到的一直转圈。

### 修复

- **[x] ① 已修复** — 见下方逐条对应：
  1. 加 `ffi_guard` / `ffi_guard_or` / `ffi_guard_void` 三个闸门原语，23 个导出无例外经过；异常在闸门内记日志并返回零值结果，Dart 侧走既有空结果分支。裸 `malloc` 收进 `alloc_array`：分配失败即把 count 归零，「count 非零但指针是 null」这个状态不再可构造。
  2. 新增 `kDictTypeProbeKey` / `kDictTypeProbeVersion`（`packages/fushi_dictionary/lib/src/engine/dictionary.dart`）把「探过」变成一等状态，探测结果无论是否导致改判都落库；导入路径直接写标记（native 导入时已数过 term/kanji 记录，无需再探）。存量词典第二次启动起零 IO。
  3. `FushiDicts.scheduleTyped` 只排期、`instance` / `dictionaryStyles` 用前结算：批量写入期间没人查词，N 次排期塌成 1 次装载，且不依赖任何调用方声明「我是批量的」。删词典目录路径不受影响——它走的是 `releaseAllMappings()`（立刻卸载映射，现在连待办一起清）。
  4. `FushiDicts.loadPendingAsync` 每装一本让出一次事件循环（用 `Future.delayed` 而非 `await null`，microtask 让出救不了 Timer），装载在影子实例上进行、装完才原子替换，让出期间的查词看到的是完整旧集合；并发排期按代次作废。启动预热改为等首帧之后、串行 + 每次之间让出。
- 修复提交：`3486b42ab7`（闸门 + malloc 收口）、`d3e084b671`（探测标记 + 排期结算 + 分批让出）。

### 测试

- **[x] ② 已加自动化测试**：
  - `native/fushidicts/tests/ffi_guard_coverage_test.cpp` — 源码扫描守卫：每个 `FUSHI_EXPORT` 的函数体（精确花括号配对，不是固定窗口）必须走闸门；闸门原语必须存在；导出数量下界防锚点漂移。已注册进 ctest 并登记进 `native_test_harness_guard_test.dart` 的清单，掉不出 CI。
  - `fushi/test/models/dict_engine_pending_load_test.dart` — 排期只排不装、连续排期只保留最后一次、空集合同样排期（BUG-171）、`releaseAllMappings` / `disposeInstance` 连待办一起清、`isInitialized` 覆盖「已排期未装」。
  - `fushi/test/dictionary/dict_type_probe_marker_test.dart` — 探测标记语义：缺席/旧版本/垃圾值都要重探，「探过」与「有 kanji 内容」互不反推，标记随 JSON 往返存活。
  - 更新既有守卫锚点：`dictionary_delete_engine_reload_guard_test.dart`（认排期与立刻两种表达，并新增「启动路径必须自己结算」断言）、`mixed_dict_reclassify_guard_test.dart`（新增「探测结果必须落库」断言）。
  - 两条新守卫都做了变异实测：摘掉一个导出的闸门 / 让 `scheduleTyped` 不覆盖已有待办，对应断言都会红并准确点名（第一版 `ffi_guard_coverage_test` 用固定 400 字符窗口，变异下仍 PASS——窗口越过函数结尾命中了下一个函数的闸门，已改为精确配对）。

### 备注

- **未定性的一半**：「native abort」与「Android 低内存杀进程」在用户视角完全一样（都是无提示消失），区分需要复现时的 `adb logcat`（`libfushidicts` / SIGABRT / lowmemorykiller）。本轮修的是**能从代码上确证的**四条缺陷；若日志最终指向 LMK，第 1 条仍是必要修复（它决定了崩溃有没有日志），但内存占用本身要另开一条。
- 未在真机复现验证（手上没有那台设备的词典集）。已验证的部分：native ctest 28/28、`flutter analyze` 干净、相关定向测试与全量套件见提交说明。
