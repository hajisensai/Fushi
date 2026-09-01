## BUG-2005 · 首页「最近添加」行视频卡恒竖槽，横版截帧被模糊垫底成白条
- **报告**：2026-09-01（用户：截图标注「最近添加和继续一样改成自适应」——「继续」行的视频卡已按封面朝向横竖混排，「最近添加」行同一批视频却挤在窄竖槽里，截帧上下留白条）
- **真实性**：✅ 真 bug。`_buildRecentlyAddedSection` 调共享行组件时没传 `videoLandscape`，走默认 `false`（`fushi/lib/src/pages/implementations/home_dashboard_page.dart:1327`），于是 `_buildContinueCard` 的朝向探测分支整个被跳过（同文件 `:1446`），视频卡恒 94×132 竖槽；16:9 抽帧进竖槽后由 `PortraitCoverImage` 模糊垫底 + contain，看上去就是上下两条白边。「继续」行传的是 `true`，同一批条目在那行是正常横卡——两行口径不一致而已，不是取图或缓存问题。
- **[x] ① 已修复** — 根因修复：「最近添加」行改传 `videoLandscape: true`，与「继续」行共用同一条朝向探测路径（`CoverOrientationBuilder` 按解码宽高比分流：横图 → 132×16/9 横槽，竖版海报 → 94×132 竖槽；书/游戏恒竖版不变）。零新增分支、零新常量，只是把已有参数在第二个调用点也传上。提交：见本分支。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_page_test.dart`「「最近添加」与「继续」同口径：横版封面的视频卡走 16:9 横槽」：塞真实可解码的 16×9 PNG 当封面，按区块分别量卡宽，两行都必须 > 竖槽宽。变异实测：把 `videoLandscape` 改回 `false` → 最近添加行量到 94（要求 >141）即红。
- **备注**：测试踩坑记一笔——卡片是 `_loadDashboardData` 回填后才建的，封面解码这段真异步 I/O 必须和那次 pump 一起放进 **同一个 `runAsync`** 窗口；退出 `runAsync` 再 pump 的话 ImageStream 永不完成，探测停在「朝向未知 → 竖卡」，两行都恒量到 94，断言看着「通过不了」实际是测试装配没跑到被测分支。
