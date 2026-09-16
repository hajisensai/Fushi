## BUG-2532 · iOS AnkiMobile 不显示已制卡：加卡回跳的 x-success 被丢弃，isDuplicate 恒 false
- **报告**：2026-09-14（用户：「ios 还不会检测是否已制卡」）
- **真实性**：✅ 真 bug（沿真实代码路径定位到确定性缺陷，模拟器端到端复现并复测）。
  链路：popup.js 每个词条 `scheduleEntryStateCheck('duplicate\0…')` → `duplicateCheck` 桥 →
  `dictionary_page_mixin.dart:490` / `base_source_page.dart:917` → `repo.isDuplicate(expression, reading)`
  → iOS 落到 `fushi/lib/src/anki/ankimobile_repository.dart:701`（上游 `017429cd40`）
  **`Future<bool> isDuplicate(...) async => false;`** ——恒假，`setMineState(false)` 恒把按钮画成 `+`，
  iOS 用户从来看不到 ✓（连带 ↗「在 Anki 中打开」也恒不显示，它由 `data-mined` 门控）。
  根因**不止是「AnkiMobile 查不了」**：AnkiMobile 手册 URL Schemes 一节写明
  `x-success` 是「use to automatically return to another app **after the note is added**」——
  即它送达就等价于 AnkiMobile 确认这张卡进了库。`ankimobile_repository.dart:557` 早就把
  `fushi://ankiSuccess?expression=…` 挂进了 addnote URL，但 `fushi/lib/main.dart:1178`
  收到这条回调只有一句 `return true;`：**唯一一份确定性的「已制卡」真值，到手即弃**。
  于是 iOS 端既没有外部真值（平台边界）也没有内部真值（本缺陷），`isDuplicate` 只能恒 false。
- **[x] ① 已修复** —
  - `fushi/lib/src/anki/ankimobile_mined_ledger.dart`（新）：`AnkiMobileMinedLedger` 进程级单例，
    SharedPreferences 键 `fushi_ankimobile_mined_expressions`，内存 `LinkedHashSet` 索引（插入序 =
    最久没再制过的在前）。跟着 anki 仓库层既有的持久化走（设置串 `fushi_anki_settings` 就在那儿），
    不为一个 iOS 专属的降级账本动 Drift schema。上限 5000 条（约 50 KB，plist 无压力），
    溢出淘汰队首；重制同一个词会把它挪到队尾，淘汰的才是真正最久没碰过的。
    载入/写入全 fail-soft：查重在弹窗渲染热路径上，账本坏了最坏结果是 ✓ 少画，绝不打断制卡链路。
  - `fushi/lib/main.dart`：`fushi://ankiSuccess` 分支改为 `_recordAnkiMobileMinedNote(data)`，
    取回 URL 上的 `expression` 落账。落账时机**只认 x-success**，不认「addnote URL 打开了」——
    后者只说明 AnkiMobile 被拉起来了（用户可能直接退出、`profile=` 对不上、或被 AnkiMobile 按
    `dupes` 拦下），拿它当已制卡会画出骗人的 ✓。
  - `fushi/lib/src/anki/ankimobile_repository.dart`：`isDuplicate` 改问账本；新增
    `openWordInAnki` 覆写 + `buildAnkiMobileSearchUri`（手册 `anki://x-callback-url/search?query=`，
    AnkiMobile 2.0.90+），整词加引号按短语搜、`"` 转义。**这条是 ✓ 的连带爆炸半径**：popup 只在
    ✓ 亮着时才显示 ↗，而基类默认车道（`findMatchingNotes` → `openNoteInAnki`）在本后端恒空——
    不补这条，✓ 一亮就会多出一个必然失败的按钮。↗ 与 ✓ 共用同一份真值：账本不认得就如实回
    `noMatch`，不去打开一个注定搜不到东西的界面。
  - 匹配口径 = **expression 全等（仅 trim）**，与 AnkiConnect 的 `isDuplicate` 对齐（那条也只把
    第一字段发给 Anki 问）。不拿 reading 做二次过滤是有意的：同词在不同词典里的读音标注常有出入
    （送假名 / 清浊 / 别读），当作必要条件会把「明明制过卡」判成没制过。两种错代价不对称：
    false ✗ 只是少画提示、用户照常制卡；false ✓ 会让用户以为卡已经有了而跳过。
