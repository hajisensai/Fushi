## BUG-1284 · 查词弹窗被网络超时阻塞数秒（远端查词 remote-first + 逐词条 AnkiConnect 查重）

- **报告**：2026-07-31（用户：「词典出来的速度特别特别慢，还有可能卡死，某些用户电脑上出来要 4-5 秒」）
- **真实性**：✅ 真 bug。沿真实代码路径全链审计（触发 → Dart 调用链 → C++ 引擎 → 弹窗渲染）后确认，「某些用户电脑」不是玄学，而是**两条只在特定配置下才付费的秒级网络超时**都压在查词关键路径上。BUG-717 三轮优化后开发机端到端 40-66ms，与用户报的 4-5 秒差约 100 倍——差的就是这两条（引擎侧的词典数线性放大另见 [BUG-1286](BUG-1286-engine-freq-pitch-enrich-before-truncate.md)，挂死另见 [BUG-1285](BUG-1285-hoshidicts-hash-probe-unbounded.md)）。

  - **根因①：远端查词排在本地缓存之前，且是全仓唯一不消费不可达信号的调用点**
    `hibiki/lib/src/models/app_model.dart:3843-3865` 的 remote-first 分支在 `buildSearchCacheKey` / `getCachedSearch` **之前** await 远端：
    ```dart
    if (tryRemoteFirst) {
      final remoteResult = await _searchRemoteDictionary(...);  // ← 网络
      if (remoteResult != null) return remoteResult;
    }
    final cacheKey = buildSearchCacheKey(...);                   // ← 缓存在其后
    ```
    传输层 `hibiki/lib/src/sync/interconnect_post_transport.dart:58-133` **按序遍历所有已启用候选**，每候选 `.timeout(timeout)`，超时值 `hibiki/lib/src/sync/hibiki_remote_lookup_client.dart:29` = **3 秒/候选**，传输失败只 `continue` 到下一个。配对设备离线 / 换网 / 休眠时：1 候选 ≈ **3s**，2 候选 ≈ **6s**；且因为短路在缓存之前，**重复查同一个词也全额付费**。
    而 `InterconnectPostTransport` 早就返回了 `allUnreachable`（「试过且一个 HTTP 响应都没拿到」）——音频路径 `lookupAudioUrl` 消费它并计入 45s 冷却（BUG-575 / TODO-1057），**词典路径是全仓唯一把它丢掉的调用点**，原注释白纸黑字写着「词典路径不消费 allUnreachable：失败面维持原样（返回 null），零行为变化」。
    `remote_lookup_enabled` 默认 false（`preferences_repository.dart:224`）→ 只影响开过互联/远程查词的用户，**正是「某些用户电脑」的形状**。
  - **根因②：AnkiConnect 查重在渲染时逐词条发起，连接超时 5s**
    `hibiki/assets/popup/popup.js:2693` 的 `duplicateCheck` 桥调用位于 `createEntryHeader()`，而 `createEntryHeader` 由 `buildEntryElement` 调用 → `renderPopup()` 对**结果里每个 entry** 跑一次。后端超时 `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart:47-48` = 响应 10s / 连接 5s。AnkiConnect 主机被防火墙静默丢包（DROP 而非 RST）、VPN 断开、或配成了不在线的远程主机时，**每个词条各挂满 5s**，N 个词条就是 N 条并发挂起的 HTTP 压在弹窗渲染路径上。本地 Anki 没开是 connection refused（快速失败），所以同样只在部分配置下发作。
    并且 `hibiki/lib/src/platform/platform_services.dart:92` 的 `createAnkiRepository: AnkiConnectRepository.new` 意味着**每次桥调用都新建一个 repository 实例**，任何实例级的失败记忆都存不住。
  - **连带真 bug：`_searchRemoteDictionary` 的 `return` 漏了 `await`**
    `app_model.dart:3959` 直接 `return HibikiRemoteLookupClient(...).searchDictionary(...)`，`try/catch` 只能抓同步 throw，**异步错误全部漏出成 uncaught**。音频路径 `lookupRemoteAudio`（`app_model.dart:5220-5222`）早已修过同一处写法并留了注释，词典路径遗留至今。
