# 阅读「读过」判据统一：ReadUnitLedger（翻走即计 + 会话覆盖并集）

日期：2026-09-06。裁定人：用户。对照对象：Hoshi Reader iOS（`Manhhao/Hoshi-Reader`）与 Android（`HuangAntimony/Hoshi-Reader-Android`），两端源码浅克隆精读（引用行号以当日 `develop` 为准）。

## 0. 裁定

1. 阅读三域（EPUB / 漫画 / PDF）的「读过」口径 = **翻走即计**：离开一个内容单元那一刻，把该单元里此前未覆盖的部分全额计入。没有停留门、没有速率封顶。
2. 去重靠**覆盖并集**，范围 = 本次打开的会话；关书重开再读同一页照常计。
   **第二次裁定（2026-09-06 晚，用户选「混合」）**：入账额 = 并集 ∩ [0, 当前位置)。回翻到 X 撤回 X 之后已入账的（误翻很多页再翻回来净 0，对齐 Hoshi 的会话级负数扣减、夹 0）；再前进 / 跳到 Y 时 `[X, Y)` 里翻过的按并集恢复、不用重读也不双计；从未翻过的仍不计（跳转仍是「跳走前那页计、跳过的不计」，这点与 Hoshi 的位移差分不同）。代价（已知、接受）：读完一段回头查上文再关书，只计到查看位置之前。`StudyClock.retractChars/retractPages` 从最新段往前扣、已封段绝对值重写落库、会话级夹 0；停表期间与入账对称丢弃。
3. 三域共用一个账本对象 `ReadUnitLedger`；视频保持自己的 tracker（连续播放推进语义不同），只共享区间并集类型 `IntervalCoverage`。
4. 进度 UI / 落库位置那本账不动。

## 1. 与 Hoshi 的全部统计口径对照

「现状」= 本文件写下时的 develop（含当日上午合入的 BUG-2205~2186 修复）；「新」= 本计划落地后。

### 1.1 字数

| 口径 | Hoshi iOS | Hoshi Android | Hibiki 现状 | Hibiki 新 |
|---|---|---|---|---|
| 计入时刻 | 每 1s tick 差分：`当前视口之前字数 − 上次`，正加负减（`ReaderViewModel.swift:481-490`） | 同 iOS（`ReaderStatisticsTracker.kt:70-92`） | 每次进度采样：绝对位置越过会话高水位的部分，再过令牌桶（40 字/秒，桶 4800 字）（`navigation.part.dart:1145-1168`） | 离开单元时：单元 `[start,end)` 中并集未覆盖的部分全额（`ReadUnitLedger.arrive/leave`） |
| 单元 / 粒度 | 视口起始边之前的文本节点，**整节点**（`reader.js:74-95`） | 跨边节点做 code point 二分（`reader-paginated.js:105-140`） | 起点 caret 精确；分页 progress 按节点起始边（`progressStops`），跨页长段落整段计 | 起点 / 终点都 caret 精确到学习单位；终点探测失败降级节点粒度（单调） |
| 会话内回翻 | 扣减（封顶到会话 0） | 同 | 不计不扣 | 不计不扣 |
| 会话内重读 | 再计一遍 | 同 | 不计 | 不计 |
| 跨会话重读 | 再计 | 再计 | 再计 | 再计 |
| 跳转（目录 / 进度条 / 搜索 / 收藏） | `flushStats` 后 `resetTrackingBaseline`：跳走前那页不计（视口之前才算）、跳过的不计 | 同 | 播种水位到落点：跳过不计、跳走前那页看进度是否越过水位、落点页要等额度 | 跳走前那页计（你在那页）；跳过不计；落点页翻走时计 |
| 换章 | 相邻章 `nextChapter` 不换基线，差分正常；非相邻走跳转 | 同 | 恢复完成播种 + 令牌桶清零 → 新章首页按 40 字/秒慢补；末页因 `isAtEnd→1.0` 到达即整页计 | 坐标是全书绝对偏移，章边界透明；末页在新章首页 arrive 时结算 |
| 改字号 / 主题 / 竖横排重排 | WKWebView 换 key 重建 + `restoreProgress`，统计无处理，靠字符比例锚隐式不变 | `prepareReloadAtDisplayedPosition`，统计无处理，页边界漂移记成 ± diff | 水位取 max + 原位恢复保留额度（BUG-2206）；缩字号前漂已修（BUG-2205） | 同页新边界 arrive 结算旧边界，并集只补多露出的行（BUG-2225 后 EPUB 不再 rebase） |
| 速率封顶 | 无 | 无 | 40 字/秒（`kMaxReadCharsPerSecond`） | 无 |
| 停留门 | 无 | 无 | EPUB 无；漫画到达 1.5s；视频 cue 1.5s | EPUB / 漫画 / PDF 无；视频 cue 保留 1.5s（`kArrivalDwellMs` 唯一消费者） |
| 字符口径 | ttu 正则：字母 / 假名 / 汉字（`reader.js:26-36`） | 同 | `countStudyChars`：剔 `rt/rp/rtc`、空白标点（`epub_book.dart:641-663`）；JS `fushiStudyUnits` 同口径 | 不变 |
| 有声书 | Sasayaki 翻页触发 `onPageTurn`（autostart 输入），字数照差分 | 同 | 跟随模式：滚动回传照计；歌词模式：不计字 | 不变 |
| 漫画 | — | — | 到达停留 1.5s 整页计；会话 Set 去重；存档页之前预置已计 | 翻走即计；并集去重；不预置 |
| PDF | — | — | 到达即计、标量水位：跳 N 页计 N 页 | 翻走即计；只计跳走前那页 |

