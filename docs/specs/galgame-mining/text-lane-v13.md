# IPC v13：文本区按线程分道（解 256 槽挤压，放开非胜出线程的前置）

状态：**已实现**（native + host 同一 PR 落地）。前置 BUG-1345（契约单一真相源）已落地。
实现相对本设计的三处增补，都是实现过程中发现的必需项，已写回下文：`TextSlot::face_id`
（消费期按 hook 面放行的前提）、`CollectTextSlotsBySeq`（读侧归并唯一实现）、换线程后的
历史回捞（分道保留下来的行要真的能回到工作台，否则「多抓」只存在于共享内存里）。
关联：看板 TODO-2184、BUG-1159、BUG-1193、`native/galgame_hook/include/voice_hook_ipc.h`。

## 1. 问题

用户诉求是「别再丢弃非胜出的文本线程，免得漏台词」。按现结构直接放开会复现一条已修好的
失败链：

文本环是**一块 256 槽的全局 FIFO**（`kTextSlotCount = 256`，`seq % 256` 寻址）。放开后每条
hook 线程都往这块 FIFO 里写，而 galgame 里普遍存在**逐字重绘型 hook**（一句话产生几十上百个
事件）。这类线程会在几秒内把 256 槽刷穿，把配对候选行挤出环 → 语音资源找不到对应文本
（`kExpired`）→ 写成无标记文件 → 消费端 200ms 时间窗兜不住 → 整段降级 `system_loopback`。
这正是 BUG-1159 的失败链，用户感知是「台词抓不到、退回整机混音」。

**v12 没有解决它。** v12 做的是把「线程选择器」这个消费者搬进按线程分槽的预览区（每线程只留
最近一行），让「看得见所有线程」不再依赖「文本环装所有线程」。文本环本身仍是全局 FIFO，仍只
装当前选定线程——它不挤压是因为**当下只有一个线程在写**，不是结构上挤不动。

## 2. 设计

把文本区改成**按线程分道**，让「挤压」从「要小心防」变成结构上不可能——与预览区同一套思路，
只是从「每线程 1 行」扩成「每线程一条小环」。

### 2.1 布局

```
[SharedHeader][音频环][文本区][clip 索引][loopback 环][loopback 标记表][线程预览区]
                        ^
                        └── v13：[TextLane[kTextLaneCount]][slots kTextLaneCount * kTextLaneSlotCount * kTextSlotBytes]
```

```cpp
struct TextLane {
  volatile uint64_t thread_id;    // 0 = 空道
  volatile uint64_t write_count;  // 道内单调序号
};
constexpr uint32_t kTextLaneCount = kThreadPreviewCount;  // 64
constexpr uint32_t kTextLaneSlotCount = 8;                // 每道 8 行历史
```

容量 64 × 8 × 2048B = 1MB（今天 512KB）。32 位游戏地址空间预算里，音频环上界 64MB、loopback
16MB，这 0.5MB 增量是噪声。

### 2.2 分道认领

**复用预览区的互斥分区**：Luna（跑在 injector 进程）用 `[0, kLunaThreadPreviewCount)`，游戏内
native adapter 用 `[kNativeThreadPreviewStart, kThreadPreviewCount)`。跨进程 writer 因此永远不会
认领同一条道——进程内 `CRITICAL_SECTION` 串不住另一个进程，这是 v12 已经踩过并解决的坑，不再
重新发明。同一 `thread_id` 的预览槽下标与文本道下标**取同一个值**，认领逻辑只有一份。

### 2.3 序号与完成标记

- `TextSlot::seq` 语义不变：**全局发布序**，仍由 `InterlockedIncrement64(&header->text_write_count)`
  占号。Dart 的 `pollText(fromSeq)` 契约因此逐字节不变。
- `TextSlot` 新增 `uint64_t lane_seq`：道内序号，作**道内完成标记**（reader 校验
  `slot.lane_seq == 期望道内序号` 才取该槽），取代旧的 `slot.seq == 全局 seq` 校验。
