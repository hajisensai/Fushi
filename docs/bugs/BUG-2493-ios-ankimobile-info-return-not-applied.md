## BUG-2493 · iOS AnkiMobile 回跳后牌组/笔记类型不刷新：x-success 未送达时无兜底、互联制卡包裹层静默丢弃回调
- **报告**：2026-09-13（用户：「ios 的 anki 刷新牌组和笔记类型在 anki 确认跳回 fushi 后还是没刷新」——BUG-2150 修完仍复现；无截图，未说明设置页那行文案是什么）
- **真实性**：✅ 真 bug（沿真实代码路径找到两处确定性缺陷；真机未能复测，见备注）。
  往返链：设置页「刷新」→ `AnkiViewModel.fetchConfiguration` → `AnkiMobileRepository.fetchConfiguration`
  （`fushi/lib/src/anki/ankimobile_repository.dart`）打开 `anki://x-callback-url/infoForAdding?x-success=fushi://ankiFetch`
  → AnkiMobile 写剪贴板、回跳 → `SceneDelegate.scene(_:openURLContexts:)` → `AppDelegate.deliverUrl` → EventChannel
  → `fushi/lib/main.dart` `handleIncomingUrl` → `_handleAnkiMobileInfoCallback` → 读剪贴板 → `applyFetchedConfiguration`。
  1. **`main.dart:1158`（原）`if (repo is! AnkiMobileRepository) return;` 对 iOS 上每个人都成立**：`ankiRepositoryProvider`
     （`anki_view_model.dart:571`）自 `d55752a5e1`（2026-09-10「制卡后自动按词频重排新卡」）起**恒**把本地仓库包在
     `AutoRepositionAnkiRepository` 里，开了「制卡到已配对设备」再多一层 `RemoteMiningAnkiRepository`（配置类方法仍委派本地
     AnkiMobile 仓库，所以 AnkiMobile 照样会被打开）。回调到了却被这一行静默丢弃：不读剪贴板、不落库、不清中间态，用户看到的
     正是「跳回来什么都没变」。时间线与用户报告吻合：09-10 合入自动重排 → 09-11 BUG-2459 修掉「跳回主页」→ 用户再报「还是没刷新」。
     本地 develop 没有自动重排那层，所以在本地代码上只看到了互联那一层；**模拟器实测第一步（解包断言）就把这层撞出来了**。
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
    新增 `resolveAnkiMobileRepository()`：逐层剥开 `AutoRepositionAnkiRepository.inner` / `RemoteMiningAnkiRepository.local`
    （后者新增 `local` getter）直到 `AnkiMobileRepository`，不是 AnkiMobile 后端时返回 null。
  - `fushi/lib/main.dart`：`_handleAnkiMobileInfoCallback` 与 `didChangeAppLifecycleState(resumed)`（仅 iOS）共用
    `_consumeAnkiMobileInfoReturn(trigger)`；结果为 null 时不动 UI。原生侧 `AppDelegate.swift` 不改：resumed 时机上 app 已 active，
    走的是 BUG-2150 的即读分支；AnkiMobile 没写时 `contains(pasteboardTypes:)` 元数据探测不弹「允许粘贴」提示。