### 1.2 时长

| 口径 | Hoshi iOS | Hoshi Android | Hibiki 现状 / 新（本计划不改时长） |
|---|---|---|---|
| tick | 1s（`ReaderView.swift:721-731`） | 1s | 60s `StudyClock`；UI 每秒读 `sessionTotals()`（含未结算窗） |
| 空闲 / AFK 门 | 无：开着就累计 | 无 | 10 分钟无输入不入账，设置可调 |
| 什么算输入 | 只用于自动开始（`pageturn`） | 同 | 翻页 / 滚动回传 / 听书播放态 cue 推进（查词、10s 轮询不算） |
| 自动开始 | `off / pageturn / on`，**默认 off**（不手动开不统计） | 同，`pageturn` 基线取翻页前位置 | 开书即计 |
| 后台 / 失焦 | `willResignActive` 直接丢基线（后台前最后 tick 之后的秒数也丢） | `ON_PAUSE` 先 update 再停 | `stop()` 结算到失焦瞬间再封段；`resumed` 续表 |
| 弹层 | 不停 | 外观 / goto / sasayaki / 统计 / 全屏图停 | 同 Android 集合 + 目录 / 搜索 / 书签 / 有声书导入 / 画廊；查词与 Anki 制卡不停（BUG-2208） |
| 手动暂停 | 有 | 有 | 有 |
| 断档 / 睡眠补发 | 无过滤，系统时间跳变直接进 diff | 同 | 120s 断档整窗丢弃；时钟回跳不计 |
| 最小会话门槛 | 无 | 无 | <1s 且无内容账的段不落库 |
| 停表期间的字数 | 不产生（tick 停） | 同 | `addChars` 丢弃（BUG-2210） |

### 1.3 数据结构 / 持久化 / 同步

