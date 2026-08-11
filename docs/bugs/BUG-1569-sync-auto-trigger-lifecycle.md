## BUG-1569 · 互联自动同步触发层三缺口：离线探测零退避·合集观察者关库不卸载·sweep 丢弃退出书同步
- **报告**：2026-08-12（用户：互联健壮性审计）
- **真实性**：✅ 真 bug（三处，同层合档）：
  - **① 离线探测零退避**：`fushi/lib/src/pages/implementations/home_page.dart`
    （`_periodicSyncInterval` 每分钟 tick）→ `sync_auto_trigger.dart` 的
    `_runAutoSyncAll` 冷却闸只认成功戳 `lastSyncMs`，而该戳由
    `sync_orchestrator.dart` `run()` 在整轮**完整跑成后**才写（TODO-1332 有意；
    修复前 ~617 行），通道异常（只配互联且对端离线：`findOrCreateRootFolder`→
    全候选探测失败抛 `SyncBackendError`，修复前 ~468 行）发生在写戳之前 → 冷却
    永不推进，每分钟全额重付「2s × 候选数」串行探测。
  - **② collectionsSyncWatcher 生产无卸载**：`installCollectionsSyncWatcher`
    （`sync_auto_trigger.dart:553` 一带）在 `app_model.dart:2437` 安装；
    `uninstallCollectionsSyncWatcher` 修复前只有测试 teardown 调用，
    `closeDatabase` / `closeForPopup` / `dispose`（`app_model.dart` ~5360/5375/5390）
    全不撤——未决防抖 Timer 到点对已关闭 db 跑 `_runCollectionsSync`（drift
    "connection was closed"）。
  - **③ 退出书同步被 sweep 静默丢弃**：`sync_auto_trigger.dart` `_runAutoSync`
    （修复前 ~670 行）`if (_syncingIds.contains('__all__')) return;` 直接丢弃——
    sweep 那几十秒里退出书的进度悄悄不同步，无记账无补跑。
- **[x] ① 已修复** —
  - ①：新增**内存态**失败退避戳 `_autoSweepFailureBackoffUntilMs`（固定退避 =
    `_syncCooldownMs` 5 分钟）。语义：自动/手动全量 sweep 以 failed 收场 →
    记 now+5min，退避窗内自动 sweep 判 `cooledDown` 跳过；completed 清零；
    autoDisabled/cooledDown/noChannels 不触碰。**不写 lastSyncMs**（键结构不动，
    与并行的按后端拆冷却戳工作正交）、**不落盘**（重启归零，保 TODO-1332 的
    「启动即同步」跨启动语义）；手动同步不受闸约束（显式意图恒放行）。
  - ②：`app_model.dart` 三条路径（`closeDatabase` / `closeForPopup` / `dispose`）
    均补 `uninstallCollectionsSyncWatcher()`（撤表订阅 + 取消未决防抖 Timer）。
  - ③：sweep 进行中的 per-book 请求记入 `_pendingBookSyncsDuringSweep`（按
    mediaIdentifier 去重，后到覆盖先到），自动/手动 sweep 收尾统一
    `drainPendingBookSyncsAfterSweep()` 补跑（fire-and-forget，messenger=null、
    onReport 保留，与后台路径同语义；补跑撞上新 sweep 会重新记账，不丢不死循环）。
- **[x] ② 已加自动化测试** —
  `fushi/test/sync/sync_auto_trigger_lifecycle_test.dart`：
  - ① 退避状态机单测（fake now：失败推进/窗满放行/completed 清零/其余不触碰）+
    集成（对端死端口 → 第一轮 failed 置退避、第二轮 cooledDown 且 <1s 不走网络）；
  - ② 行为测试（未决防抖 Timer 随 uninstall 取消，关库后无轻量同步结局）+
    源码守卫（AppModel 三条关库/销毁路径必须含 `uninstallCollectionsSyncWatcher()`）；
  - ③ 行为测试（sweep 中记账去重 → drain 补跑真的执行，`lastSyncOutcome` 出现
    singleBook 结局）。
  守卫已变异实测（删 closeDatabase 的 uninstall → 源码守卫红；删 drain 调用 →
  ③ 用例红；删失败退避 note → ① 集成用例红）。
- **备注**：③ 的补跑针对的是「sweep 过书之后用户又读了一段才退出」的窗口；
  per-book 同步幂等，补跑代价一次轻量往返。① 的退避对 `noChannels`（未配置）
  不生效——那条路径本就只做本地读、开销可忽略。
