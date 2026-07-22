# 2026-07-22 五大模块 UI/UX 巡检（阶段一：巡检报告）

> 任务：系统性检查书籍/视频/游戏/下载/设置五模块的显示效果与使用体验，只做视觉与交互层评审，不改业务逻辑。本轮为阶段一（巡检 + 取证 + 优先级建议），等确认范围后进入阶段二分模块重构。

## Scope

- 基线：`origin/develop @ c132b2f21`（worktree `.claude/worktrees/ui-ux-survey-20260722`，分支 `worktree-ui-ux-survey-20260722`）。主 checkout 落后 838 提交，本轮一切结论以 origin/develop 为准。
- 方法：5 路并行代码巡检（每模块通读入口文件 + 引用的共享组件，所有 file:line 子代理亲读核实，主代理另抽查 5 条高严重度 finding 全部吻合）+ 双平台双主题截图取证（Android 模拟器 emulator-5554 / Windows 离屏 runner，深色/浅色各一套）+ 疑似功能 bug 按 docs/BUGS.md 建档。
- 覆盖文件：任务指定的 5 组入口文件及其引用的共享组件（`hibiki_material_components.dart`、`hibiki_icon_button.dart`、`hibiki_dropdown.dart`、`settings_shared.dart`、`theme_notifier.dart` eink 段、焦点系统 `hibiki_focus_controller.dart` 等）。
- 注：任务清单中 `switch_settings_page.dart` 已不存在（settings schema 化重构吸收进 `hibiki/lib/src/settings/`）；`download_tasks_list.dart` 存在但为全仓无引用的死代码。
- 巡检子代理完整原始输出（含全部 P2 细节）：`.codex-test/ui-survey/review-{books,video,games,downloads,settings}.md`（worktree 内，gitignored）。

## 证据（重构前基线截图）

| 平台 | 路径 | 内容 |
|---|---|---|
| Windows 离屏（第 1 轮） | `.codex-test/ui-survey/windows/survey-{dark,light}-{home,books,video,downloads,games,settings}.png`（主 checkout `.codex-test/`） | 12 张，深浅色 × 6 面；中央被「发现新版本」更新弹窗遮挡（runner 继承代理 env 后更新检查成功弹窗），本身也是一条 finding |
| Windows 离屏（第 2 轮，干净版） | 见文末「证据补记」 | 同 12 张，无弹窗遮挡 |
| Android 模拟器 | 见文末「证据补记」 | 深浅色 × 5 面（games tab 仅 Windows） |

截图测试：`hibiki/integration_test/ui_survey_capture_test.dart`（本轮新增，双路落盘：Android `binding.takeScreenshot` → 宿主 `hibiki/screenshots/`；Windows RenderView.toImage → runner 证据目录；播种书/有声书/视频 fixture，不打开阅读器/播放器）。

## 跨模块共性问题（建议独立先行处理）

这些问题在 ≥2 个模块中反复出现，根子都在共享组件层——先修共享层能消灭大量模块内特殊情况，是「好品味」的改法：

### C1. eink（墨水屏）模式是「主题层做了、组件层没接」 【P1，影响全 app】
- `HibikiCard` 不读 `HibikiEinkTheme`，无 borderColor 时 `BorderSide.none`（`hibiki/lib/src/utils/components/hibiki_material_components.dart:76-83`）；而 eink 把所有 surface container 塌缩为背景色（`theme_notifier.dart:157-166`），eink 的 1px 描边补偿只加在裸 `Card` 的 `CardThemeData`（`theme_notifier.dart:1066-1074`）→ 书架占位卡、统计卡、游戏诊断卡、KPI 条在墨水屏上与背景完全融合。全仓只有 `dictionary_popup_layer.dart` 和 popup 注入读 eink 扩展。
- 大量 alpha 叠层在 eink 下渲染成抖动灰：书架勾选圈底 0.7 / 选中罩 0.12（`card_widgets.part.dart:235,261`）、拖放高亮 0.18（`collection_shelf_row.dart:338`）、远端云角标 0.55 黑（`remote.part.dart:800-806`）、下载 chip 无边框底色（`anime_download_dialog.dart:565-581`）。
- 动画不归零：设置折叠/搜索定位闪烁（`settings_shared.dart:319-339`、`settings_search.dart:161-175`）、下载任务不定进度 spinner（`anime_download_dialog.dart:1152`）、视频 chrome 全部 Animated*（video_hibiki* 零处读 eink）。
- **建议**：共享层三板斧——① HibikiCard 在 eink 下默认 outline 描边；② `einkSafeOverlay()` helper 统一把 alpha 叠层换实心+描边；③ 各页 Animated 组件读 eink 时 duration 归零。PR#316（eink 全局开关）验收前建议先落这个，否则四渲染面验收会大面积撞上。

