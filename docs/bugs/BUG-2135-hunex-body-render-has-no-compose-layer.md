## BUG-2135 · WoH 正文渲染没有合成层，HUNEX 几何模型的三级 compose 假设不成立
- **报告**：2026-09-03（BUG-2134 定位到 compose 锚点假阳性后，继续按真机计数逐步收敛）
- **真实性**：✅ 真 bug（引擎模型与实际渲染架构不符），全部结论由真机计数支撑。
- **逐步测得的事实**（每一步都是新增计数/诊断后读出的，不是推断）：
  1. `compose_wrapper:0`、`compose:0`、`compositor:2740` —— **两个 compose 入口都从未被调用**，compositor 被调用上千次。适配器把 `wrapper_scope` 当作 compositor 相关性的硬前提，因此候选恒为空。
  2. compositor 的调用者：不加闸门时 `count:4, overflow:1691`（通用 blit，绝大多数与正文无关）；把记录闸门在「本线程刚封存过正文行且仍新鲜」后收敛为 **唯一调用点 `RVA 0x0013535a`**，落在 `draw`（0x133fc0）与 `render_item_return`（0x1355d3）之间，即 **draw 函数体内部**。
  3. 据此实现了 draw→compositor 的结构化锚点（在 draw 跨度内找对 compositor 的 rel32 调用）。首次实现要求「恰好一处」，真机读出 **`call_count:2`** —— draw 里有**两处**这样的调用，于是 fail-closed 留空。改为接纳两处后，两个锚点均推导成功：`return_rva:0x001352c5`、`alt_rva:0x0013535a`。
  4. 直连相关性路径随即**开始触发**（trace 首次出现 `stage:2(compositor)` 事件），但内层身份判据不过。把四个子条件拆开报点后得到 **`failure:35(body_compose_source_mismatch)`**：源表面不是该行末字形的位图。
  5. 再加尝试/命中计数：**`body_compose={attempts:4, source_matches:0, published:0}`**。即待定正文行的新鲜窗内，这个调用点只触发 4 次，且**没有一次**的源表面是该行字形位图；配合被拒事件里 `destination=(0,0)`、源表面 24×25、而该行末字形位图 55×56，可判定**这两处调用不是正文的合成点**。
- **结论**：**WoH 的正文渲染路径上不存在「把字形位图合成到目标表面」这一层**。适配器的几何模型（wrapper → compose → compositor → texture upload → quad → sprite draw 六段链）假设了一个 WoH 没有的中间结构。`texture_upload` 约 20 万次、`quad_vertex` 约 7~14 万次、`sprite_draw` 约 25 万次的量级，更像**逐字形贴图直绘**而非「整层合成后一次上传」。该假设本轮未能证实（见下）。
- **[x] ① 已实现的部分（量具 + 直连锚点，几何判据未放宽）**：
  - trace v4→v10：新增 `kWorker` 段与 9 个 worker 失败码；四个投影 detour 的无条件调用计数；compositor 调用者 RVA 记录（带待定正文行闸门）；`body_compositor_return/alt` 锚点推导结果；直连路径的 attempts/source_matches/published 计数；逐字形贴图假设的 attempts/matches 计数；`kBodyCompose*` 四个失败码。probe 全部可读。
  - `hook/adapters/hunex_gge_adapter.inc`：在 draw 跨度内结构化推导 draw→compositor 调用点（**不写死 RVA**，上界两处，第三处即判多解并整体留空）；compositor detour 增加一条直连相关性路径，判据与既有同级严格（调用点 + 同线程 + 新鲜 + 源表面逐字节相同 + 落点等于末字形矩形 + 目标表面 sane），任一不成立即什么都不做。
  - 驱动 `profile`/`state` 现在打印 `statusReason`。
