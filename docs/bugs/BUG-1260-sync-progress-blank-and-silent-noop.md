## BUG-1260 · 同步进度条只有线没有字 + 零通道空转静默收尾
- **报告**：2026-07-31（用户：书架页顶部那条同步进度条什么文字都没有，「是同步还是没同步」）
- **真实性**：✅ 真 bug。截图那条线是 `SyncProgressBanner`（`hibiki/lib/src/sync/sync_progress_banner.dart:22` 的 `if (!syncing) return const SizedBox.shrink()` 保证只在 `syncInProgress == true` 时渲染），所以**确实有同步在飞**；但文字行挂在 `if (p != null)` 上（同文件 `:31`），`syncProgress` 为 null 时整行消失，只剩一条不确定进度条。

  根因是状态模型缺一层，不是 UI 忘了画。`syncInProgress` 是裸 bool，`syncProgress` 只在编排器真进入某个阶段后才有值，于是三种完全不同的现实在界面上**同形**：

  | 现实 | 以前的界面 |
  |---|---|
  | 合集 / 单本两条**天生没有阶段结构**的轻量路径在跑 | 一条线，零文字 |
  | 全量 sweep 还停在第一个阶段 tick 之前的准备段（等互斥锁 → 读自动同步开关 → 冷却判断 → `restoreAuth`/`isAuthenticated` 走网络） | 一条线，零文字 |
  | 所有通道 `isAuthenticated` 为 false 被 `continue` 跳过 —— **什么也没同步的纯空转** | 一条线，零文字，然后静默消失 |

  具体位置（修复前的 `hibiki/lib/src/sync/sync_auto_trigger.dart`）：四条路径都置 `syncInProgress.value = true`（`:289` 开机自动 sweep / `:385` 手动全量 / `:503` 合集轻量 / `:561` 单本），但只有前两条传 `onProgress` 上报阶段（`:318`、`:410`）；后两条从头到尾没有任何阶段回调。通道跳过点在 `:512`（合集）与 `:588`（单本），`_runSyncChannel` 的鉴权返回 null 在 `:190`。三处跳过都是静默 `continue`，跑完不留任何痕迹。

  顺带暴露的第二个缺陷：`_runCollectionsSync` 与 `_runAutoSync` 的 finally **漏清 `syncProgress`**（只有另两条路径清）。全量 sweep 结束时若还有别的同步在飞就不清，而那两条自己也不清，于是上一轮的阶段文字会残留到下一轮开头闪一下。四份手写的 notifier 维护正是这个不一致的来源。

- **[x] ① 已修复** — 补上缺失的那一层数据，而不是给进度条加特例分支：
  - 新增 `hibiki/lib/src/sync/sync_activity.dart`：`SyncActivityKind`（fullSweep / collections / singleBook）+ `SyncActivity`（带单本书名）+ `SyncOutcomeReason`（completed / noChannels / nothingToSync / autoDisabled / cooledDown / failed）+ `SyncRunOutcome`。每轮同步**先声明自己是谁，结束时必须留下结局**。
  - 四处手写的 `_activeSyncs++` / notifier 赋值 / finally 复位收敛成 `_beginSyncActivity` / `_endSyncActivity` 一对（`sync_auto_trigger.dart`），清理逻辑只剩一处——顺带修掉上面那个漏清 `syncProgress` 的不一致。
  - 每条路径统计实跑通道数 `channelsRun`，零通道 → `noChannels`；自动同步关闭 / 冷却跳过 / 书已不在库 各有独立 reason，不再静默收尾。
  - `SyncProgressBanner` 文字行两级取值：有阶段 tick 用 `syncProgressLine`，否则退化到 `syncActivityLine`；同步中不再可能出现零文字。设置页「立即同步」行再加第三级：空闲时显示上一轮的 `syncOutcomeLine`（尤其「没有可用的同步通道」＝上轮其实什么都没同步）。
  - 新增 10 个 i18n key（走 `hibiki/tool/i18n_sync.dart --add`，17 语言）。
  - 设置页「立即同步」的空闲副标题只认 `SyncActivityKind.fullSweep` 的结局：那一行讲的是「立即同步」这件事，拿后台单本 / 合集轻量同步的结局来填会答非所问。进行中的两段不做此过滤——它们回答的是「现在有没有东西在跑」，任何同步都算数（BUG-101 的教训）。
  - 提交 `5ce8cfdc4`、`b95dd88c9`。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_activity_visibility_test.dart`（15 例）：
  - 文案层：三种身份 / 六种结局两两不同且非空（断言语言无关信号，不绑措辞）；单本带书名/空书名/无书名三分支；**「跑完了」与「一条通道都没跑起来」文案必须不同**（本 bug 的核心）。
  - widget 层：同步中无阶段 tick（轻量路径 / 准备段）时 banner **仍有文字**；有 tick 时阶段行优先且进度确定；无同步时零高度。
  - 源码扫描守卫：`_beginSyncActivity(` / `_endSyncActivity(` 各恰好 5 处（1 定义 + 4 路径），`syncInProgress.value = true` / `_activeSyncs++` / `_activeSyncs--` / `if (_activeSyncs == 0)` 各恰好 1 处 —— 新增第五条同步路径若忘记登记身份会直接红。
  - **变异实测**：把合集路径改回手写 notifier → 守卫红 2 条；把 banner 文字行改回 `p != null ? ... : null` → widget 测试红 2 条；均已还原并复验全绿。
  - 全量 `test/sync`（1815 例）经 `flutter_test_failures.dart` 复跑：唯一失败是 `hibiki_library_host_service_books_test.dart` 的 `PathAccessException`（Windows 并发临时目录删除撞文件锁，errno 32），单独重跑该文件 26 例全过 → 既有环境 flaky，与本次改动无关（本次未碰 host service / book export）。
- **备注**：`SyncOutcomeReason.nothingToSync` 与 `noChannels` 刻意分开——一个是「连不上」，一个是「没东西可传」，混成一个词就是让状态撒谎。本次未改任何同步链路行为，只补状态与显示；用户原始现象（书架页那条线）属于上表第 1 或第 2 种，第 3 种（真空转）现在也能在设置页「立即同步」行读到。
