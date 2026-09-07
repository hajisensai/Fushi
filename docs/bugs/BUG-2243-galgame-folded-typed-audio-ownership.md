## BUG-2243 · 折叠正文事件继承旧语音与带事件资源退回时间匹配
- **报告**：2026-09-07（Windows Siglus 引擎级配音适配的消费链审查）
- **真实性**：✅ 真 bug。真实 service + controller 行为回归确认：事件 1 的 `ABC DEF` 与事件 2 的 `ABC\nDEF` 折成同一显示 row 时，`sourceSequence` 已前移而旧 typed resource 仍留在行上。另一个确定序列是事件 1 尚在 pending、事件 2 立即配到新资源时，旧 pending 在 poll 尾再次写回事件 1 的文件。WAV 索引还曾把明确属于事件 7 的文件按时间配给事件 9，先于事件 9 的 OGG。
- **[x] ① 根因修复** — 本文件同提交。`fushi/lib/src/sync/texthooker_service.dart:940` 按资源事件身份决定折叠继承；`fushi/lib/src/mining/gal_hook_session_controller.dart:3057` 保留 popup 首次明确绑定的 occurrence，折叠后仅用原事件 ID / tick 取原资源；新事件认领 row 时撤销旧 pending，刷新前核对 row 和 cache 的 ID / tick。`fushi/lib/src/mining/gal_voice_dump_index.dart:598` 与纯匹配 helper 先跨格式匹配事件，typed WAV 不进入时间桶。固定 native producer 标记的请求使用 event-only 资源合同，未标记其他引擎保留旧合同。
- **[x] ② 自动化测试** — `fushi/test/mining/gal_hook_session_controller_test.dart` 使用生产 service、controller、dump index 验证折叠新事件无声不借旧资源，排除未标记 WAV / 错事件 WAV，晚到自己的文件可配，旧 popup 始终取旧事件，旧 pending 不能覆盖新事件。`gal_voice_dump_index_test.dart` 验证跨格式事件优先及 typed WAV 负向；`gal_ingame_mining_binding_test.dart` 验证原 occurrence 不变；`gal_hook_mining_coordinator_test.dart` 验证真实折叠后的 occurrence 路由与 Completer 控制的切线程失效；`texthooker_progressive_fold_test.dart` 验证原声升级清除旧 loopback 时长、同文件已知时长保留。最终执行结果见下。

### 生命周期与范围

- Popup 不建立字符串别名、不查 latest。首次精确事件唯一绑定保留原 row occurrence；当前 session、HWND、selected thread 和 row 生命周期持续有效才可取音。未折叠的当前 occurrence 仍遵守现有 PCM / loopback 用户策略；折叠后的旧 occurrence 不借新 row 的 PCM 或资源。
- Coordinator 在队列作业开始和媒体等待完成后，使用真实选中行再次验证 occurrence；切线程使原绑定失效时停止写卡，不能把失效误当无声继续截图制卡。
- 用户实测“loopback 5 s 升级原声后仍显示 5 s”具有旧 duration 继承路径；转码入口消费完整原始文件，未发现按该 5 s 截断资源的路径。本轮更换资源时清旧时长，popup GIF 时长读实际 ADTS 字节，不借折叠后另一事件的行时长。
- 只修改 Windows galgame 必需的共享消费代码和平台无关测试；不改变 native profile / OVK 导出、不扩展其他平台、不提升引擎支持声明。
- 新增失败路径已由合成数据自动化复现，不声称真实游戏已触发 whitespace fold 串音；实际游戏 / Anki 回归由集成主线另行完成。本地日志不含游戏载荷。

### 验证

- 初始两条失败回归：旧事件资源跨折叠继承、错事件 WAV 抢占正确事件 OGG，修前退出 1。
- 独立审查追加的旧 pending 覆盖回归及捕获期间切线程回归，修前分别退出 1；后者实际成功写卡构成失败，不以临时目录错误充当复现。
- 最终 9 个定向 Flutter 文件共 **179/179**，退出 0：`gal_hook_session_controller_test.dart`、`gal_voice_dump_index_test.dart`、`gal_hook_mining_coordinator_test.dart`、`gal_ingame_mining_binding_test.dart`、`texthooker_progressive_fold_test.dart`、`gal_voice_pairing_window_parity_test.dart`、`galgame_paired_voice_test.dart`、`galgame_multi_voice_resources_test.dart`、`ingame_mining_failure_visibility_guard_test.dart`。本地 `.codex-test/fold-audio-final.log` / `fold-audio-final.exit.txt`；此前重复执行不累计。
- 14 个修改 Dart 文件 focused analyze 无问题，退出 0：`.codex-test/fold-audio-analyze-final.log` / `.exit.txt`。未运行全量 Flutter 或游戏。
- `bug.dart reindex` 2075 条；`bug.dart check` 退出 0，84 个既有跨分支号码冲突不含本条 2243。提交前 `git diff --cached --check`。
