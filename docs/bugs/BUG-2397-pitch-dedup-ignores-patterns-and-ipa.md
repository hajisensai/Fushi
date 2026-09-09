## BUG-2397 · 音调去重对 pattern 式音调与 IPA 完全不生效
- **报告**：2026-09-10（用户：「fushi 音调去重没用」）
- **真实性**：✅ 真 bug，**三条独立根因**（①用 node 真执行 `createPitchSection` 复现，
  ②③沿真实代码路径定位到具体行）：
  - **根因①** `fushi/assets/popup/popup.js:2903`（去重分支）：`seen` 只收 **数字位置**
    `pitchPositions`，`patterns`（"heiban" 等 pattern 式音调）与 `transcriptions`（IPA 音标）
    一概不参与去重；保活守卫又写成 `group.transcriptions?.length` / `group.patterns?.length`
    这种「**原始**字段非空」，于是第二本词典哪怕一个字都不新，也照样整行渲染出来。
    上游 BUG-2122 的 `mergeIdenticalPitchGroups` 只接得住「整份 payload 全等」那一种，
    两本词典只要在任意一个字段上差一点（一本带 IPA、一本不带）合并就不成立，重复
    全部落到去重这一步——而这一步对这两类视而不见。
    复现（去重**打开**）：`d1{patterns:['heiban']}` + `d2{patterns:['heiban'],transcriptions:['ɡiꜜtaː']}`
    → 渲染出 **两行** `[heiban]`；`d1{[1],ipa:X}` + `d2{[0],ipa:X}` → 同一段 IPA 打印 **两遍**。
  - **根因②** `fushi/lib/src/models/app_model.dart:3252`（`browserExtensionThemeColors`）：
    这个偏好从未被放进 app 下发给浏览器扩展的 theme 通道，`tools/browser-extension/content.js`
    也没有任何一处给 `window.deduplicatePitchAccents` 赋值。扩展弹窗与 app 内弹窗跑的是
    同一份 `popup.js`，它的去重分支读的就是这个全局 → 在扩展里恒 `undefined`（falsy），
    **浏览器里的音调去重从上线起就没生效过**，与用户在 app 里的设置完全无关。
  - **根因③** `fushi/android/app/src/main/java/app/fushi/reader/PopupDbReader.kt:202`：
    Android 原生独立弹窗词典（`:popup` 进程的 `PopupDictActivity`，系统级选词/悬浮查词）
    自己起 WebView 加载同一份 `popup.js`，偏好由 `readPrefs` 直接读 SQLite `preferences` 表，
    写法是 `prefs["deduplicate_pitch_accents"] == "true"`。而 Dart 侧
    `PreferencesRepository.getPref(key, defaultValue: true)`（`preferences_repository.dart:1752`）
    的默认值**只活在 Dart 内存里、从不落库**——用户没主动点过这个开关时表里根本没有这一行，
    `null == "true"` 判成 `false`。净效果：**设置页显示「开」，系统级弹窗里却是关的**，
    而绝大多数用户从没理由去点一个看起来已经开着的开关。同一处还连累另外两个 Dart 默认为
    `true` 的键（`harmonic_frequency` / `collapse_dictionaries`）。
