## BUG-1042 · 阅读时长被会话时钟重锚吃掉，速度/统计爆表（今日 0 分钟 / 125666 字·时⁻¹）
- **报告**：2026-07-24（用户截图「阅读统计」页）。今日 1832 字 / 时长 **0 分钟** / 速度 **125666 字·时⁻¹**；速度摘要「最快日 **421249 字·时⁻¹** · 07-22」。用户原话：「统计bug还在」（BUG-892 之后仍未好）。
- **真实性**：✅ 真 bug。生产库对账坐实，根因见下（旧 `reader_hibiki_page.dart` resumed 分支 / `navigation.part.dart` `_onRestoreComplete` + `_flushReadingStats`）。
- **[x] ① 已修复** — 见「修复」。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/reading_time_tracker_delta_test.dart`（行为层：onDelta 与小时桶同源、stop 收尾结算、停表期间零增量、无 onDelta 向后兼容）+ `hibiki/test/media/audiobook/reading_time_tracker_gap_test.dart` 新增 `BUG-1042` 组（源码守卫：墙钟基准字段已删、恢复完成不重锚、早退不清累计器、PDF 不再整段过守卫）。
- **备注**：真机复测（读一段带频繁查词的书 → 统计页速度回落到合理区间）待做。历史脏数据不会自动修正，见「未做」。

### 证据（生产库对账）
同一份 `hibiki.db` 里两条本应一致的时长账目差 4~600 倍——`reading_statistics`（每书/每日，喂
KPI「时长」与「速度」）远小于 `reading_hourly_logs`（小时桶，喂「Today by hour」）：

| dateKey | 字数 | reading_statistics | reading_hourly_logs |
|---|---|---|---|
| 2026-07-18 | 9454 | 84 分钟（6746 cph） | 345 分钟（1642 cph） |
| 2026-07-19 | 6538 | 30 分钟（13020 cph） | 175 分钟（2238 cph） |
| 2026-07-20 | 6333 | 19 分钟（19639 cph） | 39 分钟（9705 cph） |

单行更极端：`2026-07-12 / 安達としまむら / 486 字 / 3850 ms` = 454442 cph——486 个日文字符
不可能在 3.85 秒读完。**是时长这一侧被吃掉了**，字数侧正常。

### 根因
「每书/每日时长」与「小时桶」是**两个独立时钟**，前者那个是裸的墙钟基准且被多处无条件重锚：

1. `hibiki/lib/src/pages/implementations/reader_hibiki/navigation.part.dart`
   `_flushReadingStats`：`elapsedMs = now - _sessionStartTime`，且**首行以
   `_sessionCharsRead <= 0` 早退**——早退时既不落库、也不消费这段时长。
2. `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`
   `didChangeAppLifecycleState` 的 `resumed` 分支：`_sessionStartTime = DateTime.now()`
   （BUG-892 为「丢弃后台段」加的）。它**不区分**要丢的是后台段还是重锚前那段真实前台
   阅读时长——配合 ① 的早退，形成确定性的时长蒸发：

   > 翻一页（字数入账）→ 查词，窗口失焦（`inactive`）→ flush 落库 → 回来接着读**同一页**
   > （高水位不变，`_sessionCharsRead` 恒 0）→ 再查一个词失焦 → flush **早退，不消费时长**
   > → `resumed` 把 `_sessionStartTime` 推到当下 → **这一段阅读时长永久消失**。

   截图那天「查词 1000 次 / 1832 字」——失焦-回前台上千次，绝大多数发生在没有新字数的时候，
   于是当天只剩最后一小段（约 52 秒）落了库。
3. 同一个 `_sessionStartTime` 还在 `_onRestoreComplete`（**每次重排版 / 重恢复都会跑**，不只
   换章）里被无条件重置，同样在 flush 之前，同样吃掉未落库的时长。
4. PDF 侧（`reader_pdf_page.dart` `_flushReadingStats`）是另一个变体、更糟：它把**整段会话**
   `now - _sessionStartTime` 交给 `isContinuousReadingGap` 判一次，而 PDF 只在失焦/退出才
   flush ⇒ 任何超过 `kMaxReadingGap`(120s) 的正常阅读会话被整段判成「非连续窗口」丢弃，
   **读多久都记 0**。

`ReadingTimeTracker`（小时桶）没有这个毛病：它按 60s tick 逐段结算、逐段过守卫，重锚吃不掉
已结算的部分。所以两条账目才会分叉——错的一直是每书/每日那条。

### 修复
把两条账目并到**同一个**带 gap 守卫的时钟上，彻底删掉可被重锚的墙钟基准（消除特殊情况，
而不是给每个重锚点打补丁）：

- `packages/hibiki_audio/lib/src/audiobook/reading_time_tracker.dart`：新增
  `ReadingTimeDelta onDelta` 回调——每确认一段连续窗口，写小时桶的**同时**把同一份增量回吐；
  新增 `sampleNow()`（结算当前未满一个 tick 的窗口但**不停表**）与 `isRunning`。
  守卫逻辑一字未改，BUG-892 的保护原样保留。
- `reader_hibiki_page.dart` / `navigation.part.dart`：删除 `DateTime _sessionStartTime`，
  换成 `int _sessionReadingMs`（只由 `onDelta` 累加、只由**真正落库**那条路径清零）。
  `_flushReadingStats` 落库前先 `sampleNow()` 补上尾段；无新字数的早退**保留**累计器。
  `resumed` 不再重锚（后台段由「tracker 停着不 tick」天然排除）；`_onRestoreComplete`
  不再重锚（重排版不再吃时长）；失焦分支改成**先 `stop()` 再 flush**，让停表的收尾结算
  先进累计器。
- `reader_pdf_page.dart`：同款改造，并删掉「整段会话过一次守卫」那行——守卫改为逐 tick
  生效（后台/睡眠照样不计，长会话正常累计）。

### 影响面（须知，非 bug）
统一时钟后，「每书/每日时长」会与「Today by hour」小时桶**对齐**——也就是说它现在会包含
「阅读器开着 + app 在前台但用户没在翻页」的挂机时间（小时桶一直是这个口径，只是每书那条
以前因为把时长吃掉了所以显不出来）。后台 / 熄屏 / 睡眠仍然不计（tracker 停表 + `kMaxReadingGap`
守卫，BUG-892 的保护原样保留）。生产库里能看到极端例子：`2026-07-16` 全天只读 78 字，小时桶
却有 5 小时——修复后这 5 小时会记到书上。若认为挂机不该算，需要另加「无翻页/无输入即暂停
计时」的空闲判据（阈值是产品决策，未做）。

### 未做（本轮范围外）
- **挂机不计时的空闲判据**：见上「影响面」，需定阈值。
- **历史脏数据不修正**：既有 `reading_statistics` 行仍是被吃掉后的值，统计页「最快日」等
  极值仍会显示 421249 cph 这类爆表数。要么留着，要么另做一次性重算（可用同日
  `reading_hourly_logs` 作参考基准），需用户决定，不在本轮。
- **「速度」是否该忽略过短样本**：一天只读几十字时 cph 天然噪声大。BUG-892 尾部已记过
  「阅读速度忽略过短翻页 + 设置项」的跟进，仍未做。
