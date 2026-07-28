## BUG-1226 · 制卡前查重导致 Anki 未响应
- **报告**：2026-07-29（用户：制卡时 Anki 未响应，Hibiki 连续记录
  `findNotesByField → isDuplicate → _mineEntryInner` 的 10 秒超时。）
- **真实性**：✅ 真 bug。修复前
  `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart:476-504`
  在每次禁止重复的制卡前同步调用 `findNotes`；AnkiConnect 又在 Anki GUI
  主线程中同步执行该 action。Hibiki 的 `Future.timeout` 只能停止客户端等待，
  不能取消 Anki 内已开始的搜索，因此超时与 Anki 界面未响应会同时出现。
- **[x] ① 已修复** — `d2626979c`：
  `ankiconnect_service.dart:289-316,634-661` 把当前卡组、根卡组、全收藏三种
  范围传给 `addNote` 的原生 `duplicateScopeOptions`，由 AnkiConnect 用主字段
  checksum 索引原子查重；`ankiconnect_repository.dart:500-526` 删除制卡前和
  响应丢失后的 `findNotes`，并把原生重复响应映射回 `MineOutcome.duplicate`。
- **[x] ② 已加自动化测试** — `d2626979c`：
  `ankiconnect_commit_unknown_test.dart:117-169` 守卫制卡不再预查或事后补查；
  `duplicate_scope_test.dart:100-159` 钉死三种原生查重范围；
  `ankiconnect_service_test.dart` 钉死请求 payload 与重复异常映射。
- **备注**：相关 52 项 Flutter 测试全绿；`flutter analyze`
  （`packages/hibiki_anki`）0 issue。按用户要求未等待整仓/Windows 编译验收。