- **[x] ① 已修复** — `6dda5c84cd`
  - 根因①：`createPitchSection` 的去重改成**逐类**：`seenPositions` / `seenPatterns` /
    `seenTranscriptions` 三个 Set 各自过滤，保活判据从「原始字段非空」改成「**去重后**
    还剩东西」，`Object.assign` 透传时三类可见条目都换成去重后的那份。三份 popup.js
    镜像（app / 扩展 assets / 扩展 tools）同步，保持逐字节一致。
  - 根因②：`app_model.dart` 的 theme 字典加 `--fushi-dedup-pitch`（'1'/'0'，非 CSS 变量、
    仅 JS 消费，与 `--fushi-instant-scroll` 同法），两份 `content.js` 的 `fushiApplyTheme`
    里据此设 `window.deduplicatePitchAccents`。缺该 key = 旧 app，保持关闭（向后兼容）。
  - 根因③：`PopupDbReader` 加 `boolPref(prefs, key, default)`，四个布尔偏好全部改走它并
    **显式写出与 Dart 一致的默认值**（缺行 = 跟 Dart 走默认，只有落库的值才覆盖）；
    `PopupPrefs` data class 的构造默认值（DB 打不开那一档）一并对齐。
  - 行为不回归：BUG-2122（五本同 `[1]` 塌成 1 行 5 枚来源药丸）与 TODO-688（纯 IPA 词典
    在去重下仍渲染 IPA）都在新测试里显式钉住，逐字节不变。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_pitch_dedup_patterns_ipa_test.dart`
  （+ 同名 `.js` 行为 harness）：
  - 行为级：node 真执行 `createPitchSection` —— 同 pattern 只显示一次、同 IPA 只显示一次、
    两个不同数字位置都保留、**关掉开关重复必须回来**（非恒真）、TODO-688 与 BUG-2122 不回归。
    把三个 Set 里任何一个退回原来的单一 `seen`，对应 case 立刻红（已在上游原文上反向验证：
    case 1 报 `got 2 copies`）。
  - 源码级：扫三份 popup.js 镜像，钉住三个 Set、三条 filter、以及「保活判据用去重后的结果」。
  - 接线级：钉住 `app_model` 下发 `--fushi-dedup-pitch` + **两份** content.js 消费它——
    根因②那条链路上没有任何行为测试覆盖得到，只能靠这条守卫防它悄悄回来。
  - 既有 `popup_pitch_transcriptions_test.dart` 的 TODO-688 静态守卫同步升级：判据从
    「原始 transcriptions 非空」改成「去重后仍有独有 transcriptions」，并逐条钉住三类
    收窄字段。
  - 根因③：`fushi/test/pages/popup_native_pref_defaults_guard_test.dart`——从
    `preferences_repository.dart` 正则抽出每个布尔偏好的 `defaultValue:`，与
    `PopupDbReader.kt` 里 `boolPref(...)` 的默认值**逐键比对**，再钉住「不许退回裸
    `== "true"`」和「data class 构造默认值同样对齐」。那条链路跑在独立进程 + 真
    Android WebView 上，widget 测试够不到，只能在源码层钉不变式。反向验证：把
    Kotlin 默认值翻成 false，守卫立刻报出 `defaults to true in Dart but false in
    PopupDbReader`。
- **备注**：
  - 相邻缺口（**本次未修，另开**）：扩展侧同样从未赋值的还有 `harmonicFrequency`、
    `showExpressionTags`、`collapseDictionaries` 等 popup 开关——它们在浏览器里同样恒
    `undefined`。本次只按用户报告修音调去重，不扩大范围。（根因③那处不同：四个键是
    **同一个表达式模式、同一次读取**，同一处代码的同一个缺陷，故一并修。）
  - 制卡侧不受这个开关管（**本次未修**）：`popup.js` 的 `buildMinePayload` →
    `constructPitchPositionHtml`（1571 行）/ `constructPitchCategories`（1610 行）只跑
    `mergeIdenticalPitchGroups`，不做屏显那边的跨组位置去重，也不读
    `window.deduplicatePitchAccents`。两本词典 payload 不全等但标了同一个位置数字时，
    卡片字段里会出现两个同值 `<li>`。这个开关的 UI 在「查词」设置组、语义是屏显，
    要不要连制卡一起管是产品决定，不在本次报告范围内。
  - 观感相邻项（**本次未修**）：`DictionaryPopupWebViewState` 不 watch `appProvider`，
    在设置页切这个开关后**已经打开**的弹窗不会立即重渲，要等下一次查词才吃到新值
    （`_pushResults` 只在 `widget.result` 变化时重注入）。属独立的「设置热切换」缺口。
