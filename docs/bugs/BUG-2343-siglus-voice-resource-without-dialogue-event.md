## BUG-2343 · Siglus 语音资源缺少正文事件身份，配对依赖时间窗
- **报告**：2026-09-07（用户明确音频必须与内嵌查词一同实现引擎级适配）
- **真实性**：✅ 真 bug / 当前能力缺口。`native/galgame_hook/hook/adapters/siglus_adapter.inc:22` 的任务仅包含读取 tick、归档路径与 offset；`:243` 以 ReadFile 时刻排队；`:394` 调用 `WriteVoiceOggAt` 没有传正文事件 ID。`hook/dll_main.cpp:244` 将缺省 ID 0 写成无事件标记资源名；宿主 `fushi/lib/src/mining/galgame_audio_source.dart:625` 的“新版 Siglus 沿用正文 tick”注释与生产代码不一致。当前只能按时间候选匹配，不能保证原句对应语音。
- **[ ] ① 部分修复，跨 family 验证未完成** — `5c931c2558` 已接入消息调用票据、实际 TextSlot seq 与 OggOpen 来源，原版 LUNARiA 的 seq1/11 已实测正文身份与源资源一致，seq11 完成真实制卡。现有严格消息 family 之外的 NativeEcx 等版本仍未接通同等音频身份，不将单样本闭环写成整个引擎问题关闭。不得把最新 TextSlot、字符串相等、同毫秒或加大时间窗冒充稳定身份。
- **[x] ② 已加自动化测试** — `641f55d0a1` / `afa45073e2` 覆盖真实裸入口、一次性票据、生产 TextSlot 提交时间与独立语音来源门；`e2b144fc3f` 的 `siglus_voice_export_test.cpp` 执行真实 writer/export/binding worker，覆盖语音来源拒绝、资源先后到达、实际 seq/tick 文件名、无声文本拒绝借用、写入/关闭失败、真实读锁/截断及文件身份相同但索引摘要变化。`4c4d80b4b3` 覆盖 A/B 同名文件切换 CWD，拒绝依赖工作目录的请求路径。合成 Ogg 页仅测试结构与字节，不是可解码语音；真实重播、跳读/读档、BGM/SE 与制卡仍须原路径验证。
- **运行证据**：原版 LUNARiA 1.1.137.0、game PID 59820、helper 25996、宿主 24584、IPC v24、DLL `6f18f98cb239c7825cf3ec3c68a0b1af75d86c38ffd18cf28c672347d8a4a86c`。九个导出 Ogg 与对应源 entry 完整 SHA-256 相等；资源元数据摘要 `72820973b8d210da363874ba2271f55e9c38b05992040f17078345038fa99627`，只证明原始资源 captured/hash_verified。
- **重放对照**：原生 VOICE 按钮重放一次，正文仍 global seq 369、lane seq 2、tick 943998187；旧导出文件尾缀 166452 在读取 tick 944257093 再次出现，与源 entry 及此前导出哈希相同。后续查明 166452 是采样数，真实 member ID 为 125，source offset 为 769065、长度 70860；旧文件命名不能当作引擎成员身份。原先资源 tick 943997750 比正文早 437 ms，不能修改时间窗将此样本凑成通过。差分元数据摘要 `7b4e38b8db621f76d6304b74f75a40e328e63bd7b6cf70a475c0be2d211fd3cd`。
- **进一步定位**：原版同会话只读结构分析和有界调试标量表明，播放请求 `10100125` 按 100000 拆成归档 101 / member 125，索引第三 DWORD 用于成员查找。切到无语音旁白后，音频管理器仍保留旧 key，而消息对象的语音字段清为 `ffffffff`；因此不能读取全局旧 key 配给新文本。消息 voice/text 入口实测共享 owner，正文时 owner 的语音 key 与该句语音命令一致，但两入口的位置对分别是 `(1,b)` / `(1,c)`，不能将其直接当成共同事件 ID。原生重播未再次触发这两个入口。尚须证明消息生命周期、读档/重复句和 Luna 异步发布的稳定事件关联；这些单样本诊断地址没有成为生产 Hook 常量。
- **备注**：资源重读不证明角色归属或真正播放；VoiceClip/引擎 PCM 均为 0，Loopback 计数独立。未确认音频分类或执行真卡；不得升级引擎支持状态。该会话后续另遇宿主 Flutter 可访问性回调崩溃，有效 hit 无消费者不应误归为原生查词未命中。

### 2026-09-07 实现进展（尚未完成真机音频门）

`641f55d0a1` 引入完整结构准入后的消息入口与 scenario 入口 observer：冻结同次消息 owner 的 voice key，以调用帧关系和一次性票据验证，再由 worker 提交实际 TextSlot seq；callback 不执行 IPC 或文件 IO。`afa45073e2` 修正另一处集成缺口：callback 时刻不能替代 worker 的实际提交时刻，否则即使 seq 相同，宿主 1500 ms 校验仍会拒绝延迟提交的语音。测试直接写生产 TextLaneEvent，以 callback=1、提交=5000 的合成时钟验证，不扩大时间窗；恢复旧参数时测试失败。

绑定缓存、OVK 唯一成员索引和归档文件身份/索引摘要校验已实现。独立审查进一步要求实际引擎资源来源：同名 `zNNNN.ovk` 不能独立授予归档身份。正在接入结构证明的 OggOpen 调用来源，冻结请求 key、路径、offset 与 length；来源未完成时禁止该消息 family 输出无 seq 资源回退给时间匹配器。静态资源格式证明不能直接打开配对门。上述实现不构成角色语音、重播/读档生命周期或真卡 E2E 已验证。

### 新构建的原路径结果

上节记录的是接线完成前的阶段。`5c931c2558` 的最终 DLL `cb34c479177d06344c5fb8163d21bbcae5b6de88039804395c1ec5ece6afaec9` 已在原版 LUNARiA 71920、helper32264、宿主72108 实际运行。真实 `seq1/tick951860281` 与 `seq11/tick952081921` 均生成精确事件标记资源，分别与源 OVK member125/131 完整字节哈希一致。seq11 的原生资源显示于工作台，正文查词、保持/关闭/推进和真实 Anki 制卡均已观察；回读 note `1788780108844` 确认正文与实际 TextSlot 一致、卡内 AAC 与源 OGG 按生产参数转码完全同哈希，实际图片对应制卡时的游戏画面且没有词典覆盖。

同轮发现首次选择线程回捞的 seq1 未自动挂音频，这是消费端 [BUG-2240](BUG-2240-selected-thread-history-resource-pairing.md)，不再归因为 native 没有事件身份。该修复集成为 `98884fa55e`，尚待新宿主原路径回归。构建、运行身份和各项限制详见 [原路径报告](../reviews/2026-09-07-siglus-expanded-trials.md)。本条仍保留跨编译 family、重复句/读档/重播和声音分类未验证的范围，支持矩阵未升级。
