## BUG-3220 · iOS 制卡后不跳回 Fushi，已制卡打勾不见
- **报告**：2026-10-09（应用内反馈 _QdIClIdEc，shishamo，iOS 27.2 (24B5084k)，iPhone18,3，2.10.0-debug.18345：「ios 制卡后不跳回 fushi，并且完成制卡打勾提示不见了」）
- **真实性**：❌ 未复现（Fushi 侧链路在 iOS 模拟器上端到端完好；真 AnkiMobile 侧无法在本机验证）。
  - **两个症状是同一根因的两面**：iOS 上「已制卡 ✓」唯一的真值来源是 AnkiMobile 加完卡后打开的
    `x-success`（`fushi://ankiSuccess?expression=…`，`fushi/lib/src/anki/ankimobile_repository.dart` 的
    `successCallback`；收口 `fushi/lib/main.dart` `handleIncomingUrl` → `_recordAnkiMobileMinedNote` →
    `AnkiMobileMinedLedger`，见 BUG-2532）。「制卡成功」toast 在拉起 AnkiMobile 的同一刻弹出，用户这时
    已在 AnkiMobile 里；以前几秒内被 x-success 拉回来还看得到它，现在不回跳就看不到。所以只要
    x-success 没触发，「不跳回」与「打勾不见」一起出现。
  - **Fushi 侧逐项核过，未见回归**：
    - `fushi/ios/Runner/Info.plist` 仍注册 `fushi` scheme（plistlib 解析确认 `CFBundleURLTypes`），
      `FlutterDeepLinkingEnabled=false`（BUG-2459），`LSApplicationQueriesSchemes` 含 `anki`；最近动过
      该文件的提交（游戏串流、配对深链等）只改了用途说明文案，没碰 URL 类型。
    - `SceneDelegate.swift` 冷启动（`connectionOptions.urlContexts`）与热启动（`openURLContexts`）都把 URL
      交给 `AppDelegate.deliverUrl` → `app.fushi.reader/url_events` 通道，近期提交只动了方向回调。
    - `handleIncomingUrl` 里排在 AnkiMobile 前面的分流（`fushi://source`、`fushi://pair` 配对深链确认框、
      `fushi://shortcut`、`fushi://lookup`）都按 host 精确匹配，`fushi://ankiSuccess` 不会被吞。
    - addnote URL 构造（`buildAnkiMobileAddNoteUri`，x-success 在查询串末尾）自 BUG-2532 起未改；
      近期 `ankimobile_repository.dart` 的提交只涉及待发制卡队列与来源回跳复习。
  - **模拟器实测（2026-10-09，Mac，iPhone 17 Pro / iOS 26.5，本 PR 当前提交 `e79ec4c362`）**：
    - `fushi/integration_test/ios_ankimobile_mined_detection_itest.dart`（FakeAnkiMobile 替身，真
      `anki://x-callback-url/addnote` 跨 app 跳转 → 替身收卡后打开 x-success → 真 SceneDelegate →
      EventChannel → `main.dart` → 账本 → `isDuplicate` 转真 → ↗ 打开 search）：**通过**，替身
      `addNoteCount=1`，回跳后只有一个 HomePage，系统弹窗放行器 0 次点击。
    - 同一测试把释义换成约 16.8 万个日文字符（addnote URL 约 1.5 MB）再跑：**通过**，替身收到的
      Back 字段完整、x-success 照常回跳——排除「卡片内容变大后 URL 被截断、末尾的 x-success 丢失」。
  - **结论**：Fushi 一侧注册、接收、落账、画 ✓ 全链路完好；没跳回发生在 AnkiMobile 是否打开
    x-success 这一步，本机无法验证（AnkiMobile 是付费 App Store app，装不进模拟器；用户机是 iOS 27.2
    beta）。可能的外部原因：AnkiMobile 没有直接加卡而是停在添加界面（必填字段为空 / 重复卡被拦下 /
    牌组或笔记类型对不上），这几种情况下它不会回调 x-success。
- **[ ] ① 未修复** — Fushi 侧未找到缺陷，不做猜测性改动。需要用户补充：AnkiMobile 版本；卡片到底有没有加进
  AnkiMobile；拉起 AnkiMobile 后停在哪个界面（直接回到牌组 / 停在「添加」编辑界面 / 弹了重复卡提示）；
  换一个从没制过的词、换书本（非有声书）各试一次是否也不回跳。
- **[ ] ② 未加自动化测试** — 现有 `ios_ankimobile_mined_detection_itest.dart` 已覆盖 Fushi 侧整条回跳链路，本次复跑通过。
- **备注**：反馈截图里查词弹窗只剩顶栏、正文空白，是应用内截图抓不到平台 WebView 造成的，不代表弹窗本身空白。
