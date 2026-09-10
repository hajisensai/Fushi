## BUG-2424 · 换章加载期滚轮输入被丢弃且跨章冷却窗锚在加载完成

- **报告**：2026-09-10（用户：「我感觉阅读器来回跨章的时候会强制等待」；追问后确认输入方式=鼠标滚轮、症状形态=「按了没反应，要再按一次」；对修法的追加要求：「我觉得不需要我停手，就可以下一章比较合理，我就是要一口气跨多章呢」）
- **真实性**：✅ 真 bug（交互延迟 + 输入丢失，非崩溃）。根因不是章节加载慢——单向连续跨章遮罩口径中位数只有 88ms（仓库内既有实测证据 `.codex-test/windows-itest/xchapter-engine-after/command.log`，18 次跨章）。真正卡住用户的是叠在跨章路径上的两道闸门。

### 根因（两处，都在 Dart 侧的输入处理，不在加载链路）

**① 在飞期间的输入被静默丢弃，而不是排队**

- `reader_fushi/chrome.part.dart` `_paginate` 入口：`if (_paginationInFlight) return;`
- `reader_fushi/webview.part.dart` `onBoundarySwipe` handler：同款 `if (_paginationInFlight) return;`

`_paginationInFlight = _restoreInFlight || !_readerContentReady || _isNavigatingToChapter`，覆盖整段「换章加载 + 恢复」。这段时间用户拨的每一格滚轮都石沉大海，且**没有任何反馈**。

丢弃的原始理由（TODO-1229 案A）是真实的：在飞时 `fushiReader` 尚未就绪，`evaluateJavascript` 返 `null` → `_didScroll(null)==false` → 被读成「已到页边界」→ 再次 `_handlePageTurnLimit`，一次输入产生两次跨章（用户复诉三次的「跳两章」）。**但那是判定时机错了，不是输入本身该被扔掉。**

**② 跨章冷却窗锚在「新章 content-ready」，等待随加载时长膨胀**

`_kChapterTurnCooldown = 450ms`（`reader_fushi_page.dart`），由 `_chapterTurnCoolingDown()` 拦截惯性输入的跨章。窗口只由两处 stamp：真正发起跨章（`_noteChapterTurn`），以及**该次跨章落地的新章 content-ready 时重新 stamp**（`_noteChapterTurnSettledIfPending`，TODO-1229 v3 为堵「加载 >450ms 时窗口早过期」而加）。

于是滚轮跨章一次的完整等待账：

| 时刻 | 事件 |
|---|---|
| t=0 | `onBoundarySwipe` 放行，stamp 冷却窗 + 置惯性旗 + `_beginNavigation` 令 `_paginationInFlight=true` |
| t=0 ~ T_load | 所有滚轮 tick **静默丢弃** |
| t=T_load | `_onRestoreComplete` → `_noteChapterTurnSettledIfPending()` → 冷却窗**重新 stamp 到此刻** |
| t=T_load+450ms | 冷却窗才过期 |

**下一次跨章最早只能在 `T_load + 450ms`**：纯文本章约 540ms，带整页插图章 800~1000ms（`docLoad` 实测可达 235ms，插图章遮罩 355~541ms，见 BUG-1140）。

判据维度本身就错了：要区分的是「同一次拨轮的残余惯性」与「用户新拨了一下」，而惯性时长是手离开滚轮那刻起算的固定物理量，**和章节加载多久没有任何因果关系**。把窗口锚在加载完成上，直接后果是「加载越慢，罚用户等得越久」。

**③（附带）设备信息传了却被丢掉**

BUG-1745 起 JS 侧就随方向一起回传输入设备（`webview.part.dart:1481`，鼠标=`'wheel'` / 触摸板=`'trackpad'`），但 `onBoundarySwipe` 的 Dart handler 只读 `args[0]`，`args[1]` 整个丢弃。缺了这一维，跨章路径只能对所有设备一刀切上时间窗——而鼠标滚轮一格就是一个 tick、一次明确意图，本不该被聚合。

### 修复

**把「丢弃」换成「排队」，删掉整套时间窗。**

