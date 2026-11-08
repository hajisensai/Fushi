# 第二块屏（双屏伴屏 + 游戏串流副屏）

> [CLAUDE.md](../../CLAUDE.md) 的子文档。改副屏原生宿主、伴屏面板、页面接线（`companion.part.dart` /
> `controller_lookup.part.dart`）或手柄查词模式前先读这里。只做 Android（AYN Thor 这类自带第二块屏的掌机，以及任何
> 接了外接显示器的 Android 设备）；其他平台 `SecondScreenHost.forCurrentPlatform()` 返回 null，行为与单屏完全一致。

## 1. 一个宿主、一个额外进程

- **原生宿主只有一套**（主进程）：`SecondScreenDisplay.java`（DisplayManager 监听、启动 / 收回面板、channel）+ 纯状态机
  `SecondScreenLifecycle.java`（JVM 测试 `android/app/src/test/kotlin/app/fushi/reader/SecondScreenLifecycleTest.kt`）。
- **面板**：`SecondScreenActivity.java`，跑在独立进程 `:second_screen`（WebView 数据目录后缀 `second_screen`），中转
  `SecondScreenRelayService.java`（Messenger）。channel `app.fushi.reader/second_screen`（`ChannelNames.SECOND_SCREEN` /
  `FushiChannels.secondScreen`）。旧的 `GameStreamCompanion*` 四件套、`game_stream_companion` channel 与 `:companion`
  进程已删除，不留回退。
- 为什么不用 `Presentation`：查词词典要真 Activity 里的 WebView；完整的 popup AppModel 只在自己进程里安全；第二个
  engine 里的 WebView 有 Impeller 拆除卡死风险（BUG-2790）。
- **面板模式每次启动固定**：`companion` | `gameStream`（intent extra `EXTRA_MODE`，面板经 `launchInfo` 读）。换模式 =
  原生收回旧面板、用新 token 起新面板。非当前注册面板发来的消息在原生侧直接丢弃。
- Dart 主侧：`lib/src/second_screen/second_screen_host.dart` 的 `SecondScreenHost`（全局单例）按模式仲裁：**游戏串流
  优先于伴屏**，串流放手后伴屏自动回来。平台接口 `SecondScreenPlatform`（测试替身
  `test/second_screen/fake_second_screen_platform.dart`）。
- 游戏串流是宿主的一个客户端：`game_stream_panel_host.dart`（`GameStreamPanelHost`），面板端
  `panel/game_stream_panel_app.dart`；串流协议类（`GameStreamCompanion*Message`、bridge、`GameStreamCompanionPage`）保留原名。
- 面板入口：`lib/second_screen_main.dart`（`secondScreenMain`，由 `main.dart` 转发）按模式渲染串流面板或伴屏
  （`panel/companion_panel_app.dart`）。

## 2. 生命周期与启动策略

- 能力检查只用标准 API，不写 Thor 特例、不硬编码 display id：API ≥ 29、不是自身所在屏、非 `FLAG_PRIVATE`、
  state ≠ OFF、`ActivityManager.isActivityStartAllowedOnDisplay`。
- 面板只在 MainActivity started 期间存活：stop 时 finish，start 时若仍想要就重启（重启失败发 `hostReset`）；屏被拔掉 /
  关掉 → 立即收回，所有页面回到单屏行为（页内查词弹窗等），不崩。
- 策略（`second_screen_controller.dart`）：设置「第二块屏」= 自动（默认）/ 总是 / 关闭（偏好 `second_screen_mode`）。
  自动模式对每块新屏（指纹 `name|wDp x hDp`，偏好 `second_screen_approved_displays`）在主屏问一次「把这块屏用于
  Fushi？」（`second_screen_approval_host.dart`），同意后每次启动自动起；「暂不」只管本次运行。两个键都是设备本地键
  （`SyncRepository` 不同步）。
- `SecondScreenController.isActive` 是唯一真相源：想要伴屏 **且** 当前挂着的面板模式是 `companion`（串流占屏时为 false）。
  重新请求只由屏幕事件 / reset / 策略变化触发，从不由面板事件触发（防崩溃循环）。
- 设置行 `appearance.second_screen_mode` 与紧随其后的 `appearance.second_screen_lookup_screen`（两者只在有第二块屏时显示）、
  `appearance.controller_lookup_style`（始终显示）。
- 「查词结果显示在」`SecondScreenLookupScreen {bottom, top}`（偏好 `second_screen_lookup_screen`，设备本地，默认 bottom）：
  `SecondScreenController.lookupScreen`，`CompanionBridge` 把它镜像成 `CompanionContextRegistry.lookupsOnCompanion`。
  Top = 主屏查词一律走页内弹窗，伴屏照常显示面板（Now / Library / Settings 照用，Lookup 页签仍可手动打开看历史）。