- **[x] ② 已加自动化测试** —
  - `fushi/test/anki/ankimobile_mined_ledger_test.dart`（新，17 条）：账本十条（记过才算 / 落账与提问
    同 trim 口径 / 空词不落账 / 穿透持久层重启仍认得 / 重复制不留两份 / 超上限淘汰队首 / 重制挪队尾改变
    淘汰对象 / 持久层坏了当空账本不抛 / 杂质被滤掉 / 并发提问只读一次）；仓库消费五条
    （isDuplicate 不再恒 false、reading 不参与匹配、↗ 认得就开 search、不认得回 noMatch 且不开界面、
    打不开是 failed 不是 noMatch）；URL 构造两条（空格 %20 短语搜、引号转义）。
  - `fushi/test/anki/ankimobile_ios_callback_static_test.dart`：加一条 `main.dart` 源码守卫，
    钉死 `fushi://ankiSuccess` 分支必须落账（此前就是那句 `return true;` 把真值丢了）。
  - `fushi/integration_test/ios_ankimobile_mined_detection_itest.dart`（新）+ 替身
    `fushi/integration_test/support/fake_ankimobile/main.swift` 扩到受理 `/addnote` 与 `/search`：
    iOS 模拟器上跑真往返——真 app 发 addnote → 替身 AnkiMobile 收下并回跳 `fushi://ankiSuccess`
    → 真 SceneDelegate → EventChannel → `main.dart` → 账本 → `isDuplicate` 转真。
    编排脚本加 `TEST=` 变量复用 BUG-2493 那套弹窗放行器：
    `TEST=integration_test/ios_ankimobile_mined_detection_itest.dart bash fushi/integration_test/support/fake_ankimobile/run_sim_itest.sh`
- **备注**：
  - **能力边界，别当成「判重」对外宣称**：账本只知道**本机经 Fushi 制成**的卡。直接在 Anki 里加的、
    别的设备上加的、装 Fushi 之前加的，以及用户事后在 Anki 里删掉的，iOS 上没有任何通道能核对
    （`anki://x-callback-url` 只有 addnote / infoForAdding / search / sync 四个入口，没有回读 collection
    的通道；AnkiConnect 的 `canAddNotesWithErrorDetail`、AnkiDroid 的 ContentProvider
    `findDuplicateNotes` 在 iOS 上都没有对应物）。所以 iOS 的 ✓ 语义是「Fushi 记得你制过」，
    弱于另外两个后端的「Anki 说库里有」。溢出上限后最老的词不再画 ✓ 也是静默降级——方向是安全那边。
  - **实测证据**（2026-09-14，FushiProbe / iPhone 17 Pro / iOS 26.5 (23F77)，连跑两轮都
    `flutter test exit=0` 且各 1 条测试执行）：替身容器 plist 里四个键齐全——
    `addNoteCount => 1`、`lastAddNote => "deck=FakeDeck type=FakeBasic | Front=見物 | Back=sightseeing"`
    （Fushi 真发出了字段映射正确的 addnote）、`lastSearch => ""見物""`（↗ 的 search 腿真送达，
    且是带引号的短语）；真屏截图上替身显示 `search / query="見物"`。第一轮 tapper 点掉了一次
    系统的「"Fushi" 想要打开 "FakeAnki"」，第二轮 iOS 记住授权后 0 次。
    🔴 **读证据要读容器 plist，别只看编排脚本那行 `fakeanki prefs:`**——它在 flutter test 刚结束
    就读，会抢在替身最后一次落盘之前，只印出 `addNoteCount` 一个键，看起来像「什么都没发生」。
    权威读法：`plutil -p "$(xcrun simctl get_app_container <udid> app.fushi.fakeankimobile data)/Library/Preferences/app.fushi.fakeankimobile.plist"`。
    （替身现在每次写完都 `synchronize()`，落盘本身不再是问题，races 的只是脚本读的时机。）
  - 真 AnkiMobile 仍装不进模拟器（付费 App Store app，同 BUG-2150 / BUG-2493 的缺口），本轮实测用的是
    替身 app 走同一套 URL scheme 契约。替身与手册逐字对齐（`x-success` 在加卡之后才回跳），
    但真机上 AnkiMobile 是否在**所有**失败形态下都不回 `x-success`，仅有手册措辞为据，未能实机穷举。
  - 未做、也不该顺手做的：`findMatchingNotes` / `findOverwriteTargetNoteId` / `noteFields` /
    `findDeletedNotes` 在本后端仍保留基类降级。AnkiMobile 既不回传 note id 也没有按 id 操作的入口，
    账本里没有 note id 可记——硬造一个假 id 会让「覆写既有卡」链路拿着它去做注定失败的事。
