## BUG-4510 · 词典物化探测自我喂养：预算后回报触发重装，重装又对全部目录起新 worker，启动卡在 rebuild-dict-paths、窗口无响应
- **报告**：2026-11-12（应用内反馈 V9Jd1f2pLi，Windows 3.3.0，「启动时无响应 x2」；用户有 121 本词典，日志反复报 30～97 本「超时未物化」）
- **真实性**：✅ 真 bug。日志：22:36:25 进入 `rebuild-dict-paths`，22:36:33 物化预算（8s）耗尽、跳过 88 本，22:36:37 撞上 12s 启动看门狗（`TimeoutException ... 卡在「rebuild-dict-paths」`），之后进错误屏。从 22:36:45 起每 2～3 秒冒一条 `AppModel.dictResourceMaterialize`，跳过数在 55～80 本之间来回跳、一直不收敛，直到 22:37:28 Windows 报 Application Hang 1002、进程被结束；下次启动的 `AppInit.hangRecovered` 停在 rebuild-dict-paths。根因在 `fushi/lib/src/models/app_model.dart`（修复前行号）：
  1. `_onDictDirMaterializedLate`（:3562）每收到一条预算后的成功回报就 2s 后排一次 `_rebuildDictPathsCacheAsync`。这次重装（:3737）**对全部目录**重新 `materializeDictResources`，包括上一个 worker 还没读到的那些，于是又起一个新 worker、预算内又读不完、又有新的预算后回报、又排重装……worker 无界叠加，各自从头读同一批（云占位）文件、互相抢 IO，永远收不敛。
  2. 重装用本轮结果**覆盖**可读集（:3745 `_materializedDictDirs = readyDirs`），已经证明可读的词典又掉出去，可读集来回抖动（日志里跳过数忽高忽低）。
  3. 每轮重装都在主 isolate 上把引擎整套重装一遍（`loadPendingAsync`，逐本同步 FFI）。每 2～3 秒一轮持续下去，Windows 上 UI 线程的消息泵被饿死，报「无响应」。
  4. 启动看门狗 `_guardInitIo('rebuild-dict-paths', _rebuildDictPathsCacheAsync())`（:4736）把装载也包了进去。8s 物化预算之后只剩 4s 给逐本装载，词典一多、盘一慢，就会被误判成启动失败。
  5. 次要问题（分诊指出）：`_migrateDictionaryTypes`（:3332）跑在物化探测**之前**，对没探过的词典同步 `openSync/readSync blobs.bin` 或 `probeDictContent`，读到云占位文件会在内核里阻塞。
- **[x] ① 已修复** —
  - `fushi/lib/src/dictionary/dict_resource_materializer.dart` 新增 `DictResourceAvailability`，作为进程内物化状态的唯一持有者：已证明物化的目录单调累积、不被后续轮次覆盖；同一目录同一时刻最多一个在途探测，`resolve` 只探既没证明可读、也不在途的目录；在途集合全部回报完、且其间有新目录变可读时，`onLateReady` 只触发一次。
  - `app_model.dart`：删掉 `_probedDictDirs` / `_materializedDictDirs` / `_onDictDirMaterializedLate` 和 2s 重装，改由 `_dictResources` 驱动，在途探测清空后只重装一次（`_reloadDictsAfterLateMaterialize`）。`_rebuildDictPathsCacheAsync` 拆成 `_scheduleDictPathsAsync`（exists + 物化探测 + 类型自愈 + 排期）和装载两段；启动时 12s 看门狗只包前一段，逐本让出的 `loadPendingAsync` 不再包进去（另记 init step `load-dicts`）。`_migrateDictionaryTypes` 移到物化探测之后，只探 `_dictResources.isReady` 的目录，没证明物化的本次不探、不落标记；用进程内 `_dictTypeProbeAttempted` 防止两条重建路径重复探。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/dict_resource_materializer_test.dart`，`DictResourceAvailability（BUG-4510）` 组 6 条：
  - 用假探测器（预算后回报由测试控制）验证：在途目录不重复探；可读集单调累积；全部到齐才触发一次重装；全部失败不重装；失败的目录下轮会重探、没探过的目录放行。
  - 用真 `materializeDictResources` 验证：预算后到齐只重装一次，重装那轮不再起 worker。
  - 两条生产接线守卫改到新结构：探测先于类型自愈和排期；看门狗只包 `_scheduleDictPathsAsync`；类型自愈受 `isReady` 门控；同步路径用 `isLoadable`。
- **备注**：用户的词典目录确实大量处于 OneDrive 云占位状态，拉回本地本身要时间。修复后第一次冷启动仍只装预算内证明可读的那部分词典，其余的由一个 worker 读完后统一重装一次。没有 Windows OneDrive 云占位真机复现，属于代码路径加单测层面的验证。
