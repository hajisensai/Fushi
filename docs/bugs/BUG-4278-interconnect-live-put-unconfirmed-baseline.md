## BUG-4278 · 互联 live 进度 PUT 不回结果，client 无条件记基线
- **报告**：2026-11-10（用户：审计 sync-live 修复包 V-C2 / V-C3 / D10 / D11）
- **真实性**：✅ 真 bug。host 侧契约（本条前半，修复前）：
  - `packages/fushi_engine/lib/sync/fushi_sync_server/library.part.dart:285-299`（书进度 `PUT`）、`:615-630`（有声书位置 `PUT`）、`fushi_sync_server/video.part.dart:544-560`（视频位置 `PUT`）一律 `shelf.Response(200)` 空体；
  - `local_library_host_service/{books,audiobooks,videos}.part.dart` 的 `putBookProgress` / `putAudiobookPosition` / `putVideoPosition` 返回 `Future<void>`，被 LWW 拒收、书 / 有声书不在库都静默 no-op，也不接受「期望值」前置条件。
  - 后果：client 收到 200 就只能当作「写成功」记基线（被拒收的也记），且只能按判定时的旧快照盲写，覆盖判定之后第三台设备写下的进度。
  - client 侧（无条件记基线）见步骤 4，本文件同一条。
- **[ ] ① 部分修复（host 侧契约已修，client 侧待步骤 4）** — （host 侧提交见下方备注）：`fushi_library_host_service.dart` 新增 `LiveWriteResult`、`LivePositionWriteOutcome` / `LiveBookProgressWriteOutcome`（含 `tryParse`）、可选能力 `LivePositionWriteHost`、`kLiveWriteHeader`，以及 host 写入唯一判定口径 `resolveLivePositionWrite` / `resolveLiveBookProgressWrite`（带前置条件且命中时不按戳拒收、落库戳 = max(上报戳, 已存可信戳 + 1)、毒戳一定改写；无前置条件沿用 LWW 并区分 unchanged / stale）。`LocalLibraryHostService` 实现三个 `*Checked`，旧 `put*` 改为调它们并丢弃回执。三个位置 `PUT` 解析可选 `expectedPositionsMs` / `expected`（格式错 → 400），回 200 / 409 + 回执 JSON + `X-Fushi-Live-Write: 1`；三个位置 `GET` 与批量 `GET /api/library/book-progress` 加同一头。未实现能力的 host 行为不变。
- **[ ] ② 部分加自动化测试（host 侧）** — `fushi/test/sync/live_position_write_contract_test.dart`：真 `FushiSyncServer` + `LocalLibraryHostService` + 裸 `HttpClient`，视频 / 有声书 / 书各测响应头、applied / stale / 409 不写库 / 命中前置条件时旧戳也写入（戳 = 已存 + 1）、毒戳改写、书只差 charOffset 写入、书不在库 missing、非法前置条件 400，另加回执解析纯函数组。修复前 20 条 HTTP 用例全红（无头、空体、错配前置条件照 200 按 LWW 写）。
- **备注**：wire 兼容——新字段全可选；旧 client 不发 `expected*`，只多收到一个被 drain 掉的响应体与头，永远收不到 409。无头 `fushi_server` 用 `LocalLibraryHostService` 同步获得能力。
