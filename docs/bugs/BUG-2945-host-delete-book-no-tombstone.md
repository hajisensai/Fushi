## BUG-2945 · 互联「从所有设备删除」对书/有声书不生效：host 删除不写墓碑
- **报告**：2026-10-04（用户：shishamo，「fushi互联删除所有端的书没生效」）
- **真实性**：✅ 真 bug。client 端删除写本地墓碑后推 DELETE 到 host（`fushi/lib/src/sync/sync_orchestrator/tombstones.part.dart:223`），host 侧 `packages/fushi_engine/lib/sync/local_library_host_service/books.part.dart:350` `deleteBook` 只调 `deleteEpubBook(tombstone: true)`（那是防旧备份复活的备份墓碑），`audiobooks.part.dart:216` `deleteAudiobook` 什么墓碑都不写；其它已配对设备拉的是 host 的 `/api/tombstones`（`sync_deletion_tombstones` 表），host 没写就永远拉不到——结果只有发起端与 host 两份被删。
- **[x] ① 已修复** — 提交 `2c7efa44df5`。共享 mixin 新增 best-effort `_writeHostSyncTombstone`（`local_library_host_service.dart`），`deleteBook` 删成功后写 `book` 墓碑；`deleteAudiobook` 写 `audiobook` 墓碑，纯 SRT 书分支仅对 standalone 行（`bookKey` 为空）写 `srtbook` 墓碑。审查返工：原版对有声书关联的 SRT 书也写 `srtbook` 墓碑，违反 `SrtBookRepository.delete` 的「srtbook 墓碑只对 standalone 行写」不变式（关联行身份是 bookKey，已由 audiobook 墓碑覆盖），已去掉。墓碑写失败只记日志，不把已完成的删除变成 500。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_delete_push_test.dart`：client 删书 / 删有声书（含关联 SRT，断言不另写 srtbook 墓碑）/ 删纯 SRT 书三条，经真实 client 推送链到真实 host，断言 host 行已删且 host 自己写了对应 kind 的同步墓碑。
- **备注**：另有次要风险未在本次修：同步时内容同步先于墓碑处理（该开关默认关），开启时可能把刚删的条目再拉回来。未在真机双端复测。