1. 新增 `ReaderPageTurnQueue`（`lib/src/reader/reader_pagination_scripts.dart`，紧邻既有 `ReaderWheelGestureGate`）：带符号积压计数，反向意图相互抵消，上限 `kMaxPending = 8`（一次误触的惯性流不换来失控连翻）。
   存的是**翻页意图**而非跨章意图——重放走完整 `_paginate`（章内还有页就翻页，真到边界才跨章），所以刚落地新章的章首插图页会被正常翻过去，而不是被越过。「章首整页被跳过」正是原始症状的另一半。
2. 两处在飞路径改为 `_pageTurnQueue.push(direction)` 后 return。
3. `_replayPendingPageTurn()` 在三个 content-ready 完成点消费：`_onRestoreComplete` 的**延后收尾块最末**（遮罩已撤、新章可见、`fushiReader` 已就绪，且共用该块既有的 `_navigateGeneration` 代际守卫）、`spreadReady`、8s 兜底超时。
   消费到「队空」或「又进入在飞」为止，两种出口都必要：重放导致**跨章**→ `_paginationInFlight` 立刻为真 → 退出循环，剩余意图由那次导航的 content-ready 再进来消费，串成 1:1 的链；重放只是**章内翻页**（新章还有下一页）则不会再有 content-ready 把它叫醒，必须就地继续消费，否则剩余意图一直压到下一次跨章才突然连翻（自查补漏，提交 c68cfb579d）。另有 `_replayingPageTurns` 重入闸：await 期间可能被另一个完成点再次调用，两个循环同时消费同一队列会让意图乱序落到不同章上。
   **重放不过 `_lastPaginateTime` 节流**——该节流限的是用户新输入的速率，积压意图是已按下过、被延后执行的输入，再节流一次等于又丢一遍。
4. 删除 `chapterTurnCoolingDown` 纯函数、`_kChapterTurnCooldown`、`_lastChapterTurnAt`、`_inertiaChapterTurnPending`、`_noteChapterTurn`、`_noteChapterTurnSettledIfPending`、`_markInertiaChapterTurnPending`，以及只服务于它们的 `_handlePageTurnLimit(inertia:)` 参数。4 个状态位 + 2 个 stamp 点 → 1 个队列。
5. `onBoundarySwipe` 改读 `args[1]` 的 `pointerKind`。
6. **节流统一前置**（用户于 2026-09-10 明确要求：「都受他管 连续模式的也受它管」）：
   `wheelPageTurnInterval` 是**用户自己在设置里配的限速器**（150~800ms 可调），语义是
   「每隔这么久接受一次翻页输入」——**统一管章内翻页与跨章，两种模式一视同仁**。
   故：连续模式的 `onBoundarySwipe`（绕过 `_paginate` 入口）就地补一道同款闸门；
   `_paginate` 入口的节流从在飞判定**之后**提到**之前**。两处顺序完全一致：
   **先节流 → 再 stamp → 最后才是在飞排队**。过了节流 = 这一次输入被接受、占掉
   一个翻页配额，所以即使接着要入队也先 stamp（不然加载期内每个 tick 都会被
   接受入队，落定后一次性连翻，等于用户配的速率对跨章不生效）；重放不再过节流
   （这一格在**入队前**就已经过了）。

   > 这里走过一次弯路，记下来免得后人重踩：初版把用户的「不需要我停手就可以下一章」
   > 读成了「跨章不该限速」，于是把 `onBoundarySwipe` 的节流窗一并删了。实际上用户指的
   > 是**隐藏的冷却窗**（不可配、而且随加载时长膨胀）；他自己配的限速器应该照常生效。
   > 判据：**用户可见可调的闸门统一生效，隐藏且锢错地方的闸门才该删**。
7. **触摸板惯性仍必须聚合，但理由不是时间窗**：跨章会 `loadUrl` 换文档，JS 侧的 `_continuousWheelLastTickAt` 随之归零，新章的第一个残余惯性 tick 会被 JS 那道 `startsNewWheelGesture` 误判成「新手势」而放行 → 二次跨章。这正是必须由活在 reader State、跨文档持续存在的 `_pagedWheelGestureGate`（BUG-1342 同一实例）兜住的洞。鼠标滚轮不经此 gate。

「一次输入最多产生一次跨章」这条真正的不变式，现在由队列的 1:1 消费直接保证，不再需要任何时间窗。