| 口径 | Hoshi | Hibiki |
|---|---|---|
| 存储 | 一书一个 `statistics.json`，按天一条：`charactersRead / readingTime(秒) / min·alt·last·max 速度 / lastStatisticModified` | `study_segments` 段表：一段一行、不跨小时、uid 键控、绝对值 upsert；legacy 四表冻结只读 |
| 跨书聚合 | iOS 无统计页；Android 逐书读 JSON 聚合 | `loadStatFacts` 统一事实面（日面 / 小时面） |
| 同步 | Drive ttu 文件：Merge = 按 dateKey `lastStatisticModified` 大者整条覆盖；Replace = 远端全覆盖（同书同天两端各读必丢一端） | uid LWW 并集 + 按身份墓碑（压制 `startAt < deletedAt` 的段，碑永不退场） |
| 清空 / 删除 | 覆盖文件 | 逐身份立碑（BUG-2215）；删单本立碑 |
| 「今日」边界 | Android 可配重置时刻（`statisticsResetMinutes`），写入时定 dateKey | 本地 0 点固定，跨午夜整页重聚合（BUG-2219）。**可配重置时刻：未做，候选** |

### 1.4 展示

| 口径 | Hoshi | Hibiki |
|---|---|---|
| 会话速度 | `charactersRead / readingTime × 3600` 累计均速 | `readingCharsPerHour` 会话秒表，开局即显 0 |
| 今日 / 累计速度 | 同上，无门槛 | `computeCph`，样本 < 60s 显示「—」（BUG-2218） |
| 剩余时间 | session 均速 | 会话速度优先，无会话数据回退全书均速（`readerFinishCph`） |
| 目标 / streak | Android：日目标（字数或时长）+ 周目标天数 + 日 / 周 streak | 日 / 周字数目标 + 日 streak（`computeReadingStreak`） |
| 热力图 | Android 8 级按秩 | 4 级按秩（BUG-2223） |
| 时段（小时）分布 | 无 | 有（小时面） |
| 英文字数 | Android 5 字符 ≈ 1 词显示 | 无（候选） |
| 异常值过滤 | 无 | 写入侧无（新）；展示侧 60s 门槛 + 环比封顶 |

### 1.5 未采纳 / 候选（不在本计划内）

- Hoshi 的差分扣减模型（劣于并集）；按 dateKey 整条覆盖的合并（劣于 uid LWW）。
- 候选功能：「今日」可配重置时刻；首次翻页才开始计时（autostart）；英文 5 字符一词展示。

### 1.6 有声书 / Sasayaki：形态与数据

| 口径 | Hoshi（iOS / Android 同构） | Hibiki |
|---|---|---|
| 形态 | 仅 Sasayaki：音频 + SubPlz 生成的 SRT + EPUB，cue = SRT 块（`SasayakiParser.swift:12-48` / `SasayakiParser.kt:6-27`） | 三种：EPUB + 字符对齐（smil / json / lrc）、EPUB + SRT/VTT/ASS 句级、纯 SrtBook（`audiobook_model.dart:8-59`、`tables.dart:72-118`） |
| cue 数据 | `sasayaki_match.json`：`id / startTime / endTime（秒）/ text / chapterIndex / start / length`（章内字符起点 + 长度）+ `unmatched`（`Models/Sasayaki.swift:18-37`） | `audio_cues` 表：`bookKey / chapterHref / sentenceIndex / textFragmentId / text / startMs / endMs / audioFileIndex`；对齐命中编码 `fushi-cue://s=&ns=&ne=`（`subtitle_rematch_codec.dart:16-64`） |
| 音频引用 | iOS security-scoped bookmark；Android `audioUri`（可复制进 `bookRoot/Sasayaki/`） | `audiobooks.audioRoot / audioPaths`；SrtBook `audioPathsJson` |
| 播放位置 | `sasayaki_playback.json`：`lastPosition（秒）/ delay / rate / 音频引用`，每跨整秒写 | 偏好表 `audiobook_pos_<key>` + LWW 孪生键 `audiobook_pos_at_<key>`（`audiobook_repository.dart:211-238`） |
| 阅读位置 | `bookmark.json`（章 / progress / characterCount / lastModified） | `reader_positions` 表（`sectionIndex / normCharOffset / charOffset`） |
| 谁覆盖谁 | **单向**：音频位置 → cue → bookmark；阅读位置不回写音频 | 仅 `reveal == true`（播放跟随 / 显式 reveal）时 cue 覆盖阅读位置；被动高亮不覆盖（TODO-718，`audiobook.part.dart:690-699`） |
| 同步 | Drive `audioBook_*` 只带 `playbackPosition + lastAudioBookModified`，方向跟随 bookmark 判定 | 偏好键随聚合同步 LWW |

