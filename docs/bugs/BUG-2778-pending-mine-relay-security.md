## BUG-2778 · 待发制卡跨设备中转：远端载荷可读本地文件/发任意请求、id 路径穿越、同一张卡重复落地
- **报告**：2026-09-29（PR #1719「待发制卡队列 + 跨设备中转」合并后审查确认的四个阻塞问题）
- **真实性**：✅ 真 bug（沿真实代码路径静态定位；本骨架因环境无 dart 手写，号按全分支 + 各工作区扫描取下一个空号）。行号为修复前 origin/develop `7e32e586`：
  1. **SSRF / 读本地文件**：`packages/fushi_engine/lib/sync/forwarded_mine_materialize.dart:42-48` 只在载荷带单词音频字节时改写 `audio`，否则远端给的 rawPayloadJson 原样透传；下游 `packages/fushi_anki/lib/src/anki_local_media.dart:45`（本地路径直接当文件读进卡）/ `:50-53`（对任意 URL GET，不限大小）。任何能写同步后端 `__pending_mines__/` 的一方都能让落地设备读本机文件进 Anki 或打内网地址。
  2. **路径穿越**：`packages/fushi_engine/lib/anki_sync/pending_mine_relay.dart:324` `_recordId` 直接拿远端文件名当 id（`:141` → `_receive` → `insertRemote`），`packages/fushi_engine/lib/anki_sync/pending_mine_store.dart:58` `p.join(root, '$id.json')` 拼出本机路径。
  3. **跨设备重复出卡**：`pending_mine_store.dart:163` `sendable()` 含本机制、已上传到中转的行——制卡设备本机补发与落地设备各落一张。
  4. **多通道重复落地**：`fushi/lib/src/sync/sync_auto_trigger.dart` 每条同步通道各建一个 `PendingMineRelay`，`uploaded` 不分通道（制卡设备在每条通道各传一份），落地设备落完删行后没有任何记忆（`pending_mine_store.dart:91` 只按行判重），另一条通道的副本会被再收再落。
- **[x] ① 已修复** — 分支 `fix/pending-mine-relay-security`：
  - `withMaterializedMiningContext(..., bundledMediaOnly:)`：中转来的卡（`AnkiBoxLanding._land`、`PendingMiningAnkiRepository._sendOne` 对 `originDeviceId != null` 的行）`audio` 只能指向本次随附字节写出的临时文件，否则置空；`dictionaryMedia` 只留随附了字节的条目；fields 不是 JSON 对象直接拒绝。临时文件扩展名再过一遍 `sanitizeExt`。已配对主机的 `/api/mine/forward` 路径不变。
  - `PendingMineStore.isValidId`（`^[A-Za-z0-9_-]{1,128}$`）：`_recordId` 不合即丢弃并 `engineLog.logDiagnostic`；`insertRemote` / `_payloadFile` / 墓碑路径都校验，非法 id 抛 `ArgumentError`。
  - 幂等键 = 记录 id：`sendable()` 排除本机制且 `uploaded` 的行；`markSending` / `markUploaded` 改为事务内条件转移、返回 bool，二者互斥（本机补发与上传只能成一个）；本机成了落地设备时中转先撤回远端记录再 `clearUploaded`，交回本机补发。
  - 本地墓碑 `<support>/pending_mine_queue/landed/<id>`：来自其他设备的卡在 `markDelivered` 时先落墓碑；`insertRemote` 拒收已落地 id；任一通道再见到同 id 只写回执、撤记录；墓碑 180 天后由 `sweepOrphanPayloads` 清理。正在 `sending` 的收来行不再因「这条通道上没有记录」被删（否则墓碑留不下）。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/forwarded_mine_materialize_test.dart`（非随附本地路径 / URL 被剥、随附字节改写成临时文件、外字只留随附条目、非对象 fields 拒绝、非中转路径照旧）；`fushi/test/anki/pending_mine_relay_test.dart`（恶意 id `../x` 等被拒且不写出目录、已上传记录本机不补发、sending 的不上传、改当落地设备撤回后本机补发、两通道同一记录只落一次）；`fushi/test/anki/anki_box_landing_test.dart`（主机落地剥 `/etc/passwd`、非法文件名跳过）；`fushi/test/anki/pending_mining_anki_repository_test.dart`（已上传行不补发）。
- **备注**：环境无 dart/flutter 工具链，以上测试未在本地执行，待 CI 验证。遗留：① 中转卡的 `http(s)` 单词音频（打包时不搬字节）落地后会丢——要保留得在入队时就把 URL 音频下载成随附字节；② 一条通道上没有记录会让落地设备删掉还没交的收来行（多通道且制卡设备只与部分通道相通时，行会在通道间反复收/删），本次只保证不重复落地；③ 已配对主机的 `/api/mine/forward` 仍信任对端给的 `audio` 本地路径 / URL（对端已配对鉴权，未在本次范围）。
