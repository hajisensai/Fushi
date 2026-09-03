## BUG-1799 · galgame 台词列表「已制卡」徽章是单向内存 latch，Anki 删卡后永不复核
- **报告**：2026-08-23（用户原话：「anki扫描好像不是实时的 我制卡后然后去anki删了，还是显示已制卡。」）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/sync/texthooker_service.dart:341`（旧 `final bool mined`）
  + `:745` 旧 `markLineMined(String id)`。
  - **定位到底是哪块 UI**：界面上出现「已制卡」这四个字的只有 galgame 捕获工作台台词列表
    （`fushi/lib/src/pages/implementations/texthooker_page.dart:2738` → `_LineMinedChip` `:2852`，
    文案 `game_line_mined`；筛选器 `game_filter_mined` `:1872`）。查词弹窗那条车道显示的是
    ✓ 符号而非文字，且它**本来就是实时的**（BUG-186 已把它改成查词时实时探测 Anki），
    所以用户说的不是它。收藏夹页的 `collection_mined` 是制卡历史流水，删卡后仍在列属预期。
  - **根因**：`TexthookerLineEntry.mined` 是个 `bool` 单向 latch，只记录了「制卡这个动作发生过」，
    **没有记录制出来的是哪张卡**。`markLineMined` 只能 false→true（`:747` 已 mined 直接 return），
    全仓没有任何一处会把它清回去。数据结构里缺少身份，导致它**结构上无法复核** —— 不是
    「忘了刷新」，是「就算想刷新也没有可查的凭据」。
  - 对照：Anki 数据源本身两端都是实时的（AnkiConnect `findNotes` /
    AnkiDroid `findDuplicateNotes`），查词弹窗每次渲染都实时查（`popup.js:2909`）。
    这条 galgame 徽章车道是唯一一个从不问 Anki 的「已制卡」显示。
- **[x] ① 已修复** — 修数据结构，而不是加一个刷新定时器：
  - `texthooker_service.dart`：`TexthookerLineEntry` 新增 `minedNoteId`（制出的那张 note 的 id
    = 复核凭据）；`markLineMined(id, {int? noteId})` 记下它，幂等口径改成「已 mined **且** id 没变
    才跳过」，这样覆写既有卡 / 先前没带回 id 的行也能补登记；新增 `clearMinedForNotes(Set<int>)`
    把确认已删除的卡对应的行清回未制卡，新增 `minedNoteIds` 供页面批量取证。
  - `packages/fushi_anki/lib/src/base_anki_repository.dart`：新增 `findDeletedNotes(Set<int>)`，
    **返回值口径是本次修复的要害**——只返回「后端明确应答、且应答里没有这张 note」的 id；
    查询失败 / 不可达 / 后端不支持一律**空集**。刻意不用 `bool`/`Map<int,bool>`：`bool` 表达不了
    「不知道」这个第三态，而把「问不到」误判成「已删除」会在 Anki 没开着时清空满屏徽章，
    比不复核更糟。基类默认空集 = AnkiDroid / AnkiMobile 保持旧 latch 行为不变。
  - `ankiconnect_repository.dart`：用一次 `notesInfo` 批量往返实现（常数 1 次，不随 id 数增长）；
    `notesInfoMany` 对不存在的 note 收到的是空对象项并已跳过，故「id 不在返回 map 里」精确等于
    「Anki 说这张 note 没了」。不复用 `isDuplicate` 的 30s 不可达冷却窗（BUG-1302）——那个冷却是给
    渲染路径上逐词条的高频探测省超时的，本方法是切回前台才跑一次的低频复核，借它只会让
    「Anki 刚重新可达」的那次复核白跑。
  - `texthooker_page.dart`：State 挂 `WidgetsBindingObserver`，`didChangeAppLifecycleState`
    收到 `resumed` 时复核（用户原始路径「制卡 → 切去 Anki 删卡 → 切回 Hibiki」回到 app 的那一刻），
    进页首帧也复核一次（覆盖「卡在别的页面制的」）；`_revalidatingMined` 单次在途守卫防重入。
  - `gal_hook_mining_coordinator.dart:409`：制卡成功回写时带上 `outcome.noteId ?? updateNoteId`
    （覆写既有卡时 outcome 不带新 id，退回本次覆写目标 id）。
  - 未触碰：hook DLL / helper / IPC 契约 / LunaHook / 引擎 adapter / 文本线程选择 / 语音配对；
    `engine-support.yaml` 原封不动（改 UI 不构成任何引擎状态变化）；查词弹窗 popup.js 制卡状态机
    未动；`MiningStatistics` / `LookupMiningCounters` 未动（历史计数，删卡不应减，与 BUG-186 同口径）。
- **[x] ② 已加自动化测试** —
  - 行为（TexthookerService 层，12 例）：`fushi/test/mining/texthooker_mined_revalidation_test.dart`
    —— 记 note id / 幂等 / 覆写补登记 / `minedNoteIds` 口径；确认删除→徽章消失、可重新制卡、
    只在真清掉时通知；**「绝不误清」组是核心不变式**：空集（= 不可达）什么都不清、别的 id 不误伤、
    没有 note id 的行永不被清。
  - 契约（Anki 仓库层，7 例）：`packages/fushi_anki/test/find_deleted_notes_test.dart`
    —— 缺席即已删除、全在则空集、一次批量往返、空输入不打网络、**不可达返回空集**、
    业务错误同样空集、基类默认降级空集。
  - **变异实测**（两处，各自逐字节还原并 SHA-256 校验）：
    ① 把 `clearMinedForNotes` 的清除改成 `continue`（还原成旧 latch）→「徽章消失」组 3 例红；
    ② 把 `findDeletedNotes` 的 catch 从空集改成 `return noteIds`（把不可达当全删）→「绝不误清」
    的 2 例红。守卫确认有效。
- **备注**：
  - 验证：`flutter test test/mining`（1081 通过）、`fushi_anki` 包全量（430 通过）、
    `fushi/test/lookup` + `test/anki`（913 通过）、`flutter analyze`（fushi 全量 No issues）、
    `dart analyze --fatal-infos`（fushi_anki，No issues）。
  - **未验证项（照 SOP 逐项记账）**：真 Anki 端到端（在本页制卡 → 在 Anki 桌面删掉那张卡 →
    切回 Hibiki 看徽章消失）需要真 AnkiConnect + 真游戏会话，host 侧测不到，与 BUG-186 的
    既有免责口径一致。`didChangeAppLifecycleState` 在 Windows 桌面窗口切换时是否稳定发
    `resumed` 未经真机确认——即便它不发，进页复核与后续制卡回写仍会纠正徽章，只是纠正时机变晚。