## 3. 协议

- 每条消息一个 JSON 对象 `{"type": ...}`，经 `SecondScreenHost.post` 与 `SecondScreenPipe`（`second_screen_pipe.dart`，
  超过 64K UTF-16 单元落盘、以 `@file:` 前缀传路径）。消息要粗粒度：一次状态变化 / 一次用户动作一条，绝不逐帧。
- 定义在 `companion/companion_protocol.dart`（纯 Dart，未知 type 抛 `FormatException`）：
  - 主 → 面板：`context`、`snapshot`、`summary`、`nowPlaying`、`lookup`、`prefsChanged`、`libraryChanged`、
    `settingsChanged`、`lookupAction`、`panelNav`、`reply`、`uiRestore`（`ready` 后第一条：上一个面板的 UI 状态）。
  - 面板 → 主：`ready`（主侧重发全部状态）、`command`、`playback`、`openOnMain`、`request`、`lookupState`、`lookupCounted`、
    `uiState`（`CompanionPanelUiState`：页签、Library 模式 / Browse 分区 / 搜索、Settings 分类页 / 搜索）。
  - 通用请求 `request(id, method, args)` → `reply(id, value, error)`；方法名集中在 `CompanionRequestMethods`
    （`summary.refresh`、`settings.*`、`library.*`），主侧 `CompanionBridge.registerRequestHandler` 按方法注册。
- 主侧 `companion_bridge.dart` + `companion_main_services.dart`（`companionBridgeProvider`）：伴屏未激活或面板未 `ready`
  时一条都不发。

## 4. 上下文模型

- `CompanionContextKind {none, home, library, settings, reader, video, manga, audiobook, music, srs, gameStream}`。
- `companion/companion_context.dart`：全局 `companionContexts` 注册表 + `companionContextRouteObserver`（`main.dart` 注册）。
  页面用 `CompanionContextClaim` 声明；**最新的、且其页面在栈顶的 claim 胜出**（盖在上面的对话框不算）；无 claim 时
  home 路由在顶就用 home shell 当前页签，否则 `none`。
- 页面接线：`companion_page_link.dart` 的 `CompanionPageLink`（claim + 快照发布器），**只在伴屏激活且本页持有上下文时**
  约每秒构建一次快照、按 JSON 去重；未激活时零 timer、零构建。页面不 import bridge / AppModel 层（`import_cycle_guard`
  有棘轮）。
- 查词路由：`companion_lookup_routing.dart` 的 `routeCompanionLookup(...)`，true = 伴屏 Lookup 页签接走，false = 页内弹窗
  照旧。阅读器在 `_handleTextSelected` 顶部统一路由（paginated / continuous / vn / 有声书视图共用一条路径）。
  「查词结果显示在」只在这一个点生效（`CompanionContextRegistry.routeLookup` / `routesLookups`，手柄跟进键用
  `lookupController`），页面里不写特例。**面板上发起的查词**（长按 / 点面板上的字幕、转写、歌词、OCR 文本）不经过这里，
  无论设置如何都在下屏 Lookup 页签打开（用户此时就在看下屏）。

## 5. 面板（4 个纯图标页签，各自一个 Navigator）

`panel/companion/companion_shell.dart`：**Now / Library / Lookup / Settings**，`adaptiveBottomBar(showLabels: false)`，
根 `PopScope` 先弹当前页签，重选页签弹回根。顶部换了新媒体只刷新 Now 的内容，不切页签。
面板每次随主屏 stop 结束（文件选择器、Home），所以 UI 状态由主进程保管：面板每次变化发 `uiState`，主侧
`CompanionBridge` 只在内存里留最新一份（不落盘），新面板 `ready` 时先收到 `uiRestore`，`CompanionPanelSession.uiState` /
`uiRestores` 驱动壳、Library、Browse、Settings 各自恢复（恢复本身不回报）。

- **Now**（`companion_now_tab.dart`）：按上下文渲染模块面板（注册在 `companion_context_panels.dart`）——阅读器、有声书、
  视频、漫画、音乐、SRS、串流；无媒体时是每日摘要（今天读 / 看 / 听的时长、SRS 到期数 +「在主屏复习」、一个继续项）。
  信息卡只用已缓存数据（视频 `VideoMetadataWorks/Episodes`、书 `EpubBooks` + `Bookmarks` + `ReadingStatistics`、漫画源
  元数据与 `CollectionScrapeMeta`），缺数据就隐藏该行，不编值、不发新的元数据网络请求。