- **[x] ① 已修复** — 提交：见本轮 PR
  - 根因①：`HibikiRemoteLookupClient.searchDictionary` 与 `lookupAudioUrl` **对称**消费 `allUnreachable`，全候选传输层失败时抛 `RemoteLookupUnreachableError`；`AppModel._searchRemoteDictionary` 捕获它并写入 `_remoteDictionaryUnreachableUntil`，冷却窗（`kRemoteDictionaryFailureCooldown` = 45s，对齐音频侧 `kRemoteAudioFailureCooldown`）内**直接短路不发请求**。拿到任何 HTTP 响应（含「可达但无结果」）立刻清零冷却。**设备活着时行为完全不变**——「远端优先」语义未改，只是不再为已证实死掉的设备重复付超时。顺带把漏掉的 `await` 收进 `try`。
  - 根因②：`AnkiConnectRepository.isDuplicate` 加**进程级静态**不可达冷却（`kDuplicateCheckUnreachableCooldown` = 30s；必须静态，因为每次桥调用都新建实例）。**只对传输层失败生效**（`SocketException` / `TimeoutException` / `http.ClientException`，与 `_mineFailureFor` 同一套分类）——主机应答了业务错误说明它活着，短路它会让查重永久失灵。返回值语义与既有 fail-soft 完全一致（false）。成功探测立即清零冷却。
- **[x] ② 已加自动化测试** — 提交：见本轮 PR
  - `hibiki/test/sync/hibiki_remote_lookup_client_test.dart`：词典路径全候选传输层失败必须抛 `RemoteLookupUnreachableError`（**契约变更**——旧用例 `dictionary lookup keeps returning null when all candidates are unreachable` 断言的正是被修掉的旧行为，已改写并在注释里说明原因）；可达主机答 404 仍返回 null（不误触冷却）；未配对返回 null 不抛（刚配好对的第一次查词不被冷却窗吃掉）。
  - `hibiki/test/anki/anki_duplicate_check_cooldown_test.dart`（新增）：传输层死主机只探测一次、冷却窗内**零 HTTP 请求**；冷却跨 repository 实例共享（模拟 `createAnkiRepository()` 每词条新建）；**可达主机答业务错误不进冷却**（防「短路把查重永久搞坏」）；成功探测立即清冷却；冷却窗有界（≤1 分钟）。
- **备注**：
  - 用户截图确认弹窗形态是「**外壳已显示、内容区整块空白**」，即弹窗在等 `popupRendered` 等不到、被兜底超时硬 reveal 成空壳（in-app failsafe 1.8s `dictionary_popup_controller.dart:120`；app 外 ready-safety 阶梯 450ms×7=3.15s `global_lookup_controller.dart:126-127`）。这两个兜底是症状的显示器，不是根因，本轮未动。
  - 用户另一张截图显示其**释义词典有 7 本以上**（含 Pixiv / Nico_Pixiv 这类超大词典），另有汉字/词频/音调三类——这条放大的是 [BUG-1286](BUG-1286-engine-freq-pitch-enrich-before-truncate.md) 的引擎侧线性成本，与本条网络超时并列、互不替代。
  - 同轮审计发现但**未修**、留作后续的项（按收益排序）：查词 FFI 全链同步跑在 UI isolate（`app_model.dart:3899`，`lookup/query/queryKanji/getMediaFile` 均无 `Isolate.run`，是「卡死」的架构级成因）；reader/video/剪贴板/全局热键路径的 Shift-hover 连续查词**无 debounce**（仅 8px 位移节流，代次守卫只丢结果不取消已排队的同步 FFI）；词典对话框勾一下「隐藏/折叠」触发**整引擎重建**并清空两级缓存（`dictionary_repository.dart:192-216` → `persistDictionary` → `onCacheRebuild`）；`maxResults=200`（load-more 分页深度硬依赖）；popupJson 每次重建（FFI 缓存命中也重建，实测单条 54-231KB）；带图词典的媒体走同步 FFI 逐张阻塞（`dictionary_webview_media.dart:102`）。
