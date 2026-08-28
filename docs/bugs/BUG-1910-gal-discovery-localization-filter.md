## BUG-1910 · gal 下载缺少生肉/熟肉筛选：分类只以一句硬编码中文存在
- **报告**：2026-08-28（用户：「gal下载缺少筛选生肉熟肉等标签」）
- **真实性**：✅ 功能缺失，且底层数据形态本身就不支持筛选。

### 现状

galgame 没有独立下载页，走统一发现页（`media_discovery_page.dart`，书/游戏共用）。
那页的控件只有「来源下拉 + 搜索框 + `leading` 插槽」，而 `leading` 在游戏域恒为 null
（它只在多媒体域时放类型分段按钮）——**一个筛选控件都没有**。

更根本的是数据形态：汉化状态只以 `DiscoveryResourceItem.note` 里**一句硬编码中文**存在
（`shinnkuGameTypeNote` 直接 `return '生肉'`），字段注释自陈「原样展示，**不参与任何
逻辑**」。于是：

- 没法筛（按显示名字符串筛正是本仓刚修过的反模式，见 [BUG-1906] 的导出范围）；
- 英文/日文用户看到的是两个看不懂的方块。

三个游戏源里也只有 shinnku 产出这个信息；sukebei 的 `note` 被 `trusted` 占用，
AList 连 `note` 都不产出。

### 修复与测试

- **[x] ① 已实现**：
  - `DiscoveryResourceItem` 新增**带类型**的 `gameLocalization`
    （`enum DiscoveryGameLocalization { raw, translated, mobile }`）。
    规则只有一处实现 `shinnkuGameLocalization(filePath)`；中文字面量的
    `shinnkuGameTypeNote` 由它派生——两种表示不会分叉。
    游戏条目的 `note` 不再塞那句中文，UI 按枚举出 **i18n** 标签。
  - 发现页加一排 `ChoiceChip`：全部 / 生肉 / 熟肉 / 手机 / **未标注**。
    **「未标注」是必须有的一档**：sukebei / AList 的条目 `gameLocalization` 恒为 null
    （那两个源不给这个信息，**不是**「未汉化」）。没有这一档，用户在聚合搜索里一按
    筛选就把那两个源整个滤没了，还会以为它们挂了。
  - **纯客户端过滤，不重发请求** —— 分类是条目自带的可判定属性，源在解析时就算好了；
    与番剧下载对话框的排序切换同一条纪律。
  - chip 行只在**游戏域且当前结果里确实有带分类的条目**时出现，不给视频/书域凭空多一排。
  - 目录条目（`DiscoveryFolder`）无条件保留——它们是导航结构，筛掉用户就下不去了。
- **[x] ② 已加自动化测试** — `fushi/test/media/discovery/game_localization_filter_test.dart`：
  路径前缀规则、中文标注**由枚举派生**（两种表示永远说同一句话）、源确实产出类型字段、
  不给分类的源保持 null、以及接线守卫（必须有「未标注」档 / 目录条目无条件保留 /
  换筛选不得重新发起请求）。
  同时更新既有 `shinnku_discovery_source_test.dart` 的三处断言：从 `note` 的中文字面量
  改到类型字段（`shinnkuGameTypeNote` 本身仍有独立断言覆盖）。

### 备注

- **本轮把一条既有守卫的过宽代理收紧了**（顺带记一笔）：
  `popup_asset_behavior_test.js` 的 TODO-448 用例原先断言「pending 定时器数 == 0」来
  代理「没有延迟刷新」。那个代理太宽——[BUG-1908] 给制卡失败加的就地提示自带一个
  1.8s 自渐隐定时器，与它要防的「延迟 duplicateCheck 把按钮翻成 ✓」毫无关系。
  已换成**更强**的直接断言：把所有挂起定时器全跑一遍，再断言没人偷偷刷新/翻转
  （数定时器只能证明「没人排队」，跑完定时器能证明「排了队也不会翻」）。
- 另有两条既有守卫因实现搬家而更新：`display_title_facade_guard_test`
  （[BUG-1906] 删掉了按显示名建书目的死 helper）、`anki_deck_refresh_label_todo400_test`
  （[BUG-1902] 把牌组选择行搬进共享组件，守卫跟着实现走，并补断言「设置页仍挂着它」）。
- **galgame 平台边界**：本改动全在 Dart 发现/下载 UI，未触碰 `native/galgame_hook/`、
  未改 IPC 契约、未改 `engine-support.yaml`。
- 未做真机复测（需要真实 shinnku 搜索结果）。规则与接线由单测覆盖。