### C2. 焦点/手柄可达性覆盖不均 【P1】
- 游戏模块大面积缺口：游戏卡裸 `Card+InkWell` 不注册 `HibikiFocusTarget`（`games_library_page.dart:254-256`）→ 手柄能进 tab 但选不中任何卡；texthooker 点词 span 裸 GestureDetector（`texthooker_page.dart:1518-1528`）；线程选择器全仓唯一裸 `DropdownButton`（`:820-821`，绕过 gamepad-enterable 的 `HibikiDropdown`）；诊断页多枚裸 IconButton/无 focusId chip。
- 书籍：视频合集详情页剧集行裸 InkWell 不可达（`media_collection_detail_page.dart:440-441`）。
- 下载：失败原因只在 hover Tooltip（Icon 不可聚焦，键盘/手柄读不到，`anime_download_dialog.dart:1143-1146`）。
- 设置：开关行 Tab 有 2-3 个焦点站点（滑条行已用 ExcludeFocus 收成单站点，开关行没有，`settings_shared.dart:503-521` + `adaptive_widgets.dart:92-96`）。
- 视频（正面对照）：库页卡片全走 HibikiFocusId，播放器手柄全屏路由也包裹了——说明范式成熟，缺的只是把游戏/下载/合集详情接上。

### C3. 空态/错误态缺共享组件，质量参差 【P1~P2】
- 错误态最重：书架错误直接显示原始异常串且丢弃重试回调（`base_page.dart:68-79`，影响所有 BasePageState 页面）。
- 空弹窗两处：远端书/远端视频「信息」弹窗无内容时只有标题+关闭（`remote.part.dart:190-210`、`home_video_page.dart:2657-2665`）。
- 空态骨架「图标+一句话」全 app 至少三份复制，且质量不一：书架空态有导入引导、视频/合集详情没有 CTA、下载搜番初始态只有孤图标、游戏空态反而双 CTA 重复（空态按钮 + FAB 同屏，Windows 截图可见）。
- **建议**：抽 `HibikiEmptyState(icon, message, {action})` + 修 `buildError`，各模块换用。

### C4. 卡片规格漂移 【P1~P2】
书架已花大力气统一（`unifiedShelfCardLayout` + `kShelfBookCardAspectRatio` + 40px 标题 footer），但：游戏卡硬编码 180/0.72 自成一派（`games_library_page.dart:219-224`）；合集网格详情页 `maxCardWidth=180` + 字面量 `160/260`（`media_collection_grid_detail_page.dart:460-474`）与书架断点（150-210）口径不同——同一本书两处尺寸不同。**建议**：卡片布局参数只留一个真相源，游戏卡/详情页复用书架壳或至少同一批常量。

### C5. i18n 漏网点位 【P1~P2】
- 枚举 `.name` 直接上屏（游戏模块 6 处：`waitingSignals`/`degraded` 等 camelCase 英文暴露给 17 语言用户）。
- 硬编码英文：`'Trusted'`、`'EP '`（下载）、`'clips'`/`'energy'`（游戏诊断）。
- 日期格式手写不随 locale：`MM/dd HH:mm`（收藏页）、`M-dd`（视频概览）。
- 对话框按钮混用 `MaterialLocalizations`（Anki picker「删除」实为「清空映射」、图标确认框）与 app 自有 t.*。
- 更新弹窗正文直接显示英文 release note 原文（Windows 截图第 1 轮可见：`Manual Apple formal release from v1.2.0-beta.8024 @ 8082046.`）。

## 模块一：书籍（书架/阅读历史/合集）

总评：主链路纪律良好（tokens/i18n/焦点），问题集中在 eink 断层（见 C1）、合集详情两页复制漂移、错误态/空态文案缺陷。