- **[x] ⑤ 又两轮测量：字形坐标是「行条带」局部坐标；「上传在别的线程」假设已证伪** —
  - 取到真正的正文行后读字形事件：同一行的字形**全部 `y:4`**，`x` 每字精确 +27（153/180/207/234/261/288），`glyph_metrics 26×26`。即 `render x/y` 是**行条带内部**的局部坐标，不是屏幕坐标；条带本身落在哪，正是原设计要靠 compose 段给出、而 WoH 没有的那一环。
  - 顺带确认 trace 里一直带着的 `viewport={left:0,top:0,right:1788,bottom:1006,scale_x:0.93125,scale_y:0.931481}` **与实测客户区逐值相同**——游戏自己的 viewport/缩放全局是可信的，一旦拿到条带在逻辑面上的位置，最后一段映射不缺条件。
  - 于是检验「条带作为纹理上传」：在待定正文行新鲜期内记录上传纹理尺寸，读到 `count:0`。放宽为**不问线程**后仍是 `any:0`。再无条件记录线程 id，得到 `story_tid:10836`、`caller_tid:10836`，而字形事件也是 `tid=10836`——**三者同线程，「上传发生在别的线程」假设证伪**（`g_hunex_gge_pending_story_compose` 是 `thread_local`，此前我一度以为是跨线程不可见，不成立）。
  - **因此真正的变量是待定正文行的「存活窗口」**：它在 `FinalizeExactLineTraversal` 成功时设、在同一处的 else 分支清（`hunex_gge_adapter.inc` 的 `pending.story_thread_address != 0 && ... ? 设 : 清`），而该处每次遍历都会跑。compositor 恰好在同一趟绘制内被调用，所以能看到 4 次；纹理上传发生得更晚（或落在下一帧），那时待定行已被下一次 Finalize 清掉。
- **[x] ⑥ 纹理上传段同样不成立：描述符从来读不出来，且 wrapper 里根本没有 CPU 表面指针** —
  - 把计数移到描述符门**之外**后读到决定性数字：`upload_desc={ok:0, fail:141070, with_active_story:3170}`。即 **14 万次上传里描述符一次都没读出来**，而其中 3170 次确实发生在待定正文行仍活着的时候——**待定行的存活窗口没有问题**（此前 ⑤ 里「窗口太短」的猜测据此排除），堵点纯粹在描述符可读性。
  - 于是在上传 wrapper 对象前 `0x200` 字节内**结构化搜索**「指向 sane CPU 表面的指针槽」（SEH 兜底、只在待定行活着时扫、最多记 4 个）。结果 **`count:0`**：整个范围内没有任何指针指向合法 CPU 表面。既有的 `wrapper+0xd8` / 回退 `+0x84` 不是「偏移写错了」，而是 **WoH 的上传路径根本不携带这种 CPU 表面描述符**（很可能直接从 D3D 托管资源或另一种结构上传）。
- **[x] ⑦ quad 段同样落空，且 thread_local 是跨段相关的结构性障碍** —
  - 先解决可见性：`g_hunex_gge_pending_story_compose` 是 `thread_local`，而 WoH 各渲染段并不都在封存字形的那条线程上（实测 quad 段 `seen:0`、上传段某些会话 `caller_tid != story_tid`）。**任何跨段相关都因此不可能成立**。故按文件里既有的 `PublishHunexGgeProjectionEvidence` seqlock 范式，新增一份**进程内发布副本** `g_hunex_gge_published_story_compose` + `PublishHunexGgeStoryCompose` / `ReadHunexGgePublishedStoryCompose`。**不改任何既有判据**——thread_local 那份仍是原逻辑唯一依据，发布副本目前只供诊断与跨段观测。
  - 换用发布副本后 quad 观测仍是 `seen:0`，于是再加两个计数分型，得到决定性读数：**`story_seal={published:4, quad_reached:0}`**。即**确实有 4 条正文行封存并发布**，而 `RecordHunexGgeStoryQuad`（放在 quad 组装成功、`g_hunex_gge_pending_quad` 落地之后）**一次都没被调用到**。
  - 而 `quad_vertex` 本身被调用 18 万次 ⇒ **quad 段每一次都在形状校验处提前返回**（要求原函数返回 4 顶点、`manager+0x18 mode == 1`、纹理尺寸 ∈ (0,32768]、offset 有限）。BUG-2132 给这几处补的 `kQuadShapeRejected` 等诊断只在 surface chain active 时才发，而那个前提在 WoH 永不成立，所以此前一直是哑的。
