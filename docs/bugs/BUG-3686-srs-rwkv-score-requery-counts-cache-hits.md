## BUG-3686 · RWKV 分数表「每 50 次」刷新数的是部分命中的查询，不是作答
- **报告**：2026-10-23（来源：审查记录 HBK-AUDIT-019，`2026-10-23-rwkv-score-refresh-review.md`）
- **现象**：RWKV-Instant 排队用常驻分数表缓存每张候选卡的回忆率 R。答完一张卡后，其余卡的 R 会因共享状态（牌组 / 预设 / 全局流、今日复习数）变化而改变，但它们继续沿用旧分数。旧分数要等「50 次增量或 30 分钟」才整表刷新，而这个计数在一些作答路径上永远到不了 50。
- **真实性**：✅ 真 bug（代码路径确认，测试复现）。根因：`packages/fushi_engine/lib/srs/srs_rwkv_service.dart` 的 `instantRetrievability` 只在一次查询「既有命中又有缺失」（`missing.length < cards.length`）时 `_patchesSinceRequery++`。下面两种情况都不计数，模型推进再多次，别的牌组的旧分数也不刷新：
  - 全部缺失（同笔记候选全被作废）；
  - 连续直接评分、中间不排队。
  阈值 50 和 30 分钟都写死，没有依据。
- **[x] ① 已修复** — `70c8ad022c`：
  - 计数改为模型状态真正推进的次数：`_appendNew` 里追加的评分与撤回各算一次，本机与同步来的都算。
  - 阈值改为构造参数 `requeryEveryAnswers`，缺省 `kSrsRwkvRequeryEveryAnswers = 1`：每次作答后，下一次排队前整表按最新状态重查（上游 JSchoreels/anki 未配置时同样回退到每题刷新）。
  - 时间条件保留为 `requeryAfter`，因为查询行里的间隔秒数随时间走；文件头写明它只在下一次排队时检查，不是定时器。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/srs/srs_rwkv_service_test.dart`「分数表整表重查按模型状态推进次数」组（缺省每题重查后别的卡的新 R 生效；N=3 时连续直接评分照样数满、撤回也算一次）。变异实测：去掉计数后两条变红。
- **备注**：未在真模型上测量每题整表重查的耗时，表大小 = 排过分的卡数，在后台 worker isolate 里跑，不阻塞 UI。设置页没有加「每 N 题刷新」选项；需要性能模式时再接 UI。