| # | 严重度 | 问题 | 位置 |
|---|---|---|---|
| B1 | P1 | 错误态直出原始异常串 + 重试回调被丢弃 | `base_page.dart:68-79` |
| B2 | P1 | 标签筛选矛盾空态 + 丢下拉刷新（**BUG-1008**） | `reader_hibiki_history_page.dart:1219-1261` |
| B3 | P1 | eink 下卡片消失（见 C1） | `hibiki_material_components.dart:76-83` |
| B4 | P1 | 批量操作栏窄屏+大字体必溢出 | `books.part.dart:380-427` |
| B5 | P1 | 视频合集详情剧集行手柄不可达（见 C2） | `media_collection_detail_page.dart:440-441` |
| B6 | P2 | 书卡标签恒只显 1 个且无 +N 提示（槽位算法死路径） | `card_widgets.part.dart:449-458,13-22,110-115` |
| B7 | P2 | 同一书卡书架/详情页尺寸口径不同（见 C4） | `media_collection_grid_detail_page.dart:460-468` |
| B8 | P2 | 合集详情 IgnorePointer 灭掉桌面 hover | `media_collection_grid_detail_page.dart:487-488` |
| B9 | P2 | 收藏页：日期不随 locale / 加载只有裸转圈 / 播放中全列表变静态沙漏 / 导出走 bottom sheet 范式分裂 / iOS 分享图标 | `collections_page.dart:172,1008,1173-1177,634-706,996` |
| B10 | P2 | 远端卡：信息弹窗空、SRT 长按直接下载无确认、批量栏唯一 elevation 6 阴影 | `remote.part.dart:190-210,632-634`；`books.part.dart:370-372` |
| B11 | P1 | **（截图新发现）** Android 深色下无封面书卡的占位底与背景几乎零对比——书架上只见角落类型图标和悬空书名，卡片轮廓消失（Windows 深色勉强可辨，Android 完全不可辨；C1 的普通深色版） | 证据 `.codex-test/ui-survey/android/survey-dark-books.png`；占位实现 `card_widgets.part.dart:415-421` |

结构性问题（阶段二重点）：
- **两个合集详情页是同一页面两份手抄**（`media_collection_detail_page.dart` vs `media_collection_grid_detail_page.dart`：改名/标签/排序/删除四组逻辑逐行相同但控件混搭）→ 抽 `CollectionDetailScaffold`。
- 卡片 footer / 选中勾选圈在 `series_shelf_card.dart` 与 `card_widgets.part.dart` 逐行重复 → 抽 `ShelfCardFooter` / `ShelfSelectionCheck`。
- 删除确认弹窗四种实现并存 → 收口 `HibikiDestructiveConfirmDialog`。
- 标签 chip Wrap 三份复制；`SeriesShelfCard` 疑似残留活代码（无长按/右键，确认无调用方可删）。

## 模块二：视频

总评：工程质量最高的模块（i18n 满分、四态齐全、几何走 token+缩放），主要问题是播放器 chrome 前景色错误地跟随主题（浅色下压深色 scrim 对比度崩），以及库页角标/焦点细节。

| # | 严重度 | 问题 | 位置 |
|---|---|---|---|
| V1 | P1 | 播放器控制条/顶栏/时间前景随主题 colorScheme，浅色+eink 下压固定深色 scrim 对比度崩（正确范式 `_osdSurfaceColor` 同页已有） | `controls_theme.part.dart:80-82,221-225`；`video_hibiki_page.dart:793-794,4759-4772`；`layout.part.dart:650-657` |
| V2 | P1 | 多选勾选框与标签 chip 同角(6,6)重叠 | `home_video_page.dart:2903-2922` |
| V3 | P1 | 桌面无鼠标可达的「刷新远端视频」入口（唯一入口是下拉刷新） | `home_video_page.dart:1756-1762,2566-2610` |
| V4 | P2 | OSD 固定 top:52 / 连播卡固定 bottom:88，不随 `_videoUiScale`，大缩放时叠顶栏/挡进度条 | `volume_osd.part.dart:333`；`episode.part.dart:280-281` |
| V5 | P2 | 横滑 seek HUD 硬编码黑/白/22px 脱离 OSD token 体系 | `controls_theme.part.dart:283-311` |
| V6 | P2 | 画质面板空态文案=标题本身；弹幕手动匹配失败零反馈 | `quality.part.dart:276-297`；`danmaku.part.dart:195-197` |
| V7 | P2 | 库页空态无 CTA；远端卡封面内嵌下载钮嵌套焦点+热区<48dp；竖版封面露底无衬底；日期 M-dd 不随 locale；浮层 alpha 四档各自为政 | `home_video_page.dart:2728-2746,2445-2453,3185-3193,2112-2117`；4 文件 alpha |
| V8 | P2 | eink 对播放器 chrome 动画零适配（见 C1） | video_hibiki* 全部 |

