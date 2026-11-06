## BUG-3847 · SRS 评分后下一张卡掉帧：评分叫醒被盖住的牌组列表 + 卡面无关重建
- **报告**：2026-10-27（用户：所有者口头报告「SRS 完成卡片评分后，下一张卡片显示帧率低」，无反馈 id）
- **真实性**：✅ 真 bug。Windows 离屏 runner 实测（`fushi/integration_test/srs_rate_next_frame_itest.dart`，debug 构建，牌组列表页之上开复习页，键盘 Space 翻面 / 3 评分，每种卡 10 次，量评分起 1.5 s 内每帧 FrameTiming + 每帧重建的 element 数 + 各阶段时刻）。两条根因：
  1. **评分叫醒被复习页盖住的列表**：`fushi/lib/src/pages/implementations/srs/srs_review_page.dart:491`（修前）`_guarded` 每次写完都 `bumpSrsRevision` → `srsDeckListProvider`（`fushi/lib/src/srs/srs_providers.dart:535`）整库重算 `deckSummaries()`（牌组树 + 日界 + 30 天日志 + 今日活动 + 计数），冲突 / 迁移角标 provider 也重跑；被盖住的 `SrsDeckListPage` 在评分后 100–350 ms 内整页重建 2–3 次（每次约 2300 个 element），正撞在下一张卡上屏、底栏切换与 Fushi 卡片错峰进场动画那几帧。入口（牌组列表 `srs_deck_list_page.dart:158 _push`、首页复习条 `home_dashboard_page.dart:1924`、导航速览 `home_nav_peek.dart:452`）本来就在复习页返回时各发一次 `bumpSrsRevision`，评分时发是纯浪费。
  2. **复习页与卡面无关的 setState 每次都重建整棵卡面**：`srs_review_page.dart:1514-1612`（修前）`_buildCard` 每次 build 都新建 `SrsCardFace` / `SrsFushiCardView`，忙碌态开、换卡 + 忙碌态关、计数与间隔预览补齐（`_completeShown`）各一次 → 换一张卡卡面整棵重建 3–4 遍（含释义 WebView 宿主）。
  - 已排除：UI isolate 上的预取计算不是热点——`renderCard`（模板渲染）≈ 1 ms、`srsWarmCardFace` ≈ 0.3–0.5 ms（`prefetch:detail→render→warm` 时刻差，debug JIT）；`nextCard` / `cardDetail` / `preview` / `deckSummary` 的耗时在后台 isolate 的库与 `Isolate.run` 的 sync2 里，只占等待不占帧。Windows 上卡面 WebView 全程同一个 controller、没有重建（另一子任务修的「卡面根 widget 类型变化 → 平台视图重建」是 macOS 路径，不在本次 Windows 测量里）。
- **[x] ① 已修复** — `srs_review_page.dart` `_guarded` 改发新的 `bumpSrsLocalWrite`（`srs_providers.dart` `srsLocalWriteProvider`：只有互联快速通道订阅，`srs_app_runtime.dart` 同样去抖推送），不再发列表刷新信号；`_cardFace` 按输入（卡 id / 渲染结果 / 正反面 / 缩放 / 图片尺寸 CSS / 自动播放 / MediaQuery / 卡面构造器）缓存卡面 widget 实例，输入不变时返回同一实例，框架跳过整棵卡面重建。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_review_rate_rebuild_test.dart`：真实内存库 + 假排程内核，键盘翻面 / 评分，断言换一张卡卡面只 build 一次（下一张的问题面）、评分不递增 `srsRevisionProvider`、递增 `srsLocalWriteProvider`。变异验证：在 `_guarded` 加回 `bumpSrsRevision` → 红（revision 0→1）；关掉卡面缓存命中 → 红（卡面 build 多次）。
- **备注**：
  - 实测对比（Windows debug，同一台机器，数字是 10 次评分的均值；#0 冷启动、并发 agent 抢 CPU 的离群次已在括号里注明）：
    - Fushi 卡片（原生 + 释义 WebView）：每次评分 1.5 s 内重建 element **9298 → 2045**；单帧最大 UI 耗时 **61.6 → 26.8 ms**（第 4–9 次稳态 48.9 → 21.8 ms）；最大帧间隔 **79.3 → 44.0 ms**；>16.7 ms 的帧 **7.4 → 6.4**。
    - Lapis（整面 WebView，带图片 + 两段音频）：单帧最大 UI 耗时第 4–9 次稳态 **41.0 → 23.1 ms**；卡面 WebView 新内容首帧（页内 MutationObserver 双 rAF）稳态 **103.7 → 89.5 ms**。修后第 2/3 次出现 answer 280 ms 的离群（同机其它 agent 正跑重活，`answer:begin→done` 本身被拖慢），不计入稳态。
    - debug JIT 绝对值偏大，release 约小一个量级；比例可信。
  - 剩余：复习页自身的整页 setState（忙碌态开 / 计数补齐）每次仍重建约 630–780 个 element（顶栏 `FushiFloatingTopBar` 与底栏），未拆；需要时可把计数 / 忙碌态改成局部 Listenable。
  - 未验证：macOS / Android / iOS 未实测；release / profile 构建未实测；探针 itest 在最后一次评分之后偶发不退出（数据已在此前写进探针文件，原因未查）。
