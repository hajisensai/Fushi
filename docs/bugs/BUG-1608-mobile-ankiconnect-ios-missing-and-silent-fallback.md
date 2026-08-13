## BUG-1608 · iOS 没接 AnkiConnect（Lapis 区永远隐藏）；移动端清空 API key 后开关静默失效
- **报告**：2026-08-14（用户：「可视化配置 lapis 要支持手机端」「安卓这个问题也全修复」）
- **真实性**：✅ 两条都是真 bug。
  - **① iOS 缺接线**：`fushi/lib/src/platform/platform_services.dart:124-132`（改前）iOS 分支只传
    `createAnkiRepository: AnkiMobileRepository.new`，既没传 AnkiConnect 工厂、也没置 `isAndroid`。
    而后端选择的门是 `_isAndroid && _useAnkiConnectOnAndroid`（`:68`），iOS 一票否决 →
    `supportsNoteTypeEditing` 恒 false → 设置页 Lapis 样式区（`anki_settings_page.dart:128`
    的 `if (vm.supportsNoteTypeEditing)`）在 iOS 上**永远隐藏**。AnkiConnect 是纯 HTTP，
    iOS 上本来就能指向局域网里跑 Anki 桌面版的机器——缺的只是接线。
  - **② 清空 API key 后静默失效**：设置页的 API key 输入框直接接 `vm.updateAnkiConnectApiKey`
    （改前 `anki_settings_page.dart:121`）。开关已打开时把 key 清空，`useAnkiConnectOnAndroid`
    在设置里仍是 true、`PlatformServices._useAnkiConnectOnAndroid` 也仍是 true（没有任何一处
    重算），一直到**下次启动** `PlatformServices.init()`（`:97-102`）才把设置悄悄改回 false。
    用户回来看到开关自己关了、Lapis 区不见了，全程零提示；而在改回之前的那段时间里，存储
    说「走 AnkiConnect」、运行时也说「走 AnkiConnect」，但请求已经不带 key 了。
  - 判据被抄成三份是根因：UI 门控（`:589` `apiKey.trim().isEmpty`）、运行时选择
    （`platform_services.dart:81` `value && apiKey.trim().isNotEmpty`）、启动期修复（`:97`）
    各写一遍，谁都没在「key 被清空」这个事件上重算。
- **症状预测**：iOS 用户完全看不到 Lapis 可视化配置入口，且无从判断是没做还是坏了。
  Android 用户清空 key 后下次启动开关自己关闭、Lapis 区消失，会当成 app 的随机 bug。
- **[x] ① 已修复**
  - iOS 接上 AnkiConnect：`PlatformServices` 的 `_isAndroid`/`createAndroidAnkiConnectRepository`
    泛化为 `_isMobile`/`createMobileAnkiConnectRepository`，iOS 分支传入
    `AnkiConnectRepository.new` + `isMobile: true`；设置页开关与分区折叠改按
    `_isMobileAnkiPlatform`（Android || iOS）门控。AnkiMobile 仍是 iOS 默认（升级安全）。
  - 判据收敛成一份：新增 `AnkiSettings.ankiConnectUsableOnMobile`（开关开 **且** key 非空），
    UI 门控、`PlatformServices.setUseAnkiConnectOnMobile`、启动期修复三处共用它。
  - 清空 key 当场处置：API key 输入框改接页面自己的 `_updateAnkiConnectApiKey`——检测到
    「移动端 + 开关原本开着 + 新 key 为空」时立即关开关、换回原生后端、重建仓库 provider，
    并弹 `anki_connect_mobile_disabled_key_cleared` 明确告知原因。`init()` 里的静默改写降级
    为**只给存量坏状态兜底**，正常路径不再产生这种组合。
  - 命名：Dart 侧 `useAnkiConnectOnAndroid` → `useAnkiConnectOnMobile`；**持久化 JSON 键名
    冻结**为 `useAnkiConnectOnAndroid`（改键名会让老装置的选择在升级后静默丢失）。
- **[x] ② 已加自动化测试** — `fushi/test/platform/mobile_anki_backend_selection_test.dart`
  （由 `android_anki_backend_selection_test.dart` 改名而来，14 例）：iOS 拿到与 Android 同样的
  选择、桌面无此支路、持久化键名冻结的读写往返、`ankiConnectUsableOnMobile` 三态、以及
  「清空 key 后运行时立刻回落原生后端」。其中源码扫描守卫改断言 `_isMobileAnkiPlatform`
  与 `onChanged: _updateAnkiConnectApiKey`，防止有人把门控改回 `Platform.isAndroid` 或把
  输入框重新直连 vm。
- **备注**：真机验收（iOS 上指向局域网 AnkiConnect 跑通 Lapis 客制化）尚未做——本机没有
  可用 iOS 真机链路，缺口如实记在这里，不当作已验证。