- **[x] ② 已加自动化测试** —
  - `fushi/test/anki/ankimobile_info_return_coordinator_test.dart`（新，18 条）：状态机八条（未请求不读 / 回到前台即终点 /
    URL 后 resume 不重读 / resume 后 URL 不重读 / 在途不并发 / 冷启动读一次且重复不读 / notActive 保留等待态 / 新一轮重开），
    仓库接入两条（fetch 后 resume 取回且随后 URL 不重读 / 打不开不进等待态），解包五条（裸仓库 / 互联壳 / 自动重排壳与
    自动重排(互联(本地)) 两层 / 非 AnkiMobile 为 null / **源码守卫：`lib/src/anki` 下每个包着 `BaseAnkiRepository` 的包装类都必须在
    解包器里登记**——再加一层包装就会把 iOS 回传链再次静默切断），`main.dart` 源码守卫三条（不再 `is! AnkiMobileRepository` /
    resumed 分支带 `appResumed` / 两路共用 `consumeInfoForAddingReturn`）。
  - `fushi/test/anki/ankimobile_ios_callback_static_test.dart`：Dart 启动守卫改认新入口 `consumeInfoForAddingReturn(`。
  - **iOS 模拟器实测**（第二个提交）：`fushi/integration_test/ios_ankimobile_info_return_itest.dart` 在真 iOS 进程上跑完整往返——
    真 URL scheme 跨 app、真系统剪贴板、真 SceneDelegate → EventChannel → `main.dart` → AppDelegate 读剪贴板。对手是
    `fushi/integration_test/support/fake_ankimobile/`（AnkiMobile 装不进模拟器）：swiftc 直接编成模拟器 .app 的替身，按第 N 次请求
    切三种回跳形态（r1 不写 + x-success / r2 写剪贴板 + x-success / r3 写剪贴板 + 只回前台），牌组名带 rN 供测试分辨。
    跑法（Mac，一条命令）：`bash fushi/integration_test/support/fake_ankimobile/run_sim_itest.sh <udid>`——它编装替身、清剪贴板、
    卸载 Fushi 拿干净容器、后台跑 `flutter test … -d <udid>`，并在 flutter 的 Xcode 构建结束后起
    `fushi/integration_test/support/ios_alert_tapper/`（xcodegen 生成的 XCUITest 工程）自动放行两种系统弹窗：
    「"Fushi" 想要打开 "FakeAnki"」与 iOS 16+ 跨 app 读剪贴板的「允许粘贴」。ssh 起的进程没有辅助功能授权投不了 CGEvent，
    idb-companion 又要 Xcode 27，只有 XCUITest 走模拟器内部 AX 通道能点到 SpringBoard 的弹窗；且必须等构建结束再起，
    flutter 的 xcodebuild 会把同一模拟器上在跑的 XCUITest 会话打断（runner「unexpected exit」，实测两次）。
    **结果（2026-09-13，iPhone 17 Pro 模拟器 / iOS 26.5 / Xcode 26.6，连跑两轮）**：`All tests passed`，每轮 13 s、三次
    `Lifecycle Resumed`（三次真跨 app 往返）、放行器点了 3 次「允许粘贴」；真屏截图见 `~/dev/ios-shots/anki/`（Fushi 回到前台、
    顶栏「◀ FakeAnki」返回链、系统「"Fushi" 想从 "FakeAnki" 粘贴」提示压在首页上——提示能弹出本身就证明读剪贴板发生在 active
    之后，BUG-2150 的时序门成立）。三形态各自断言：r1 报「没有回传配置」而非挂中间态；r2 牌组/笔记类型/字段落地、中间态清空、
    `HomePage` 仍只有一份（BUG-2459 不复发）、随后 2 s 内不被兜底路径的第二次读盖掉；r3 没有 ankiFetch 回调、只回前台也取回牌组。
    **第一次跑就撞出的真根因**：解包断言 `resolveAnkiMobileRepository(...) != null` 红——provider 给的是
    `AutoRepositionAnkiRepository`（见真实性第 1 条），本地代码上根本看不到这层。
- **备注**：
  - **与真机的差距**：模拟器上的对手是替身而非 AnkiMobile 本尊，AnkiMobile 自己的「允许 Fushi 读取？」确认与它写剪贴板/调
    x-success 的实现没被测到；其余整条链（URL scheme 跨 app、系统剪贴板与「允许粘贴」提示、SceneDelegate → EventChannel →
    main.dart → AppDelegate 三态读取、resumed 兜底、往返去重）都在真 iOS 进程上跑过。Mac 上配对着一台 iPhone 17（`HUAWEI 17`，
    本地网络、装有开发签名），要真机复测可 `flutter run -d <该设备>` 后由人在 AnkiMobile 里点同意——本轮它不在线。
    若真机仍不刷新，设置页那行文案现在每条失败都是稳定码（`empty`/`denied`/`notActive`/`no decks`），能直接定位到哪一关。
  - 上一次修复 BUG-2150 时把「读得太早」当成唯一根因，但同一条链上还有这两处，说明当时的路径复核只看了 iOS 时序没看 Dart 侧分发。
