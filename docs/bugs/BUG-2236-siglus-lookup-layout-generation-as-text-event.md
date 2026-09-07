## BUG-2236 · Siglus查词用几何代数冒充字幕事件ID导致制卡行与音频身份错误
- **报告**：2026-09-07，Siglus 引擎级查词/音频制卡扩覆盖验证。
- **真实性**：✅ 真 bug。LOOPERS PLUS 最终 DLL 实际命中载荷 `textGeneration=20`，同会话文本环总数与当前 `TextSlot.seq` 均为 `1`。基线 `781e80dd64` 的 `native/galgame_hook/hook/adapters/siglus_lookup.inc:1445` 把内部 geometry generation 写到 `publication.text_generation`，两种编号没有共同来源。`fushi/windows/runner/voice_hook_reader.cpp:753` 原样发往 Dart；`fushi/lib/src/lookup/gal_ingame_lookup_controller.dart:1283` 将其交给制卡 resolver；`gal_hook_text_overlay_controller.dart:1879` 对正值只按 `TexthookerLineEntry.sourceSequence` 匹配。`gal_hook_session_controller.dart:4731` 的 sourceSequence 实际来自 TextSlot.seq。结果可能无法解析原行；编号碰巧匹配历史行时还可能错绑 occurrence 与音频。
- **[x] ① 已修复** — 本文件同批源码提交：NativeExact 由 `WriteTextRingEntryLocked` 返回当次 `WriteTextLaneEvent` 的 committed seq，先写环、再于同锁内把原文与 event ID/thread ID 一起交给 lookup；LunaScenario 直接保留已稳定读出的 slot.seq/thread_id。lookup 的 active text、click target、pending payload 全程携带该身份，松开与最终提交都校验；IPC text_generation 写真实 event ID，geometry_generation 独立。没有修改 IPC 格式、runner 或 Dart resolver，也没有从全局最新计数或字符串补猜 ID。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/siglus_lookup_test.cpp` 新增实际 `WriteTextLaneEvent` 交错 native/Luna 写者测试：global counter 被另一写者推进、同文不同线程、真实 seq=1/geometry=20、同文新 occurrence、无效 ID 与失败写环均不能互换身份。保留现有重绘/layout/snapshot_epoch 测试。`adapter_structure_test.py` 新增真实生产接线守卫，42 项通过；MSVC x86 `/utf-8 /W4 /WX /O2` 行为测试通过，x86 Release 生产 Hook DLL 和定向测试目标构建通过。
- **备注**：只修复身份契约。OVK 提取/资源与语音归属、音频完整性、真实截图和卡片媒体写入不因此获得证明；不提升任何引擎支持状态。

### Proved

- `textGeneration` 与真实 TextSlot.seq 的不一致已有同会话实测元数据；本次修复使两条提字 ABI 都从实际文本生产事件取得身份。
- 同文字的新事件会撤销旧 press 的 snapshot；同事件的纯几何重绘保持事件 ID。layout reset 仍清空坐标并要求新 glyph，但保留它原已绑定的文本事件身份，避免在恢复时猜取全局最新文本。
- 写环失败产生的零身份不能认领 Ready、生成有效 click target 或提交命中；不会复用前一事件身份。

### Not proved

本独立 worktree 没有启动游戏或操作 UI。整合后的 x86/x64 完整构建，以及同一会话真实有声正文 → event ID → 音频资源 → 截图 → 卡片写入，仍由集成任务验证。源码测试不等于真卡音频正确。

### Next gate

整合后重新注入最终 DLL，先验证点击载荷的 textGeneration 与选中正文 TextSlot.seq 精确相等，且 geometry_generation 可以独立变化；通过后再沿该 occurrence 做资源配对与真卡媒体验证。