### 与 BUG-1829 / TODO-1229 的关系

BUG-1829 修的是「被拦输入自我续期 → 单页章成滚轮死区」。队列化之后**「输入密度」这个维度整个消失**：每一格滚轮要么当场执行、要么进队列等重放，没有任何一条路径会把它扔掉，所以「拨得越快越不动」在结构上不可能再发生。旧守卫护住的行为不变式（不饥饿、单页章能连续前进、一次输入不跳两章）已在新测试里用新语义重新钉住。

- **[x] ① 已修复** — 见上，`fix/reader-cross-chapter-input-queue`
- **[x] ② 已加自动化测试** —
  - `fushi/test/pages/chapter_turn_queue_test.dart`（19 项，取代已删的 `chapter_turn_cooldown_test.dart` / `chapter_turn_cooldown_ready_restamp_test.dart`）：队列纯语义（1:1 消费 / N 次输入 N 次重放 / 反向抵消 / 上限 / clear）、旧守卫行为不变式的新语义版、源码守卫（两处在飞路径必须入队 / 冷却窗整套不得复活 / 跨章不得叠节流窗 / 触摸板经 gate 而鼠标不经 / 三个完成点都重放 / 重放排在收尾之后且受代际守卫 / 非翻页导航作废积压）。
    源码守卫读的是 `maskComments()` 剥注释后的语料——钉的是「代码里没有这些接线」，不是「注释里不准提这些名字」；本次改动的说明注释本身要讲清删掉了什么，裸扫原文会被自己的解释文字判红。
  - `fushi/test/reader/reader_spread_image_ready_gate_test.dart`：那条原本钉冷却窗重锚的断言改钉新的等价物（spreadReady 仍是 content-ready 完成点，必须重放积压意图）。不变式没变而且更要紧——spread 路径从不发 `onRestoreComplete`。

### 真机实测（Windows 离屏 itest，同机同书同用例、只换 lib）

用例：`integration_test/reader_cross_chapter_input_queue_itest.dart` ——
forward → backward → forward → backward 四拍，每拍之间**从发起时刻起恰好等满
`wheelPageTurnInterval`（用户配的那道闸门）、不多等一毫秒**。

这个等待时长是故意选的，恰好能把两道闸门分开：节流窗从**发起**那一刻算
（加载耗时包含在窗内），而被删的冷却窗从**新章 content-ready** 重新 stamp。
所以等满 throttle 时：新代码已过闸门该放行，旧代码还在 `T_load + 450ms` 的冷却里。

修复前（lib 还原到基底 `87eda400f2`，`xchapter-throttle-mutant`）：

```
[xchapter-queue] #0 forward  chapter_01 -> chapter_02  landed=116ms
[xchapter-queue] #1 backward chapter_02 -> chapter_02  landed=0ms
Some tests failed.  (exit 1)
```

第 1 拍 **30 秒内完全没有落地**（`landed=0ms`）、章节原地不动——这就是用户报的
「按了没反应」的真机复现：此刻冷却窗刚在 chapter_02 的 content-ready 被重新 stamp，
正是窗口最满的时刻。

修复后（`xchapter-final`，对应最终提交）：

```
[xchapter-queue] #0 forward  chapter_01 -> chapter_02  landed=119ms
[xchapter-queue] #1 backward chapter_02 -> chapter_01  landed=134ms
[xchapter-queue] #2 forward  chapter_01 -> chapter_02  landed=102ms
[xchapter-queue] #3 backward chapter_02 -> chapter_01  landed=122ms
All tests passed!  (exit 0)
```

四拍全部落地，落地时间 102~134ms **就是章节加载本身**，隐藏冷却窗带来的额外
等待归零（修复前是 `T_load + 450ms`，且第 2 拍起直接被吞）。来回四拍回到起点、
四次输入恰好四次跨章（无「跳两章」）。用户配的 `wheelPageTurnInterval` 仍然生效。

证据：`fushi/.codex-test/windows-itest/xchapter-{final,throttle-mutant}/command.log`（不入库）。

- **备注**：交互延迟 + 输入丢失，非崩溃。`test/pages`（3601 项）、`test/reader`（1611 项）定向全绿，`flutter analyze`（含 test）零问题，真机用例已做变异实测（还原 lib 即红，见上）。