结构性问题：半透明黑胶囊角标三连复制 → 抽 `CoverBadge`；继续观看 hero 本地/远端双胞胎合并；画质 tile 双胞胎合并；空态骨架并入 C3 的 `HibikiEmptyState`；push-aside 侧栏六层包装重复。

疑似 bug：**BUG-1010**（控制条自动隐藏 unmount 丢键盘焦点，待 Windows 真机复现）。

## 模块三：游戏

总评：共享组件接入是五模块中最差的——焦点体系大面积缺口（手柄用户核心操作基本不可用）+ 枚举 `.name` 直接上屏。空态/加载反馈本身覆盖尚可。

| # | 严重度 | 问题 | 位置 |
|---|---|---|---|
| G1 | P1 | 游戏卡裸 Card+InkWell，手柄/方向键无法启动游戏（见 C2） | `games_library_page.dart:254-256` |
| G2 | P1 | 点词 span 无焦点/无手型/无 hover；键盘手柄无法查词 | `texthooker_page.dart:1518-1528` |
| G3 | P1 | 线程选择器全仓唯一裸 DropdownButton | `texthooker_page.dart:820-821` |
| G4 | P1 | 枚举 .name 上屏 6 处（waitingSignals 等，见 C5） | `home_game_page.dart:338`；`game_diagnostics_page.dart:218,277`；`texthooker_page.dart:1081-1236` |
| G5 | P1 | eink 下 HibikiCard 无边界 + 严重度圆点色彩塌缩（见 C1） | `hibiki_material_components.dart:76-83`；`game_diagnostics_page.dart:437-442` |
| G6 | P1 | 网格硬编码 180/0.72 与书架规格漂移（见 C4）；首页概览带固定 height:400/width:360，矮窗挤压、大字体溢出（Windows 截图可见卡片底部裁切） | `games_library_page.dart:219-224`；`home_game_page.dart:176-199` |
| G7 | P2 | 裸 IconButton/Switch/无 focusId chip 散布；'clips'/'energy' 硬编码英文；全角冒号混用；未读胶囊缺 onTertiaryContainer 且不可点；溢出菜单 Colors.black54 阴影；audio_format 标签显示时长；窄屏丢弃两块面板；重命名框无 label | 详见 `.codex-test/ui-survey/review-games.md` |
| G8 | P2 | **（截图新发现）** 空库时「添加游戏」双 CTA 同屏：空态引导按钮与右下 FAB 并存重复 | 证据 `.codex-test/ui-survey/windows/survey-dark-games.png` |

结构性问题：`_audioBackendLabel` 三份拷贝、section tab chip 行三份拷贝（focusId 前缀已三套）→ 抽 `GameSectionTabs`；`_HealthRow`/`_DiagnosticRow` 同构合并；`_formatTime` 两份；游戏卡改用书架卡片壳；首页 KPI 汇总应由 controller 暴露统一 getter（现用字符串比较 `phase.name == 'connected'`，`home_game_page.dart:311-313`）。

疑似 bug：**BUG-1007**（健康卡 Anki 行恒显未配置，已验真）；另有游戏列表不感知外部变更（`games_library_page.dart:46` 只读一次 + IndexedStack 保活）、对话框 controller 过早 dispose（`:117-119`）——列为模块 PR 顺带修复项。

## 模块四：下载

总评：MD3/Slang 纪律好，但作为下载管理器核心的任务行信息量严重不足（有进度数据却只给永转 spinner），失败不可恢复、错误提示不可操作；一个整文件死代码。

