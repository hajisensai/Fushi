## BUG-1220 · Bangumi 同步链路全静默：看完了没反应且无处查看

- **报告**：2026-07-28（用户：看完了没反应，也不知道怎么查看这个 bangumi 数据）
- **真实性**：✅ 真 bug（可观测性缺陷，非链路断裂）

调用点其实都在，事件确实会进 outbox：
- `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:2876`（看完一集 → `recordVideoCompleted`）
- `hibiki/lib/src/pages/implementations/reader_hibiki/navigation.part.dart:1118`（阅读位置落盘 → `recordBookProgress`）
- `hibiki/lib/src/models/app_model.dart:4928`（游戏状态 → `recordGameStatus`）

根因是这条链路的**每一个失败点都不出声**，用户端零反馈，因此「同步没同步、断在哪一段」完全不可观测：

| 位置 | 静默行为 |
|---|---|
| `media_tracking_service.dart` `_ensureAutoBookMapping` / `_ensureAutoVideoMapping` / `_ensureAutoGameMapping` | 没令牌 → `return null`；标题匹配不唯一或相似度 < 0.92 → `return null`，且 `_autoMappingMissAt` 让同一条目 10 分钟内不再尝试 |
| `media_tracking_service.dart` `_sync` | 上报失败只 `ErrorLogService.log`，`markFailed` 退避 30s→最长 6h |
| `media_tracking_repository.dart` `markSucceeded` | 成功即 **删除** outbox 行——同步成功不留任何痕迹 |
| `media_tracking_repository.dart` `dueUpdates` | 按 `nextAttemptAt` 过滤，退避窗口内失败行连「待办」都不算 |

于是「已连接 + 零待办」与「从来没跑过同步」在 UI 上完全同形，而设置页只有一个 `Pending: 0`。

附带问题：设置页有一条「読書メーター 未公开个人写入 API」说明（`media_tracking_bookmeter_note`），全仓仅此一处 UI 引用、零实现代码——从未接入的东西不该出现在设置里。

- **[x] ① 已修复** — commit 见本分支
  1. 服务层新增可观测出口：`MediaTrackingStatus` / `MediaTrackingFailure` 快照 + `loadStatus()`；每轮同步结束落 `media_tracking_last_sync_*_v1` 偏好（区分「跑过零待办」与「从未跑过」），`statusRevision` 通知 UI；`connect()` 把「校验 + 落令牌 + 记账号名」收成一次原子操作，换令牌清旧账号名。
  2. `MediaTrackingRepository.allPending()`：**不**按 `nextAttemptAt` 过滤的展示侧查询，退避窗口里也能说出失败原因。它带展示上限（默认 50 行），因此「待发送 N 项」的计数仍走 `pendingCount()` 的 `COUNT(*)`，不能用列表长度（否则待办多于上限时少报，有回归测试守卫）。
  3. 首页 dashboard 新增「Bangumi 同步」卡（宽屏侧列顶部 / 窄屏继续区之后）：未连接→说明 + 连接入口；已连接→账号、上次同步、已关联数、待发送数、令牌被拒提示、已关联条目（点击开 bgm.tv 条目页）、立即同步 + 管理关联。零映射时明说「没有任何条目关联，所以看完不会有变化」。
     - 失败原因**挂在对应条目行上**（`MediaTrackingFailure.mappingId` + `mappingsProblemFirst` 把出问题的条目排到最前），不另开一段——首版写成独立「失败」段时 widget 测试立刻抓到同一条目标题出现两次，读起来像两个不同的东西。设置页同口径（错误进该行副标题）。
  4. 设置页删掉 bookmeter 死文案（含 17 语言 i18n key，走 `i18n_sync --remove`），并复用同一状态快照显示上次同步/失败原因；`_kindLabel`/`_modeLabel` 抽成共享 `media_tracking_labels.dart`。
- **[x] ② 已加自动化测试** — `hibiki/test/media/tracking/media_tracking_service_test.dart`（group「可见状态快照（BUG-1220）」7 项）
  - 从未同步 vs 同步过零待办可区分
  - 未配置令牌时不谎报「已同步过」
  - 失败待办在退避窗口内仍带原因外显（`dueUpdates` 为空而 `loadStatus().failures` 有值）
  - 令牌被拒 → `unauthorized`
  - `connect` 记住账号名 / 换令牌清旧账号
  - bookChapter 伴随映射不作为独立条目外显
  - 同步结束自增 `statusRevision`
- **备注**：本条只解决可观测性与死文案。自动映射的高置信度门槛（exact 唯一 / score ≥ 0.92）**未放宽**——宁可不建映射也不把进度写到别人的条目上；现在这种情况会在首页明说「没关联」并指向手工关联入口。UI 部分需真机目视验收。
