## BUG-1902 · 新手引导配置 Anki 缺少创建 Lapis 卡组/刷新/选牌组
- **报告**：2026-08-28（用户：「新手引导配置 anki 的时候缺少了创建 lapis 卡组或者刷新卡组和选择牌组」）
- **真实性**：✅ 真 bug。

### 根因

新手引导的 Anki 步（`fushi/lib/src/pages/implementations/onboarding_wizard_page.dart`
的 `_buildAnkiStep`）对牌组/笔记类型只有三行 **纯只读 Row**（`_ankiConfigRow`，
未选时显示「—」），可点的只有「测试连接」「下载 Anki」「安装 AnkiConnect 插件」
「打开制卡设置」。

而这三样能力在设置页里是**私有实例方法**，跨文件不可见：
`anki_settings_page.dart` 的 `_buildCreateLapisTile` / `_buildDeckDropdown` /
`_buildNoteTypeDropdown`。业务层（`AnkiViewModel.createLapisSetup` /
`selectDeck` / `selectNoteType`）本来就是公开的——**只有「怎么画」这一层被锁在了
一个 State 里**，于是引导页只能显示摘要、把用户推去设置页再回来。

这件事在这一批报告里不是孤立的：[BUG-1900] 的触发条件（字段映射不属于当前笔记类型）
正是 `createLapisSetup` 一次性能消除的状态——它同时建笔记类型 + 牌组、自动选中、
并套上 `LapisPreset` 的字段映射。新手最该点的那一下，恰恰在引导里点不到。

### 修复与测试

- **[x] ① 已修复** — 新建 `fushi/lib/src/anki/anki_config_controls.dart`，把三样能力
  抽成公开共享组件 `AnkiDeckPickerRow` / `AnkiNoteTypePickerRow` /
  `AnkiCreateLapisRow`；**设置页与引导页共用同一份实现**（设置页原方法退化成薄封装，
  本页其余调用点不动）。
  引导页在拿到牌组后就地渲染「创建 Lapis 卡组 / 选牌组 / 选笔记类型」，没连上时仍保持
  只读摘要以先引导用户连接。「测试连接」按钮在已连上后改标签为「刷新牌组与笔记类型」
  ——它调的一直是同一个 `fetchConfiguration`，继续叫「测试连接」会让用户在 Anki 里
  新建牌组后找不到刷新入口。
  `AnkiCreateLapisRow` 带 `onBusyChanged` 回调：`createLapisSetup` 内部也会把
  `AnkiUiState.isFetching` 置真，设置页的「刷新牌组」行需要靠它把「获取中…」压住
  （这是原实现的既有约定，抽取时必须保住，否则是行为回归）。
- **[x] ② 已加自动化测试** — `fushi/test/anki/anki_config_controls_test.dart`：
  牌组/笔记类型行渲染与写回；创建 Lapis 真的调后端且在途状态按 `[true, false]` 回报；
  外部拉取在途时创建行禁用；外加**接线守卫**——两个页面都必须引用这三个共享组件，
  且 `createLapisSetup(` / `selectDeck(` / `selectNoteType(` 只能出现在共享组件里
  （防重复实现回潮，那正是本 bug 的形态）。

### 备注

- 未做真机复测（引导流程需要真实 Anki 环境）。
- 引导页仍**不提供**字段映射编辑：那是一张长表，属于设置页的职责；
  「创建 Lapis 卡组」已经把映射一次性配好，新手不需要在引导里逐字段调。