| # | 严重度 | 问题 | 位置 |
|---|---|---|---|
| D1 | P1 | 任务行无进度%/速度/ETA，只有不定进度 spinner（后端 `TorrentSnapshot.progress` 明明有值） | `anime_download_dialog.dart:1147-1154`；`torrent_backend.dart:24-25` |
| D2 | P1 | 失败无重试入口；失败原因只在 hover Tooltip（触屏/键盘/手柄读不到） | `anime_download_dialog.dart:1143-1146,1181-1185` |
| D3 | P1 | 「后端未配置」banner 无按钮，且「右上角设置」指引在视频页入口下是错的（Android 新用户高概率死路，Windows 截图确认） | `anime_download_dialog.dart:510-533`；`home_video_page.dart:740` |
| D4 | P2 | 设置面板桌面全宽铺开（对照全 app 设置 560 限宽）；齿轮变 ✕ 后 tooltip 语义相反；qb 无「测试连接」（probeConnection 已有）；搜番初始空态孤图标（截图确认对比度极低）；分类清空静默回落所见非所得；'Trusted'/'EP' 硬编码；chip eink 消失 + fontSize 11 | `downloads_page.dart:42-45,33-36`；`torrent_settings_section.dart:145-175`；`anime_download_dialog.dart:742-750,897,757,565-581` |

结构性问题：`download_tasks_list.dart` 整文件死代码（「单一真相源」注释为假）——要么真复用要么删；任务行实现两份漂移且上屏版没用 `HibikiListItem`；`_nonNegInt/_nonNegDouble` 两处复制；i18n key 残留 `video_setting_torrent_*` 前缀（rename 成本大，暂缓）。

疑似 bug：**BUG-1006**（embedded 推送成功 pop 掉宿主路由，已验真，Android 下载 tab 上等于退出/黑屏）。

## 模块五：设置

总评：schema 化重构质量很高（单一真相源+双渲染器+焦点驱动成熟），本轮问题多为重构收尾遗留。

| # | 严重度 | 问题 | 位置 |
|---|---|---|---|
| S1 | P1 | 宽屏默认选中「外观」，与重排后首项「阅读」脱节（c132b2f21 重排的直接遗漏；截图 `windows-clean/survey-light-settings.png` 可见选中 pill 落在左栏第 7 项） | `settings_home_page.dart:32-35` |
| S2 | P1 | 值控件行 icon 声明了但从不渲染（showIcon 不转发），同卡片左栏参差；搜索结果有图标落地行没有 | `settings_shared.dart:663-675,533,407`；`settings_schema_widgets.dart:161-173` |
| S3 | P1 | 「制卡」整个分类对设置搜索不可见（body 逃生口不入索引，搜「牌组」「允许重复」零结果） | `settings_schema_card_creation.dart:15-16`；`settings_search.dart:55-75` |
| S4 | P2 | eink 下折叠/搜索定位动画不归零（见 C1）；开关行 Tab 2-3 站点（见 C2）；「界面大小」滑条静止无读数（readout 机制已有，25 个滑条只 6 个开）；MaterialLocalizations 混用+「删除」实为「清空」；图标页三重标题+提示伪装设置行；快捷键页硬编码 padding；RTL/LTR 缩写不本地化（现成 key 不用）；宽屏详情 pane 无 max-width（产品取舍，需确认） | 详见 `.codex-test/ui-survey/review-settings.md` |

结构性问题：AnkiSettingsBody 整页 bespoke 是搜索盲区+重复实现共同根源（`_AnkiConnectionField` 无防抖每击键写穿 vs schema 侧 `SettingsSecretField` 全套）→ 逐步 schema 化；commit-on-release 滑条双实现（界面大小行改 `SettingsSliderItem(commitOnRelease:true)` 一石三鸟）；快捷键页借用 system destination id 违反自立约定；对话框按钮文案两套来源。

顺带修复项：Lapis 行 spinner 复用 isFetching（`anki_settings_page.dart:318-325`）、handlebar 弹窗选中勾对照旧快照（`:687`）、`hibiki/CLAUDE.md` 仍列已删除的 `switch_settings_page.dart`/`display_settings_page.dart`（文档陈旧）。

## 疑似功能 bug 建档汇总

