## BUG-1956 · 下载中心四分区被移除且资源页发现入口失去模块复用
- **报告**：2026-08-28（用户：「订阅、下载任务、设置那些全不见了」；
  后续验收明确资源页保留一个类型下拉框，并在选择书架、漫画、游戏、视频后
  直接复用对应模块已有的发现页展示）
- **真实性**：✅ 真 bug。回归提交 `1f67feb1e` 在
  `fushi/lib/src/pages/implementations/downloads_page.dart:31-35`（该提交版本行号）
  把 `initialShowSettings` / `initialTabIndex` 改成不再消费的「历史兼容参数」；
  同文件 `:248-332` 改为书籍 / 漫画 / 游戏 / 视频分域切换，
  `:344-355` 又将原四页 `DefaultTabController + TabBarView` 整体替换为
  单一资源页。因此 Home 页仍然传入任务 / 订阅索引、番剧下载仍然传入
  `initialShowSettings: true`，但入口统统落回资源页；随后临时改成自建的单框全域结果面，
  又没有复用各模块已经存在的发现交互与生产服务。
- **[x] ① 已修复** — 恢复资源、任务、订阅、设置四个顶层页签及原面板，
  重新消费两个初始页参数；资源页只增加一个书架 / 漫画 / 游戏 / 视频类型下拉框，
  选择后分别嵌入 `MediaDiscoveryPage`、`MangaDiscoveryPage` 与
  `VideoDiscoveryPage`。视频页复用 Home 组合根持有的生产 controller/actions，
  各页首次访问后保持挂载，切换不丢查询、结果与滚动位置。同时保留 BUG-1905 的
  `ModalRoute.of(context)?.isFirst` 返回键判定。提交：见本轮 commit。
- **[x] ② 已加自动化测试** —
  `fushi/test/pages/downloads_center_contract_guard_test.dart` 静态钉死四页签、
  两个初始页参数、`ModalRoute.isFirst`、唯一类型下拉框、四类发现页复用与切换保活；
  `video_discovery_production_wiring_guard_test.dart` 继续约束视频发现生产接线；同时保留
  下载页页头、全宽面板、设置页签与订阅切页的既有回归断言。
- **备注**：用户明确要求本轮不运行任何测试；修复合并前仍需按仓库验证纪律补跑定向用例。
