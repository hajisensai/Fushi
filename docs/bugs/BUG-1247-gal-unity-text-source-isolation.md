## BUG-1247 · Unity TextMesh 停顿拆句且绕过文本线程选择
- **报告**：2026-07-29（用户：同一句括号内文本被拆成上下两条；质疑 Luna 与
  Unity TextMesh 为何不能分别作为候选线程）
- **真实性**：✅ 真 bug。`native/galgame_hook/hook/adapters/unity_adapter.inc`
  的 legacy TextMesh 聚合器把 250ms 停顿、CR、LF 和 U+3000 都当作句界，并直接写
  `text_write_count`，完全没有检查 v12 的 `selected_text_thread_id`。因此一次打字停顿
  会把一句拆半；即便用户未选或选了 Luna，native TextMesh 仍会污染正式文本环。
- **[x] ① 已修复** — Luna 与 native adapter 使用互斥预览槽分区和互斥 thread-id
  namespace；native 文本先进入候选预览，只有精确命中显式选择才发布正式行。TextMesh
  去掉时钟断句，保留 CR/LF/TAB；U+3000 仅在真实样本证明其为批次结束符的
  `Sasasa.exe` profile 中终止，其他 Unity 标题按正文保留。空字符串和正常 helper
  收尾仍提交尚未结束的末句。
- **[x] ② 已加自动化测试** —
  `native/galgame_hook/tests/unity_text_mesh_reassembler_test.cpp` 覆盖换行、全角空格、
  profile 负向和 thread-id namespace；
  `native/galgame_hook/tests/thread_preview_ipc_test.cpp` 守卫跨进程槽分区与原子变更计数；
  `native/galgame_hook/tests/adapter_structure_test.py` 守卫无时间断句、选择门和正常收尾；
  `hibiki/test/tools/voice_hook_ipc_contract_test.dart` 守卫 host/native 契约；
  `hibiki/test/mining/gal_capture_audio_integrity_test.dart` 守卫未选择时工作台、浮窗、
  配对和制卡均不得消费历史正式环。
- **备注**：本修复不把 Luna 与 TextMesh 合并或互相屏蔽；两者始终作为独立候选供用户
  选择。按用户要求不等待 x86/x64 全编译验收，合入前仍执行生成器、结构和可用的定向测试，
  未运行项在 PR 中明确记录。