| BUG | 状态 | 摘要 |
|---|---|---|
| BUG-1006 | ✅ 已验真 | 下载页内嵌推送成功后误 pop 宿主路由 |
| BUG-1007 | ✅ 已验真 | 游戏工作台健康卡 Anki 行恒显未配置 |
| BUG-1008 | ✅ 已验真 | 标签筛选下 SRT 命中仍显无匹配空态且丢下拉刷新 |
| BUG-1009 | ⏳ 待复现 | 合集详情返回后书架同名卡手柄焦点不可达 |
| BUG-1010 | ⏳ 待复现 | 视频控制条自动隐藏后键盘焦点疑似丢失 |

## 阶段二重构优先级建议（等确认）

按「一个模块一个 worktree 一个 PR」拆 6 个 PR，建议顺序：

1. **PR-0 共享组件先行**（强烈建议第一个做）：C1 eink 三板斧（HibikiCard 描边 / einkSafeOverlay / 动画归零钩子）+ `HibikiEmptyState` + `CoverBadge` + `HibikiDestructiveConfirmDialog` + `buildError` 修复 + 设置开关行焦点单站点。理由：五个模块 PR 都要用，先落地才能消灭模块内特殊情况；且 PR#316 eink 验收依赖它。
2. **PR-1 游戏**（问题密度最高、影响手柄用户核心路径）：焦点接线全套（G1-G3、裸控件）、枚举 .name i18n 化、网格对齐书架壳、固定 400/360 自适应、BUG-1007、三份拷贝收敛。
3. **PR-2 下载**（用户价值最直接）：任务行进度/速度/重试/失败原因直显、banner 加按钮、BUG-1006、死代码删除、任务行换 HibikiListItem、设置面板限宽、测试连接按钮。
4. **PR-3 书籍**（改动面最大，注意 Never break userspace）：BUG-1008 消灭特殊分支、错误态、批量栏溢出、合集详情两页合一（CollectionDetailScaffold）+ 尺寸统一、footer/勾选圈抽件、收藏页系列打磨。
5. **PR-4 视频**（V1 需谨慎调色验证）：控制条前景固定亮色体系、V2 勾选框、V3 刷新按钮、OSD/连播卡几何联动、角标换 CoverBadge、hero 双胞胎合并。
6. **PR-5 设置**（收尾量少）：S1 默认分类、S2 icon 决策（建议：值行统一渲染图标，对齐左栏）、S3 搜索元数据、readout 盘点、MaterialLocalizations 收口、杂项。

每个 PR 验收：`dart format` + `flutter analyze` 零 warning + `flutter test --no-pub` + 用本轮同一截图测试复截对比（重构前后同名截图 diff）+ 涉焦点改动补焦点驱动集成测试。

## Next Scope

- 等用户确认阶段二范围与 PR 拆分顺序。
- BUG-1009 / BUG-1010 复现取证（1009 可写焦点驱动集成测试直接验证；1010 需 Windows -Visible 跑真播放器）。
- 未纳入本轮：词典 tab、首页 dashboard、阅读器页内 UI（`reader_hibiki_page.dart`）——如需可作为第二批巡检。

## 证据补记

三轮截图全部完成，归档到主 checkout `.codex-test/ui-survey/`（gitignored，不入库）：

- **Windows 第 1 轮（带更新弹窗）**：`.codex-test/ui-survey/windows/`（12 张，源 run `hibiki/.codex-test/windows-itest/win-itest-20260722-125515-6903b4b0`）。弹窗本身是 C5 证据（英文 release note 原文直出）。
- **Windows 第 2 轮（干净基线）**：`.codex-test/ui-survey/windows-clean/`（12 张，源 run `win-itest-20260722-131610-2a1f8a3a`，深浅色 × home/books/video/downloads/games/settings，RenderView 非空白校验全过）。
- **Android 模拟器（emulator-5554，x86_64 debug）**：`.codex-test/ui-survey/android/`（10 张，深浅色 × home/books/video/downloads/settings；games tab 仅 Windows）。fixture：合成 EPUB + 有声书；`seedVideo` 在模拟器上 `createFFmpegSession failed`，视频架为空态（顺带取到空态证据）。
- 截图测试三次迭代踩坑记录（供复用）：Android `takeScreenshot` 必须先 `binding.convertFlutterSurfaceToImage()`；Android cwd 只读不能落 `.codex-test/` 相对路径；runner 带代理 env 会让更新检查成功弹窗污染截图（测试内已加 Navigator.pop 守卫兜底）。
