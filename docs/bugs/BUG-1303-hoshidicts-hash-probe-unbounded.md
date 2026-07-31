## BUG-1303 · 词典 hash 探测无界循环 + load() 零边界校验：损坏词典可致查词永久挂死/越界读

- **报告**：2026-07-31（用户：「词典出来的速度特别特别慢，**还有可能卡死**」——查「卡死」的成因时在引擎里挖到）
- **真实性**：✅ 真 bug，且**已用变异实测证明会真崩**（见 ② 的 SegFault 证据）。根因在 `native/hoshidicts/hoshidicts_src/hash/hash.cpp`：

  - **① `load()` 完全不校验边界**（旧 `hash.cpp:77-80`）：
    ```cpp
    void linear::load(uint8_t* ptr) {
      ptr_->capacity = *reinterpret_cast<uint32_t*>(ptr);   // 直接信文件里的裸 uint32
      ptr_->table = reinterpret_cast<slot*>(ptr + sizeof(uint32_t));
    }
    ```
    没有任何检查确认 mmap 的 `hash.table` 真容得下 `capacity` 个 slot。词典目录被截断写入 / 导入中断 / 同步半截 / 磁盘错误时，`capacity` 会远大于文件实际槽数。
  - **② `operator()` 的探测是无界 `while (true)`**（旧 `hash.cpp:24-32`）：
    ```cpp
    uint64_t pos = h % ptr_->capacity;
    while (true) {
      if (ptr_->table[pos].hash == 0) return 0;
      if (ptr_->table[pos].hash == h) return ptr_->table[pos].offset;
      pos = (pos + 1) % ptr_->capacity;   // 无迭代上限
    }
    ```
    表中没有空槽（capacity 被读成畸形值、或表满 + bloom 假阳性）时**永不终止**。而 Dart 侧 `HoshiDicts.instance.lookup()` 是**同步 FFI 调用、直接跑在 UI isolate 上**（`hibiki/lib/src/models/app_model.dart:3899`，对比同文件 `importDictionary` 明确用了 `Isolate.run`）——所以这不是「查得慢」，是**整个 app 永久冻结**，与用户报的「卡死」完全吻合。
  - **③ `capacity == 0` 会整数除零**：`h % ptr_->capacity` 直接 UB / 崩溃。
  - **对照证据（这是最能说明问题的一点）**：同一份 `hash.table`、同样的格式，`query.cpp:630-635` 的 `probe_dict_content()` **早就做了**正确的钳制：
    ```cpp
    const size_t max_slots = (hash_table.size - sizeof(uint32_t)) / slot_size;
    if (capacity > max_slots) capacity = static_cast<uint32_t>(max_slots);
    ```
    两条读同一文件的路径，**只有查询这条**（每次用户查词都跑）没有边界检查——典型的「同概念两份实现漂开」。
- **[x] ① 已修复** — 提交：见本轮 PR
  - `load(uint8_t* ptr, size_t size)` 加上 mapping 大小参数（调用点 `query.cpp:129` 传 `dict.data->hash_table.size`），把 `capacity` 钳制到文件实际能容纳的槽数，复用 `probe_dict_content` 同款算式；`ptr` 为空或文件短于 header 时置 `capacity=0 / table=nullptr` 安全退出；`capacity==0` 时不再产生悬空 `table` 指针。
  - `operator()` 改为 `for (uint32_t probes = 0; probes < ptr_->capacity; probes++)`——线性探测合法情况下**永远不需要超过 capacity 步**，所以这个上限不改变任何正常查询的结果，只终结病态循环。开头补 `!ptr_->table || capacity == 0 || !bloom_` 早退（同时堵掉除零和 `bloom_` 未设置时的空指针解引用）。
- **[x] ② 已加自动化测试** — 提交：见本轮 PR。测试文件 `native/hoshidicts/tests/hash_truncated_table_guard_test.cpp`，注册进 ctest（`native/hoshidicts/tests/CMakeLists.txt`，带 `TIMEOUT 60`——挂死必须表现为失败而不是永远跑下去）。
  四个场景走**公开查询路径**：hash.table 截断到只剩 header+1 槽（header 仍宣称原始大 capacity）／capacity 字段改写为 0（旧代码除零）／capacity 改写为 `0xFFFFFFFF`（旧代码无界探测 + 越界读）／未损坏副本仍能查出 猫（证明钳制没有把正常查询一起干掉）。
  - **变异实测（关键证据）**：把 `load()` 的钳制改成 `if (false && stored > max_slots)` 重新编译后，该测试**以 SegFault 失败（25.16 秒后崩溃）**——硬证明了三件事：旧代码确实会越界读、这个测试真能抓到、修复确实解决了它。变异用反向 `sed` 替换还原（不用 `git checkout --`，那会连带打回未提交的其它修改），还原后核验零 `MUTANT` 残留、全套 19/19 恢复绿。
- **备注**：
  - 与 [BUG-1302](BUG-1302-lookup-blocking-network-timeouts.md)（网络超时阻塞）、[BUG-1304](BUG-1304-engine-freq-pitch-enrich-before-truncate.md)（引擎线性放大）同轮，是同一句用户报告拆出的三条独立根因：BUG-1302 解释「慢 4-5 秒」，BUG-1304 解释「词典装得多的人更慢」，本条解释「卡死」。
  - 本条修的是**触发后果**（不崩、不挂）。「同步 FFI 直接跑在 UI isolate」这个使其后果如此严重的架构成因未动，记在 BUG-1302 的未修项里。
  - 验证环境：MSVC 2022 + Ninja + C++23，`cmake -S native/hoshidicts/tests -B <build> -G Ninja -DCMAKE_BUILD_TYPE=Release` → `ctest`。注意 `tests/run_all.bat` 把构建树固定放在 `%TEMP%\hoshi_tests_build`，多个 worktree 并发时会撞 CMake cache（报 source 不匹配），换独立短路径构建目录即可。