### 1.7 有声书 / Sasayaki：统计方式

| 口径 | Hoshi | Hibiki |
|---|---|---|
| 独立「听」时长 | **没有**：`Statistics` 只有 `readingTime`，播放时间混入阅读时长 | **没有**：同一 `StudyClock`、同一段、`mediaKind='book' / format='epub'`；无播放态标记 |
| 播放态 tick | 播放与统计完全解耦，1s tick 照跑（`SasayakiPlayer` 无统计调用） | 同一时钟 60s tick；播放态每次 cue 推进 `touch()` 喂空闲门（BUG-2212），否则 10 分钟停 |
| 音频暂停 | 不影响统计 | 不停表，只是不再 `touch` |
| 字数：播放跟随 | cue reveal 的 JS 回调走 `onPageTurn / onSaveBookmark → flushStats`，视口差分照计 | reveal 后按 `kReaderReanchorSettleMs` 补刷 `_refreshProgress → arrive`，翻走即计 |
| 字数：同章跳句 / 拖进度条 | 跳过的段落按位置差**算读过** | 显式跳句 `leave()`：跳走前那页计、跳过不计；拖音频进度条无回调，靠下一次 `arrive` 结算 |
| 字数：跨章跟随 | `flushStats` + `resetBaseline`，跨章那跳不计；Android 另有 media stop 页 `countStatistics=false` | 全书绝对坐标透明，末页在新章首页 `arrive` 时结算 |
| 歌词模式 | 无此模式 | 时长照计、字数不计（`_refreshProgress` 首行早退） |
| autostart | 播放推进算 `pageturn` 输入（iOS 分页 / 滚动都触发；Android 仅 `countStatistics=true` 分支） | 开书即计，不适用 |
| 后台 / 锁屏播放 | 音频继续；tick 停、回前台重置基线 → **后台听的时长与字数都丢** | `paused / inactive` 都停表、`addChars` 丢弃；退出页面后台续播时 `StudyClock` 随页面 dispose，**完全没有统计写入方**。缺口与 Hoshi 相同 |
| 面板 | Android：Sasayaki 面板停统计；iOS：任何面板都不停 | 有声书面板 / 导入 / 对齐 / ASR sheet 都停（`_withStudyClockPaused`）；底部播放条不停 |
| 关书 | iOS 返回键 `stopTracking → flushStats`，swipe-dismiss 路径未见 flush；Android `closeReader` 先存位置再停播放 | `onSourcePagePop`：flush 位置 → `leave()` → `_flushReadingStats()`；进程退出同序 |
| UI 展示 | 无听书项（Session / Today / All Time 三段） | 无听书项（会话 / 今日 / 累计 / 预计读完；统计中心 overview / reading / video / game） |

## 2. 边界条件（现状 → 新模型）

