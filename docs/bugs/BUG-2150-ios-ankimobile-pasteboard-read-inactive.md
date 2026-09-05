## BUG-2150 · iOS AnkiMobile 配置回传读不到剪贴板：URL 回调跑在 .inactive 阶段
- **报告**：2026-09-05（用户：两张 iPhone 截图 —— ① 从 Anki 返回后首页弹红条 `No AnkiMobile configuration was found on the clipboard.`；② 制卡设置页显示 `AnkiMobile opened. Approve the request, then return to Fushi.`，两句都是中文 UI 里的英文原文）
- **真实性**：✅ 真 bug。根因 `fushi/ios/Runner/AppDelegate.swift:64`（原）：方法通道 `consumeInfoForAddingPasteboard` 在收到调用的那一刻直接 `UIPasteboard.general.data(forPasteboardType: "net.ankimobile.json")`。
  而这个调用的触发链是 **AnkiMobile 的 x-success 把 Fushi 拉回前台**：
  `fetchConfiguration` 打开 `anki://x-callback-url/infoForAdding?x-success=fushi://ankiFetch`
  （`fushi/lib/src/anki/ankimobile_repository.dart:111`）→ AnkiMobile 写剪贴板后回跳 →
  iOS 调 `application(_:open:options:)`（`AppDelegate.swift:221` 原）→ `deliverUrl` → EventChannel →
  `fushi/lib/main.dart:1059` `handleIncomingUrl` → `:1072` `consumeInfoForAddingPasteboard`。
  **iOS 在 URL-driven resume 上的文档顺序是 `willEnterForeground` → `application(_:open:)` → `didBecomeActive`**，
  也就是说整条链跑在 app `.inactive` 阶段。iOS 只允许**前台活跃**的 app 读别的 app 写进通用剪贴板的内容
  （iOS 16+ 还要为此弹一次系统「允许粘贴」确认，而弹窗只有 active 的 app 能呈现），于是读必然拿到 nil。
  剪贴板类型和「读完清空」的写法本身没错 —— 与 AnkiMobile 官方手册 URL Schemes 一节给的示例逐字一致。

  **第二个缺陷（同一条错误信息）**：`fushi/lib/src/anki/ankimobile_repository.dart:128`（原）把三种**下一步动作完全不同**的
  情形压成同一句硬编码英文：① AnkiMobile 根本没写（用户没在 AnkiMobile 里同意那次请求 —— 官方手册原话
  "If the user authorises the request"）；② 写了但系统不让读；③ 真空。而且 `fetchConfiguration` 的两句、
  `consume` 的三句全部没有稳定码，`AnkiViewModel.localizeAnkiFetchError` 只能原样透传英文 —— 截图里中文 UI 显示英文即此。

- **[x] ① 已修复** —
  - **时序（根因）**：`fushi/ios/Runner/AppDelegate.swift` 新增 `consumeAnkiMobilePasteboard(result:)`：读取的前置条件从
    「URL 回调到了」改成「app 真的 active 了」。非 active 时挂一次性 `UIApplication.didBecomeActiveNotification`
    观察者，等真正活跃后再读；`ankiMobilePasteboardActiveTimeout = 5s` 兜底，超时仍尽力读一次并如实报告，
    不让 Dart 侧的 Future 永久挂起。`FlutterResult` 由 `finished` 闸门保证恰好回调一次。
  - **三态（诊断）**：新增 `readAnkiMobilePasteboard()` 返回 `{status, json}`，用 **不触发粘贴确认弹窗** 的元数据 API
    `UIPasteboard.general.contains(pasteboardTypes:)` 把 `denied`（数据在、系统不让读）与 `empty`（AnkiMobile 没写）分开；
    「类型在但内容为空」归 `empty`（那是我们自己取走后写回的空 `Data`，不是被拒）。
  - **Dart 契约**：`AnkiMobileInfoReader` 由 `Future<String?>` 改为 `Future<AnkiMobilePasteboardRead>`
    （`AnkiMobilePasteboardStatus{ok,empty,denied}`），`consumeInfoForAddingPasteboard` 按三态分流。
  - **文案**：新增 5 个稳定码 `AnkiErrorCode.ankiMobileOpened / ankiMobilePasteboardEmpty /
    ankiMobilePasteboardDenied / ankiMobileNoDecks / ankiMobileUnavailable`
    （`packages/fushi_anki/lib/src/anki_models.dart`），经 `AnkiViewModel.localizeAnkiFetchError`
    与 `localizeAnkiMineError`（`fushi/lib/src/utils/misc/error_log_service.dart`）映射到 5 个新 i18n key
    （17 语言，`i18n_sync --add` + `dart run slang`）。制卡路径的「打不开 AnkiMobile」共用同一个码。
  - **顺带**：`fetchConfiguration` 的 `infoForAdding` URL 改走 `_buildAnkiMobileQuery`，与 BUG-558 为 `addnote`
    定下的百分号编码规则统一 —— 此前它是同一个类里的第二套编码（`Uri.replace(queryParameters:)` 把空格编成 `+`）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/anki/ankimobile_pasteboard_states_test.dart`（新，12 条）：三态各自的稳定码、
    `denied`/`empty` 不共用码也不共用文案、`ok` 但 json 为空按 `empty` 处理、`fetchConfiguration` 两个码、
    `x-success` 百分号编码、以及「五个码在中文 UI 下都不再吐英文原文且五条互不相同」。
  - `fushi/test/anki/ankimobile_ios_callback_static_test.dart`（+2 条）：Swift 进不了 `flutter test`，
    源码守卫是这层唯一可落地的自动化。守「方法通道的 case 只许分发给带时序门的 helper、不许在那一刻直接碰
    `UIPasteboard`」+「`applicationState == .active` / `didBecomeActiveNotification` / `removeObserver` 必须在」
    +「`pasteboardTypes:` 非提示性探测与 `denied`/`empty` 两态必须在」。截取 case body 时带自检，避免恒真。
  - **变异实测**（不是「写了守卫就算数」）：把 case 改回「回调那一刻直接读」→ 守卫红，理由
    「case 必须分发给带 active 门的 helper」；单独把 `applicationState == .active` 改成 `true` → 守卫红，
    `Expected: contains 'UIApplication.shared.applicationState == .active'`。两次都还原后复绿。
- **备注**：
  - **真机缺口**：AnkiMobile 是 App Store 付费 app，装不进模拟器，本机也没有能跑它的 iOS 设备，所以
    「回到原始失败路径复测」这一步没做。已做到的最强验证是：Swift 侧在远程 Mac（macOS 26.6.1 /
    iPhoneSimulator26.5 SDK）上 `swiftc -parse` 整文件通过，并把新增的两个方法**逐字抽出**对 iOS SDK
    `swiftc -typecheck -target arm64-apple-ios15.0-simulator` 通过（UIPasteboard API 名、闭包捕获、
    `DispatchWorkItem`、通知观察者、`[String: Any]` 返回全部成立）；Dart 侧三态契约与文案 318 条测试全绿。
  - 若真机复测后仍失败，本次改动已把结果收敛成两句可判读的话：看到「AnkiMobile 没有回传配置」= AnkiMobile
    那一侧没写（多半没点同意 / 版本太老），看到「iOS 阻止了读取剪贴板」= 系统粘贴权限那一关。原来那句
    「剪贴板上没有配置」两种都可能，无法据以决定下一步。
  - 新增 5 个 i18n key 的 15 个非 en/zh-CN 语言按 `i18n_sync --add` 的既有行为落的是英文值，属既有翻译欠账。
