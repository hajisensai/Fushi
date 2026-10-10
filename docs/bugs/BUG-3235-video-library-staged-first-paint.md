## BUG-3235 · 视频库首屏一块块加载
- **报告**：2026-10-10（用户：「主页里面的视频模块好像是分块加载的，点开以后别说动画了，里面的视频是一块块加载的」）
- **真实性**：✅ 真 bug。视频库页 `initState` 同时发出本地列表与分组映射（`_loadLibraryMaps`，十几张全表）两路加载，各自独立 setState，渲染没有「首屏数据齐了再画」的边界：列表先到时拿**空映射**渲染（`fushi/lib/src/pages/implementations/home_video_page.dart` `_buildVideoLibraryBody`：旧代码只判 `loaded == null`）——合集一个都折不出来，全员先铺成散卡、刮削海报全缺；映射一到再收拢成合集、换海报。BUG-2835 只给「全部视频 + 系列筛选」加了一道 `_seriesFilterPending` 特例门，系列页 / 首页照样分段重组。另外首屏进场动画窗口从挂载起计时 600 ms，映射晚于窗口到达时真卡直接蹦出、早于窗口时才错峰，进场与否取决于映射快慢。
- **[x] ① 已修复** — 根因修复（不是加淡入动画盖住）：
  - 首屏门推广到所有分区：列表**与**映射都到位才画真卡（`home_video_page.dart` `firstPaintPending`；`_libraryMapsReady` 只从 false 变 true，失败路径也置位，后续刷新用旧映射顶住），期间画与真实墙同几何的骨架（`_buildLibraryMapsPendingSlivers`，直接复用 `_buildVideoWallSliver` / `_buildAllVideoGridSliver`），映射一到整墙一次换成终态、版面不跳；BUG-2835 的 `_seriesFilterPending` 特例随之删除（被通用门覆盖）。原先列表未到时的整页居中加载圈也并进同一道门。
  - 进场动画按「骨架 / 真墙」分代重播（`FushiEntranceScope.replayKey: (section, firstPaintPending)`），真墙恒有一次完整进场。
  - 排查过但**未改**的两处：① 远端目录逐条 `adoptVideo` 收养后，页面主动重载一次映射、合集表变更防抖又补一轮——两轮读到同一份数据，第二轮画面不变，只是多算一次。试过「外层事务批量收养」（drift 嵌套事务在保存点释放时就通知根监听器，通知并不合并，反而在收养期间挡住库页读库、并把逐条容错改成整份回滚）和「防抖记代跳过」（变更事件经 `tableUpdates` 的 `Stream.multi` 与页面 controller 两跳异步转发，与写入方 await 后的主动重载谁先到不确定，判据只能偶尔省一轮），收益不确定、都已撤回。② 单张封面卡解码后的宽高比探测 / 主色采样仍会让该卡再变一次（`cover_aspect_probe.dart`），属单卡级别。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_video_first_paint_test.dart`：卡住映射加载（`getAllMediaCollections`），系列 / 全部视频 / 首页三个分区逐帧只画骨架、不出现任何散卡；放行后系列页合集一次折好、全部视频按默认「非系列」档位。变异实测：把门退回 `loaded == null` → 三个分区用例全红。
- **备注**：真机未复测（本轮无真机验证）。
