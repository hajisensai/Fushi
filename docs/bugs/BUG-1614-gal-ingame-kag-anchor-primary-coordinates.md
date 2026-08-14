## BUG-1614 · 游戏内查词把 KAG 消息锚点误判为脱离 primary 导致字形恒不命中
- **报告**：2026-08-12（用户：）
- **真实性**：✅ 真 bug（沿修复前的 KAG 锚点选择与光标坐标换算路径核实）

### 根因

问题由两处同属「把几何相似误当对象身份」的错误叠加而成：

1. 修复前的 `native/galgame_hook/hook/adapters/kirikiri_adapter.inc:878-899` 要求文字锚点的
   `parent` 链必须经过 `kag.primaryLayer`。但 KAG 的 `back.messages[]` 可以位于 primary 的
   **兄弟子树**；它与 primary 共享更上层根节点，却不会经过 primary。本来合法的消息层因此被记为
   `kLookupDiagLayerDetached`，其偏移也不是严格的 primary 坐标，光标命中会稳定失败。
2. 修复前同文件 `:1379-1401` 在 fore/back 两页里按 `width/height` 找第一个同尺寸消息层。
   同页可以有多个同尺寸 message layer，且 fore/back 是逻辑消息层的双缓冲页；这条规则会把正在
   绘制的宿主映射到另一页或闲置的 `top=0` 层。后续即使坐标公式本身正确，起点也已经属于错误对象。

### 修复

- `fushiLookupComputeOffset` 分别以最多 32 层的有界遍历累加消息层与 primary 到共同根的绝对
  图层坐标；只有根对象相同才发布两者差值。兄弟子树因此可以严格换算，异根与父链环仍 fail closed。
- 锚点先从 `drawCh` 的真实宿主得到 `hostPage`，再把 `kag.currentNum` 投影到该宿主页的
  `messages[currentNum]`。旧/定制 KAG 没有可用 `currentNum` 时，才用 `kag.current` 的对象身份
  在 fore/back 中找到逻辑下标并投影回宿主页；不再用尺寸、名字或跨页「第一个」认领身份。
- primary 图像坐标（卡片落点）与 primary 图层坐标（高亮/命中）继续分开，避免把
  `imageLeft/imageTop` 混进父链坐标。
- 2026-08-13 的同进程运行追踪又确认了一处同源生命周期错误：页交换后，字形坐标与整行包围盒
  仍然正确，却被 `z=V` 可见性门拒绝。原因是投影后的 KAG message anchor 同时被拿来判可见；
  它在淡入/页交换期间可以短暂 hidden，而实际 `drawCh` 宿主仍在屏上。记录现已拆成
  `layer`（只做共同根坐标换算）和 `visibleHost`（真实绘制宿主）。有声女主的口型/表情会让
  同一句反复进入 TextRender；修复前每轮 Capture 都先清绑定，某一帧没有完整 drawCh candidate
  就会永久丢掉上一帧的正确坐标。现在完整 candidate（可见 `drawCh` 宿主、字符原点跨度匹配、
  可投影的 KAG `page/index`）是唯一 slot adoption 边界：同句瞬时缺候选/异常保留已提交 binding；
  无 candidate 的新句只清当前 renderer，不推进 slot、也不 dismiss；同 slot 的完整异句 candidate
  才在同一提交路径退休 peer、推进 generation 并发布新的 active entry。
- Entry registry 与 slot ledger 的有界 LRU 都改为 inactive-first；`ClearEntryBinding` 在摘除
  `activeEntry` 时只把旧高亮矩形合并进有界的 pending erase，不在 registry/slot 事务中调用
  游戏 Layer。`fillRect/visible/update` 与换句收卡延后到 render/done/Probe/Apply 的外层叶子，
  并用 reentry guard 串行 flush，避免表情重绘在账本提交一半时同步重入。BindGroups 也从固定 FIFO 改为
  invalid-first / 最旧 clock 淘汰，并用字符**原点**跨度匹配宿主；向下换行不再误判为新绘制序列，
  避免姓名层、正文层和历史多行范围互相污染。
- renderer 退休时记录 `retiredRenderEpoch = renderEpoch`；只有新的 `TextRender.render` 会递增
  epoch，`done` 不递增。因此已退休旧 entry 同一 render 世代迟到的 `done` 不能把旧词重新提交，
  而 fresh renderer 在 `done` 才凑齐完整字符时仍可正常提交。无 candidate 的已关联 renderer 异句
  只冻结自己确实拥有的 slot active；无法归属的姓名/表情临时 renderer 不会清掉正文 slot。