- `TextSlot` 新增 `uint64_t face_id`：native 算好的 hook 面 id。消费期要按 hook 面放行
  （同一 hook 面换调用点 ctx 会变、thread_id 随之变，精确匹配会丢整段台词 —— BUG-1159），
  判据必须用 native 这份，不能在 Dart 里照抄一遍 FNV 哈希（那又是一个漂移源）。

### 2.4 写侧

非伪影行**一律写进自己那条道**，采集期不再有任何「选定线程」过滤。伪影仍在写入前剔除
（预览区另有 artifact 标记位，脏线程在选择器里照样看得见）。

### 2.5 读侧

`VoiceHookReader::PollText(from_seq)` 遍历所有非空道，取 `slot.seq > from_seq` 且道内校验通过的
行，按 `seq` 升序合并返回。Dart 侧收到的仍是一串按全局序排好的行，字段不变。

归并实现只有 `CollectTextSlotsBySeq`（契约头里）一份：读侧不止一个（host 的 `PollText`、诊断探针
`ring_probe` 的三个 dump），各写一遍必然漂开。

### 2.6 选定线程降级为「消费期指定」

这是死结③（Dart 回写 `selected_text_thread_id` 会重新激活 native 侧过滤 = 等于没改）的解法：
`selected_text_thread_id` 不再是**采集期过滤器**，而只是**消费期指定**——

- Dart 侧（`gal_hook_session_controller` 的 `pollText` 消费点）只把选定线程的行喂给
  texthooker / 配对 / 制卡；其余线程的行留在共享内存里不喂 UI。
- 游戏内 `kirikiri_adapter.inc` 的配对候选扫描同样按选定线程过滤（它今天默认「环里只有选定
  线程」，放开后必须显式过滤，否则会把别的线程的文本配到语音上）。

于是「用户选哪条线程」只改变**从哪条道取**，不再让 native 丢弃任何行。

### 2.7 用户可见收益

- 中途换线程后，新线程**此前的历史行仍在它自己的道里**：`selectTextThread` 成功后立即回捞
  （`_recoverSelectedThreadHistory`），漏掉的台词直接补进工作台，不必重打一遍剧情。回捞只补
  文本，不重放音频抓取——那些时刻早已过去，硬跑一遍只会给每句盖上「疑似漏抓」红标；要补音频
  走既有的逐句重录入口。
- 选错线程不再等于该段语音永久孤儿。
- 角色名 / 正文分属两条线程时，两条都留着，后续 UI 可以并列消费（本设计只保证采集，不预设 UI）。

## 3. 风险与验证门

最大回归面是 **2.6 的等价性**：消费期过滤必须与旧的采集期过滤行为等价，否则就是 BUG-1159 换个
地方复发。离线阶段必须有的负向测试：

- 逐字重绘线程写满自己那条道后，**另一条道的行一条都不少**（挤压的结构性判据）；
- 未选定线程的行不得进入 texthooker / 配对；
- 切换选定线程后能取回该线程此前的道内历史；
- 同一 `thread_id` 在 Luna 与 native adapter 两侧不得认领到同一条道；
- `session_end` 后道内状态清理，后续会话不串数据。

外加：x86/x64 双架构构建 + CTest、replay fixture、Dart 定向测试与全量、真机 E2E（原始启动路径
「显示台词 → 对应语音 → 截图 → 真卡写入」）。真机 E2E 通过前，能力只能记 `implemented_unverified`。

## 4. 更便宜的备选（若要更快见效）

只把**预览区**从「每线程 1 行」扩成「每线程 K 行小环」，文本环（配对路径）一个字节不动。
代价是非选定线程的历史受预览槽限制（每行 ≤ 192 wchar、深度小），且不支持对非选定线程回配语音；
好处是配对路径零风险、改动面约为本设计的三分之一。若用户要的只是「漏了一句能回头看见」，
这个版本就够；要的是「换线程后能把那段语音也补上卡」，就得走上面的完整分道。