- **Library**（`panel/companion/library/`）：`adaptiveSegmentedButton` 切 **Main | Browse**，两种模式各有 Navigator 与状态。
  Main 只在主屏是书库时可用：显示主屏高亮条目（手柄焦点 / 长按 / `MediaSelectionController.anchor`），搜索 / 排序 /
  筛选改的是主屏列表。Browse 是副屏自己的书库（继续、书、漫画、视频、有声书、音乐、Jellyfin / Plex / ABS、合集、
  详情）；从这里打开 → 主屏先按正常离开方式保存位置再打开，副屏切到 Now，并显示 5 分钟的「回到 <上一个>」。
  在线源、统计、词典管理等 →「在主屏打开」。
- **Lookup**（`companion_lookup_tab.dart`）：嵌入式 `PopupDictionaryPage(embedded: true)`（制卡、词音、条目切换都来自弹窗
  本身；embedded 不套自己的 SafeArea，insets 归页签管，否则底栏高度被算两次）+ 内存里的查词历史（50 条）。主屏发来的查词、模块面板上点 / 长按的行（查按下的那个字起的词，`CompanionLineTile.onLongPressChar` 给字下标）都自动切到本页签（词典只渲染在这里，留在 Now 上结果不可见），关闭后回到原页签；历史重查不切。历史标签显示词典匹配到的词头（`PopupDictionaryPage.onHeadword`），没有结果时才显示扫描文本。
- **Settings**（`companion_settings_tab.dart`）：先列「当前屏幕」的分类，再是搜索 + 全部分类。

- 启动配色：面板进程的 `AppModel.initialiseForDictionaryPopup` 在偏好加载后立刻建好界面语言、主题与壁纸色板并置
  `isAppearanceReady`，`runCompanionPanel` 在 `runApp` 之前就开始初始化；`CompanionPanelApp` 在此之前只画一块纯表面色，
  不先用默认种子色（蓝）画界面——之前要等整个初始化（词典、语言引擎、快捷键）完成，每次面板重启都蓝几秒。只有初始化失败
  才用回退主题。守卫 `test/second_screen/panel_process_system_palette_guard_test.dart`、
  `test/second_screen/companion_panel_startup_theme_test.dart`。

## 6. 设置索引共享

- `fushi/lib/src/ops/settings_index.dart` 是**唯一**设置索引（从 `ctl_settings_routes.dart` 抽出，`fushi_cli config` 与伴屏共用）。
- 主侧 `companion/companion_settings_service.dart`：overview / category / search / get / set / openOnMain；上下文 → 分类映射
  `companionSettingsCategoryFor`。写入在**主进程**、走与 ctl 相同的写路径；开关 / 分段 / 滑块 / 步进 / 数字在副屏直接改，
  文本 / 密钥 / 自定义 / 列表 / 动作行 →「在主屏打开」。
- 选项与当前值的人读标签：`settingsIndexChoices` / `settingsIndexValueLabel`（设置页同一串文案，在主进程按主屏语言解析；
  主题行显示主题名）。`fushi_cli config` 的 JSON 不变，仍只给 token。
- 同步：`preferences` 表每次更新和每次伴屏写入后发 `settingsChanged`；`preferences` + `dictionaryMetadata` 更新还发
  `prefsChanged`，面板据此刷新 popup AppModel（主题、语言、词典设置），不留陈旧状态。

## 7. 书库数据路径

**面板不读 Drift 库。** 书库的每次读 / 写 / 打开都是 bridge 请求，在主进程里由 `companion/companion_library_service.dart`
（`CompanionLibraryService`，数据端口 `CompanionLibraryData`，真实适配器 `companion_library_app_data.dart`）回答。理由：
标题 / 进度 / 完成 / 继续规则已由主应用 provider 推导，不在面板复制；媒体服务器本来就得走主应用客户端；面板进程的 DB
连接是完整读写连接，「只读」只能靠约定。主侧库变化时发 `libraryChanged`，面板只重载可见页。封面按文件路径给
（`companion_covers.dart` / `companion_cover_files.dart`、`RemoteCoverCache.cachedFile`）。条目引用格式见
`library_companion_schema.dart` 的 `CompanionLibraryRef`。

## 8. 手柄模式

- 契约 `input/controller_lookup_target.dart`：`ControllerLookupStyle {holdL1, selectToggle, off}`（偏好
  `controller_lookup_style`，设备本地；未设置 = 伴屏在时 holdL1，否则 off）与页面实现的 `ControllerLookupTarget`。