- registry 的 8 个 entry 会被 LRU 复用，因此退休 epoch 不能只靠 entry 对象地址。每次 renderer
  绑定现在都有单调 `rendererLease`；`render` 在调用游戏原函数前固定 lease/epoch，Capture 在
  `getCharacters` 前后及 adoption/发布前复核。`done` 只用 `FindEntry`，绝不为已淘汰 renderer
  重新分配 entry；slot 淘汰也先封存 active 的 render epoch。这样 registry absence 本身就是
  隐式 tombstone，不增加永久 renderer 引用，也不会在 churn 超过固定 tombstone 数量后漏掉旧回调。
- 同一 entry 同句的弱 candidate 不能把严格 current identity 降级；不同 renderer 的更强
  strict-current candidate 可以立即接管较弱 active，同强/更弱 candidate 只有在旧 active 已不可用
  时才接管，避免短命宿主抢走稳定 binding，也避免失效强 entry 永久卡住表情切换后的新 renderer。
- `kag.current` 能严格解析到捕获时同一页、同一下标时，entry 保存它的对象身份；Probe 身份仍相同
  时允许绕过随后 hidden 的短命 `visibleHost`，身份明确变化则拒绝旧 entry。新 candidate 提交时
  原子退休相同 `(anchorPage, anchorIndex)` 的旧 renderer 记录；姓名层 `ai=1` 与正文 `ai=0`
  不会互相退休；当另一个共存 slot 暂时成为 global current 时，本 entry 回退检查自己的
  `visibleHost`，而不是被一并判过期。
- 2026-08-13 最终重构建后的首轮真机又暴露了更早的一次性安装竞态：TJS bootstrap 只等待
  `global.kag`，而 `TextRender.render/done/drawCh` 仅在同一帧做一次静默 `typeof` 判断。早注入时
  `kag` 已建立但 `textrender.dll` 尚未发布完整类面，输入 hook 仍会安装并永久移除 bootstrap，造成
  整局 `registry=0`。目标进程直接证据为 v15 `lookup_diag=0x41`（SensorInstalled +
  ExpressionReady，但无 GeometryObserved/SensorFault）、四次 `lookup.coord` 都为 `N=0`，同时 Luna
  文本、选中线程、helper 与 IPC 均正常。bootstrap 现在在任何 lookup 状态初始化之前同时等待
  `kag` 与 `TextRender` 三个方法完整就绪；未就绪只保留 continuous handler，成功安装三条 wrapper
  后才退休。异常安装路径仍单独 fail closed，避免半包装状态下重入递归。
- **尚未由运行时证明的边界**：同一个复用 MessageLayer 上真实发生 `A → B → A`，与旧 A 的完整
  candidate 迟到回调，在当前可观测量里没有引擎提供的消息内容 generation。实现不再用 pending 或
  “两次 render”计数猜世代；`renderEpoch` 只区分已退休 entry 的同世代迟到 `done` 与真正新 render。
  仍需新 DLL 的长时有声对话复测确认没有更晚的完整旧 render 回调把 slot 倒回旧词。

- **[x] ① 已修复** — 见本文件所在提交；实现集中在
  `native/galgame_hook/hook/adapters/kirikiri_adapter.inc` 的 entry/slot 生命周期、Capture/BindOrigin、
  Probe 与 TextRender 包装段（避免用随编辑漂移的行号描述正确性）。
- **[x] ② 已加自动化测试** —
  `native/galgame_hook/tests/kirikiri_lookup_source_guard_test.py`：共同根换算守卫、
  `hostPage → currentNum → 对象 identity 兜底` 锚点优先级守卫，以及完整 candidate 才 adoption、
  inactive-first LRU、同句保留、定向 owned-active 清理、退休 epoch、同 entry/跨 renderer strength、
  Probe active/generation/共存 current 语义与 original-first sidecar 包装的合成 fixture/逐项变异红例。
- **备注**：按用户要求本轮不运行自动化测试。修复前 Windows x86 helper
  `3EB6FF873D92E877AF5D0AD01EC04313110810EAD1CC1FD2370BE8131FF240DA`
  在目标游戏 PID `7564` 取得的同进程追踪已证明 bbox/offset/anchor 全成立而最终为 `z=V`；上述
  有声重绘生命周期补丁及新增测试均未运行/未构建进该进程。必须用新 DLL 复走“同一句口型/表情
  切换前后 + 连续多句与 A/B/A 回访”才能把修复从静态闭环升级为运行时已证。
