## BUG-1346 · galgame 文本捕获：256 槽全局 FIFO 挤压导致放开非胜出线程必然复现 BUG-1159（IPC v13 按线程分道根治）
- **报告**：2026-08-01（用户：「按『先解决 256 槽缓冲区挤压，再放开非胜出线程』的顺序做」「根本性修复」）
- **真实性**：✅ 真 bug（结构性缺陷，非偶发）

### 根因

文本区是**一块 256 槽的全局 FIFO**（旧 `kTextSlotCount = 256`，`seq % 256` 寻址，
`native/galgame_hook/include/voice_hook_ipc.h`）。galgame 里普遍存在逐字重绘型 hook（一句话产生
几十上百个事件），一旦让所有 hook 线程都发布，它几秒内刷穿全环，把配对候选行挤出去 →
语音资源找不到对应文本（`kExpired`）→ 写成无标记文件 → 消费端 200ms 时间窗兜不住 →
整段降级 `system_loopback`。这就是 BUG-1159 的失败链，用户感知是「台词抓不到、退回整机混音」。

**v12 没有解决它**（这点此前被记错过）：v12 把「线程选择器」这个消费者搬进了按线程分槽的预览区，
让「看得见所有线程」不再依赖「文本环装所有线程」；但文本环本身仍是全局 FIFO，它当时不被挤爆，
只是因为**同一时刻只有一条线程在写**（未选定就一行都不发），不是结构上挤不动。

旧方案的第二个死结：Dart 侧回写 `selected_text_thread_id` 会重新激活 native 的采集期过滤，
等于没改。

### 修复与测试

- **[x] ① 已修复** — IPC v13：文本区改成**按线程分道**（`TextLane[64]` 道表 + 每道 8 槽），
  道下标与线程预览槽下标取同一个值、沿用预览区那套跨进程互斥分区（Luna 用低段、游戏内 native
  adapter 用高段），认领逻辑只有一份。道内覆盖只吃掉自己的旧行，**挤压在结构上不再可能**。
  - 采集期取消选定线程过滤（injector `LunaShouldWriteLine` / `unity_adapter` 的
    `IsExactTextThreadSelected` 门），只保留伪影过滤；
  - `selected_text_thread_id` 降级为**消费期指定**：Dart 的文本消费点
    (`GalHookSessionController._acceptsLineFromSelectedThread`) 与游戏内 kirikiri 配对候选扫描
    各自按它过滤 —— 死结②③随之解开；
  - 等价性关键：新增 `TextSlot::face_id`（native 算好的 hook 面 id），消费期照 native 旧判据
    按 hook 面放行，否则同一 hook 面换调用点就整段丢词（BUG-1159 原样复发）；
  - 换线程后立即回捞该道历史（`_recoverSelectedThreadHistory`），漏掉的台词不必重打剧情；
  - 读侧归并只有 `CollectTextSlotsBySeq` 一份实现（host `PollText` 与 `ring_probe` 三个 dump 共用）。
  - **复核后追加两处必修**（用户复核 c97f668d3 查出）：① `lane_seq` 是最后写的完成标记却非
    volatile、写侧无屏障——改为 `volatile` + `AtomicStorePreview64` 发布（全栅栏且 64 位不可
    撕裂，x86 上普通写会被拆成两次 32 位写），读侧同步改原子读；② 道用尽原本**静默丢弃且无
    计数**，而 v13 放开非胜出线程正是抬高道满概率的改动、症状又与它要根治的 256 槽挤压完全
    同形，真机无法区分——改为两级降级 + 两个计数：先回收最久未写的**非选定**道
    （`text_lane_recycle_count`，选定线程那条道是配对路径输入，任何情况下不得被顶掉），
    无可回收才丢弃（`text_lane_overflow_count`）；两个计数经 `VoiceHookStatus` → channel →
    `EngineHookGalAudioSource` 一路到会话事件（`text.lane_recycled` / `text.lane_overflow`）。
  设计与取舍见 `docs/specs/galgame-mining/text-lane-v13.md`。
- **[x] ② 已加自动化测试** —
  - native `tests/text_lane_ipc_test.cpp`（新增 ctest 目标）：逐字重绘线程写 5000 行后
    **另一条线程的行一条不少**（挤压的结构判据）；道内只留最近 K 行；Luna/native 两段不共用道；
    全局发布序跨道连续。变异实测：把寻址退回全局 FIFO，前两条立刻判红。
  - Dart `test/mining/gal_text_lane_consumer_filter_test.dart`：未选定不放行、只放行选定线程、
    同 hook 面兄弟线程放行、face 为 0 时退回精确匹配、换线程回捞历史。变异实测三条
    （去掉 face 分支 / 不过滤全放行 / 关掉回捞）逐条判红。
  - 既有守卫改到 v13 语义：`test/tools/voice_hook_ipc_contract_test.dart`、
    `test/mining/gal_voice_pairing_window_parity_test.dart`、`native/tests/adapter_structure_test.py`。

- **备注**：真机 galgame E2E（原始启动路径「显示台词 → 对应语音 → 截图 → 真卡写入」）**未做**，
  本机无该现场；按 SOP 该能力停在 `implemented_unverified`，不得宣称已验证。
  离线门已过：x86 全量构建 + 25/25 ctest、x64 C++ 目标构建 + 分道测试、native python 结构/清单
  检查、`flutter analyze` 全绿、`flutter_test_failures.dart` 判决行 PASSED。