| 场景 | 现状（水位 + 令牌桶） | 新模型（翻走即计 + 会话并集） |
|---|---|---|
| 顺序读到章末翻入下一章 | JS `isAtEnd` 把末页 progress 报成 1.0 → 末页**到达即整页计入**；下一章恢复完成播种 `cumulative[N+1]+0` = 同一值，不双计；但换章判为「前跳」→ 令牌桶清零，新章首页按 40 字/秒慢补 | 末页单元 `[start, 章总字数)`；`_navigateToChapter` → 新章首页 arrive 时结算末页；新章首页翻走时全额计。坐标全书绝对，章边界透明 |
| 往回翻到上一章 | 水位只升不降 → 不计；再翻回来越过水位才计 | 并集已覆盖 → 0；再前翻已覆盖 → 0；越过此前最远处的新页照常计 |
| 目录 / 进度条 / 搜索 / 收藏句跳转 | 播种水位到落点、清桶 → 落点页要等额度 | 跳走时结算跳走前那页；跳过的从未成为当前单元 → 不计；落点页翻走时计 |
| 听书显式跳句 | `onExplicitCueJump` 抬水位、不清桶 | `leave()`：结算当前页；跳过段落不计 |
| 听书自动跟随跨章 | 同顺序翻页；reveal 后 250ms 内 scroll 回传被 B-3 窗吃掉，新页靠 10s 轮询 | 同顺序翻页；reveal 落定补一次 `_refreshProgress` |
| 改字号 / 主题 / 行距（CSS 热换重锚） | 水位 max、额度保留（BUG-2206）；缩字号前漂已修（BUG-2205） | 同页提前结算、新边界只补多露出的行，总额不变（BUG-2225 起不再 rebase：原位判据把同章跳转恒判原位） |
| 旋屏 / 拖窗 / 分页↔连续 / 竖横排（整章重载） | 同上 | 同上（`_onRestoreComplete` 判原位恢复） |
| 分页节点粒度 / 跨页长段落 | 起始边越过页首即整段计 | 起点 / 终点 caret 精确；降级节点粒度、单调 |
| 首次开书 / 恢复到存档页 | 播种到恢复锚；存档页按额度慢计 | 存档页是当前单元，翻走时计一次（不预置，与 Hoshi 同） |
| 纯图片章 / 封面 | `snapshot == null` 只更新 UI | 同，不 arrive |
| 内容就绪兜底超时 / 导航失败 | 不播种 | `_beginNavigation` 已 `leave()` 结算上一页，`discard()` 只丢新页空状态（BUG-2226） |
| 章字数后台补算落定 | 水位重置到当前位置 | `reset()`：并集清空、当前丢弃 |
| 停表期间翻走（手动暂停 / 后台 / 面板） | 水位推进但 `addChars` 丢弃，之后不补 | 并集照常标已覆盖，`addChars` 丢弃，之后不补（契约不变） |
| 歌词模式 | 不计字 | 不计字（不 arrive） |
| 连续模式惯性滚动 | 50ms 节流多次推进、额度跨次结转 | 每次落定采样一个单元，相邻重叠只计新露出；甩过去的全计（裁定无门） |
| 漫画存档页 | 预置 0..存档页已计 | 不预置；翻走时计一次 |
| PDF 跳 N 页 | 计 N 页 | 只计跳走前那页 |
| JS 拿不到终点（旧 shell / 探测失败） | — | `end < 0` 不 arrive，宁可不计 |

## 3. 架构（见 `C:\Users\Wight\.claude\plans\quizzical-weaving-whale.md` 全文）

- `fushi/lib/src/stats/interval_coverage.dart`：`IntervalCoverage`（原 `WatchCoverage` 搬家改名，新增 `addFresh` 返回新增子区间）。
- `fushi/lib/src/stats/read_unit_ledger.dart`：`ReadUnitLedger { arrive, leave, rebaseOnNextArrive, discard, reset }`，纯 Dart。
- EPUB：删 7 个纯函数 + 3 个字段 + 5 处播种点；`_refreshProgress` 一行 `arrive`；JS 新增 `getLastVisibleCharOffset`，协议 `current,total,start,end`。
- 漫画 / PDF：各自的 Set / Timer / 标量水位替换成同一账本。
- 文档：`docs/agent/statistics.md` 写入面新增口径条款；`study_clock.dart` `kArrivalDwellMs` 注释改准确。