- **总结：六段链对 WoH 逐段落空**。compose 两个入口零调用；draw→compositor 的两处调用不是正文合成点（4 次尝试 0 次源匹配）；字形坐标是行条带局部坐标；纹理上传不暴露 CPU 表面（0/141070，且 wrapper 前 0x200 字节内无任何 CPU 表面指针）；quad 段 18 万次调用**全部**在形状校验处被拒。**该引擎需要另起一套几何模型**，而不是修补现有链的某一环。可能方向（均未验证）：① 放弃 CPU 表面身份，改用 quad/sprite 的绘制顺序 + 行条带尺寸做相关；② 直接在 D3D 呈现层（Present / SetTexture）建立「条带纹理 → 屏幕矩形」的映射；③ 完全绕开渲染链，用游戏自己的 viewport/scale 全局加上从脚本层取到的行布局推算。
- **[ ] ② 未完成：正文几何仍未发布** — 逐字形贴图假设的检验计数本轮读到 `glyph_texture={attempts:0,matches:0}`，因为那次会话 lookup 未开启、待定正文行不存在，**该假设既未证实也未证伪**。下一轮的最小动作：确保 lookup 已开启（`lookup_gate` 四位全开）后重读这两个计数；若 `matches>0` 则改为按「字形自己的纹理→quad→sprite」建立几何，整条 compose 段对 HUNEX 不再适用；若仍为 0，则需从 `sprite_draw` 的调用者反查正文绘制路径。
- **[ ] ④ 未完成：attached 兜底路径卡在「宿主认领后 40ms 又撤回」的活锁（本轮定位到的最靠前边界）** — 强制一次重新求值后拿到确切原因 `attached=suspended/statusReason=geometryProviderPending`，且运行期日志复现出这个序列：
  ```
  17:52:11.401867  geometryAdmission=auto attachedReady=true   request=3 applied=2
  17:52:11.442122  geometryAdmission=auto attachedReady=false  request=4 applied=3
  17:52:11.452144  geometryAdmission=auto attachedReady=false  request=4 applied=4
  ```
  宿主先发出 attached 认领（`attachedReady=true`），**40 毫秒后又撤回**（`false`）。注入侧 registry 是在自己的轮询里 `Reconcile` 才授予 provider 的，等它下一拍看过来时认领已经没了，于是永远不会把 kind=4/id=11 判成 ready；而宿主的 `_evaluateAndActivate` 又在等这个 ready 才肯进 `activeAttached`——**两边互等，形成活锁**，状态永久停在 `geometryProviderPending`。
  已排除的可能：registry 的仲裁本身没问题（`BestReadyProviderIndexLocked` 在 auto 档下 `native < 0` 时会正常落到 attached，一个永远不 ready 的原生 provider **不会**挡住兜底）；`riskAccepted` 的透传也正确（`flutter_window.cpp` 的 `attachedConfigure` 取值无误，profile 里 `unsafeLeftClickAccepted:true`）。
  **待查**：`_evaluateAndActivate` 里哪条早退分支在认领之后又调了 `_setAttachedProviderClaim(false)`（候选：文本瞬时为空、profile 瞬时为 null、variant 瞬时取不到、或被新一轮 operation 抢占后的竞态）。这条**不是 HUNEX 专有**——`attached` 是所有引擎共用的兜底路径，修好它对六款游戏都有效。
- **[ ] ③ 未完成（已被 ④ 取代为更精确的定位）：attached 兜底路径被风险/护盾门挡住** — 本轮给驱动加的 `calibrate` 命令**已可用并验证**：提交后 profile 真的写出了 variant（`aspectRatio 1.777`、`bodyRect{0.149,0.442,0.678,0.134}`、`fontSizePerClientHeight 0.042`、`lineHeight 1.75`），且**跨进程重启后仍在**，状态一度从 `suspended` 变为 `waitingForBodyThread`，运行期日志也出现过一拍 `attachedReady=true`。但随后稳定停在 `needsRiskAcceptance`（`statusReason=null`），而此时 `profile.unsafeLeftClickAccepted=true`、文本在流、variant 与客户区 aspect 匹配。同时 `lookup_gate` 缺 `shield_ready` 位。按代码 `ShieldPermitsLookup() = !ShieldFaulted() && (ShieldVerified() || risk_accepted_)`，Dart 侧确实透传了 `riskAccepted:true`（`flutter_window.cpp` 的 `attachedConfigure` 取值正确），因此该状态的来源尚未定位——**这是下一轮该查的第一个边界**，因为它比几何更靠前，且一旦打通，attached 路径本身已实现全部四项目标行为（吞点击、Shift 悬浮、关弹窗不推进、带图与整句音频，见 BUG-2125）。
- **备注**：`engine-support.yaml` 的 `hunex_gge` 不提升，仍 `implemented_unverified`。真机链路当前状态：`process_found → helper_ready → ipc_ready → text_ready ✅ → text_thread_selected ✅（逐进程需重选，见 BUG-2133）→ 选中文本绑定 ✅ → 几何证据 ❌`。**用户目标「点击可查词制卡且不进入下一句」在 WoH 上尚未达成**，两条可能通路（原生几何 / attached 兜底）各自的下一步动作已列在 ② ③。
