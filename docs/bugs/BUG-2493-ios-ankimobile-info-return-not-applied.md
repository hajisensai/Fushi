## BUG-2493 · iOS AnkiMobile 回跳后牌组/笔记类型不刷新：x-success 未送达时无兜底、互联制卡包裹层静默丢弃回调
- **报告**：2026-09-13（用户：「ios 的 anki 刷新牌组和笔记类型在 anki 确认跳回 fushi 后还是没刷新」——BUG-2150 修完仍复现；无截图，未说明设置页那行文案是什么）
- **真实性**：✅ 真 bug（沿真实代码路径找到两处确定性缺陷；真机未能复测，见备注）。
  往返链：设置页「刷新」→ `AnkiViewModel.fetchConfiguration` → `AnkiMobileRepository.fetchConfiguration`
  （`fushi/lib/src/anki/ankimobile_repository.dart`）打开 `anki://x-callback-url/infoForAdding?x-success=fushi://ankiFetch`
  → AnkiMobile 写剪贴板、回跳 → `SceneDelegate.scene(_:openURLContexts:)` → `AppDelegate.deliverUrl` → EventChannel
  → `fushi/lib/main.dart` `handleIncomingUrl` → `_handleAnkiMobileInfoCallback` → 读剪贴板 → `applyFetchedConfiguration`。
  1. **`main.dart:1158`（原）`if (repo is! AnkiMobileRepository) return;`**：`ankiRepositoryProvider`
     （`anki_view_model.dart:536`）在「制卡到已配对设备」开着时返回的是 `RemoteMiningAnkiRepository` 壳
     （`fetchConfiguration` 仍委派本地 AnkiMobile 仓库，所以 AnkiMobile 照样会被打开），回调到了却被这一行静默丢弃：
     不读剪贴板、不落库、不清中间态，用户看到的正是「跳回来什么都没变」。
  2. **整条回传链只有 `fushi://ankiFetch` 一个入口，没有任何兜底**：x-success 没送达（AnkiMobile 侧没触发、系统没派发、
     或用户自己切回 Fushi）时，剪贴板上明明已有 `net.ankimobile.json`，Fushi 永远不会去读；设置页挂着
     `fetchConfiguration` 写下的「已打开 AnkiMobile，请去同意」中间态直到用户再点一次刷新（又被弹去 AnkiMobile）。
     `notActive`（原生等前台 5 s 超时）那条路同样没有后续——下次回到前台也不会再试。
  参照同类 iOS app（Hoshi Reader `Core/AnkiManager.swift`、Mangatan `anki_mobile_service.dart`）都在回跳后有重试/多路读取，
  本仓此前是单入口单次读。
- **[x] ① 已修复** —
  - `fushi/lib/src/anki/ankimobile_repository.dart`：新增进程级单例 `AnkiMobileInfoReturnCoordinator`（往返状态机）与
    `AnkiMobileInfoReturnTrigger{urlCallback, appResumed}`。`fetchConfiguration` 成功打开 AnkiMobile 后 `markRequested()`；
    新入口 `consumeInfoForAddingReturn(trigger)` 由状态机决定读不读：**同一次往返只读一次**（剪贴板取走即清空，第二次读必然
    `empty`，会把刚成功的结果盖成错误）；在途时另一条路直接放弃；`notActive` 保留等待态让下次回到前台再试；冷启动（本进程
    没发起过请求）收到 URL 回调仍读一次、重复送达不再读。状态挂单例而非仓库实例，因为 `ankiRepositoryProvider` 会随互联开关重建实例。
    新增 `resolveAnkiMobileRepository()`：从 `RemoteMiningAnkiRepository` 解包到本地仓库（`remote_mining_anki_repository.dart`
    新增 `local` getter），不是 AnkiMobile 后端时返回 null。
  - `fushi/lib/main.dart`：`_handleAnkiMobileInfoCallback` 与 `didChangeAppLifecycleState(resumed)`（仅 iOS）共用
    `_consumeAnkiMobileInfoReturn(trigger)`；结果为 null 时不动 UI。原生侧 `AppDelegate.swift` 不改：resumed 时机上 app 已 active，
    走的是 BUG-2150 的即读分支；AnkiMobile 没写时 `contains(pasteboardTypes:)` 元数据探测不弹「允许粘贴」提示。
- **[x] ② 已加自动化测试** —
  - `fushi/test/anki/ankimobile_info_return_coordinator_test.dart`（新，13 条）：状态机八条（未请求不读 / 回到前台即终点 /
    URL 后 resume 不重读 / resume 后 URL 不重读 / 在途不并发 / 冷启动读一次且重复不读 / notActive 保留等待态 / 新一轮重开），
    仓库接入两条（fetch 后 resume 取回且随后 URL 不重读 / 打不开不进等待态），解包三条（裸仓库 / 互联壳解包 / 非 AnkiMobile 为 null），
    `main.dart` 源码守卫三条（不再 `is! AnkiMobileRepository` / resumed 分支带 `appResumed` / 两路共用 `consumeInfoForAddingReturn`）。
  - `fushi/test/anki/ankimobile_ios_callback_static_test.dart`：Dart 启动守卫改认新入口 `consumeInfoForAddingReturn(`。
- **备注**：
  - **真机缺口同 BUG-2150**：AnkiMobile 是付费 App Store app，装不进模拟器，本机无可跑它的 iOS 设备，未能在原始路径复测。
    本次修的两处是从代码读出的确定性缺陷（互联开关下必丢、无兜底），但**不能排除**还有第三处只在真机上出现的问题
    （例如 iOS 16+「允许粘贴」提示在 didBecomeActive 那一刻的呈现时机）。若真机复测仍不刷新，请截设置页那行文案：
    现在每条失败都是稳定码（`empty`/`denied`/`notActive`/`no decks`），能直接定位到哪一关。
  - 上一次修复 BUG-2150 时把「读得太早」当成唯一根因，但同一条链上还有这两处，说明当时的路径复核只看了 iOS 时序没看 Dart 侧分发。