- `input/controller_lookup_mode.dart`（`ControllerLookupMode.instance`）排在一切页面分派之前：桌面在
  `gamepad_service.dart` 的 `_dispatchButton`，Android 在 `FocusManager` 早期按键处理器。
  - **查词模式**（按住 L1 ≥250 ms）：方向键 / 左摇杆 ←/→ 词（Y 切字符）、↑/↓ 行；A 查词，弹窗开着再按 A 制卡；X 词音；
    RT/LT 下 / 上一条；右摇杆滚动；B 先关弹窗再退出。查词走各页原路径（伴屏在且「查词结果显示在」= 下屏就进 Lookup 页签，
    否则页内弹窗；跟进键随之走 `CompanionContextRegistry.lookupController` 或页内弹窗钩子）。
  - **R1 驱动面板**（仅伴屏在时）：按住 R1，方向键 / 左摇杆 / A / B 驱动副屏焦点（`panelNav`），其余键吞掉。
  - 有 target 时的 L1、伴屏在时的 R1 单击在**松开时**补发。
- 页面实现：`reader_fushi/controller_lookup.part.dart`、`video_fushi/controller_lookup.part.dart`、
  `manga_fushi/controller_lookup.part.dart`、`music/music_lyrics_controller_lookup.part.dart`，公共步进
  `media/shared/controller_lookup_steps.dart`。绑定盘点见 [shortcuts-inventory.md](shortcuts-inventory.md)。
- 原生：手柄键（含 `KEYCODE_BACK`）在面板上一律转发给 MainActivity，**手柄永远驱动主屏**（规则
  `SecondScreenLifecycle.keyGoesToTop`，JVM 测试覆盖）；非手柄 Back 在伴屏模式变成 `popRoute()`。
- 方向键是不是手柄：一律用 `shortcuts/key_event_device_type.dart` 的 `keyEventDeviceType(event)`，**不要读
  `KeyEvent.deviceType`**——Flutter 3.47 的 dart:ui `_unpackKeyData` 丢掉了引擎写进 key data 的设备类型，Android 上
  它恒为 keyboard（`ControllerKeySource` 收窄 source 也救不回来）；兼容层从同一次按键的 raw 消息取 source，清理条件
  见文件头与 `test/shortcuts/key_event_device_type_test.dart` 的探测用例。
- 帽子键方向键（`ABS_HAT0X/Y`，Thor 自带手柄）是摇杆 MotionEvent，只有窗口**没消费**的摇杆事件才会被 ViewRootImpl
  合成方向键：面板转发摇杆事件后返回 false，让面板窗口自己合成方向键再按键转发；面板窗口拿到焦点即给 FlutterView
  焦点，否则触摸后的第一个方向键会被「离开触摸模式」吞掉。改按键前先读
  [focus-ownership.md](focus-ownership.md)。

## 9. 怎么测

- Dart：`test/second_screen/`（宿主、策略、协议、bridge、上下文、各模块 hook / 面板、书库、设置、手柄模式）+ 相关守卫
  （`test/build/game_stream_device_regressions_guard_test.dart`、`test/sync/game_stream_companion_bridge_test.dart`、
  设置 coverage / IA / search、i18n）。在 `fushi/` 下 `dart tool/heavy.dart -- flutter test test/second_screen/ --no-pub`。
- 原生状态机：`fushi/android/` 下
  `dart ../tool/heavy.dart --check-only -- .\gradlew.bat :app:testDebugUnitTest --tests app.fushi.reader.SecondScreenLifecycleTest`。
- 真机：Thor 底屏或任意外接显示器；检查清单在各步骤的进度记录里（阅读器三种 view mode 的查词路由、屏幕拔插回落、
  串流副屏行为、手柄 L1 / R1、Lookup 页签制卡）。

## 10. 已知限制

- 触摸能否用无法检测，所以每个面板都必须能用手柄（按住 R1）驱动。
- 伴屏查词时主屏不画词高亮；L1 / R1 单击在松开时才触发（翻页会感觉略迟）。
- 标记已读只支持书、漫画、有声书、视频、视频合集；书 TOC / 在线漫画章节条目只打开到已存位置；音乐 Main 模式的搜索 /
  排序 / 筛选与游戏书库未接线。
- 「回到 <上一个>」只存在面板内存里（面板重启即丢），固定 5 分钟。面板重启恢复页签 / 模式 / 分区 / 搜索 / Settings 分类页，
  不恢复滚动位置、Library 详情页与 Now / Lookup 的子页。
- 面板转发来的手柄 `KEYCODE_BACK` 在主屏到达时是 `goBack`，不是查词模式的 B。
- 新文案（`second_screen_*`）除 en / zh 外均为英文。
