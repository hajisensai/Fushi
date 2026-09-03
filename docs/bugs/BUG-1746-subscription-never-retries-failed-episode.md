## BUG-1746 · 订阅只看 jobId 存在就跳过，故障集永久卡死不再下载
- **报告**：2026-08-19（用户：我是订阅的从第三集下载开始，它只给我下载了 5、6、7 集）
- **真实性**：✅ 真 bug —— 根因 `fushi/lib/src/media/video/download/video_download_subscription_service.dart` 的入队去重判据（两处副本）
- **[x] ① 已修复** — 判据收成 `videoDownloadJobLifecycleStillCounts` / `subscriptionItemStillClaimed` 单一真相源，按任务真实下场决定要不要重派
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_subscription_service_test.dart` 的 `BUG-1746 订阅重试判据` group（真行为测试，走内存 DB + 真 service，已双向变异实测）
- **备注**：用户生产库实证见下

### 用户生产库实证（2026-08-19 取，只读副本）

唯一一条订阅（Re:Zero 4th Season，`start_after_episode=1`）的 13 条 `video_download_subscription_items`
与 `video_download_jobs` 关联后：

| 集 | items.status | job.lifecycle | 备注 |
|---|---|---|---|
| ep01–02 | queued | **needsAttention** | `The built-in download engine runtime is missing` |
| ep03–08 | queued | **cancelled** | 08-12 23:53:58→23:54:06 连续取消 |
| ep09–12 | queued | completed | |
| ep13 | queued | active | 下载中 9% |

**起始集数逻辑本身是对的**（13 集全部被正确识别并建了条目，集号解析没出错）。用户看到的
「只下了中间几集」是这 8 集入队后再没被重试过。

### 根因：把「派过任务」当成了「任务成功了」

```dart
// 旧判据（去重）
if (existing != null &&
    (existing.jobId != null || status in {queued, processed, skipped})) {
  continue;   // ← 完全不看那个 job 现在什么状态
}
// 旧判据（入队，第二处副本）
if (item.jobId != null) return true;
```

`jobId` 只说明**曾经派过任务**，不说明任务成功了。任务被取消或失败之后 jobId 依然留在订阅
条目上，于是每轮轮询都 `continue` / `return true`，那一集再也不会被下载。

这是本仓反复出现的形状：**两件事编成一个字段**（对照 `anime_download_service` 的
`plan.importedEarly` 把「已入库」和「内容已定稿」编成一个 bool）。

三处同一判据的副本让它更难发现：
1. `_checkSubscription` 的去重 `existing.jobId != null`
2. `_enqueueItem` 开头的 `if (item.jobId != null) return true;`
3. `_enqueueItem` 里复用既有任务的循环——它按 fingerprint+provider+resourceId 匹配，
   **会把一个已经 failed 的旧任务重新绑回条目**，放开前两处后这里会让该集在
   「重派 → 立刻又撞上失败任务」之间空转。

### 修复

判据收成两个纯函数（`video_download_subscription_service.dart` 顶层，可直接单测）：

- `videoDownloadJobLifecycleStillCounts(String? lifecycle)`
- `subscriptionItemStillClaimed(item, lifecycleByJobId)`

分界线按**是谁决定不下的**划，而不是按「成功/失败」划：

| lifecycle | 还算数？ | 理由 |
|---|---|---|
| `active` / `completed` | ✅ | 显然有人在管 |
| `cancelled` | ✅ | 用户明确说「不要这一集」。自动补回来的话用户永远取消不掉 |
| `failed` / `needsAttention` | ❌ | 系统故障（实测例：内置下载引擎运行时缺失）。故障排除后本该继续 |
| 任务记录不存在（null） | ❌ | 没有任何东西在管这一集 |

`_enqueueItem` 里那份重复判据**直接删掉**（而不是也改一遍）——判据只留一处，注释写明前置
条件由调用方保证。

### 补正（PR#915 合入后）：重派 = 恢复既有任务，不是克隆一份

第一版实现让复用循环对 failed / needsAttention 的旧任务 `continue`，于是落到
`pipeline.enqueue`——而 `enqueue` 每次调用都 `generateVideoDownloadInstallationId()`
生成全新 jobId，`VideoDownloadJobs` 对 (fingerprint, resourceProvider, selectedResourceId)
/ torrentHash **没有任何唯一约束**。生产 `checkInterval` 是 15 分钟，一个持续性故障
（实测例：内置下载引擎运行时缺失）等于**每集每天往下载面板堆约 96 条死任务行**，永不收敛；
`needsAttention` 更糟——它的定义是「需要用户处理的**可恢复**状态」，`backendTaskId` 还在、
后端 torrent 可能仍在跑，再派一份同 magnet 的任务会让两条持久工作流指向同一个 infohash，
各自 organize/import。原来那道 `jobId != null` 恰好也是唯一的防风暴闸门，拆掉时没补替代。

现在的形状：

- `_enqueueItem` 匹配到既有任务时，`failed` / `needsAttention` 走
  `FushiDatabase.reviveVideoDownloadJobForSubscription`（`database_video_domain.part.dart`）
  把**同一条**任务放回 `active`，`stage` / `backendTaskId` / `torrentHash` 一律保留，
  不倒回 enqueue，也不新建任务行。
- 上限的账本就是任务自己的 `attemptCount`，**不加列**（内存计数进程重启就归零，等于没有
  上限；加列会牵进已发布 schema 的迁移阶梯）。`maxAttempts` 是流水线进程内退避的预算，
  `attemptCount - maxAttempts` 就是自动重派额外借走的格数；借满
  `kVideoDownloadSubscriptionAutoRetryBudget`（3）之后任务原样停在 `failed` /
  `needsAttention` 等用户处理。
- 面板的重试按钮走 `retryVideoDownloadJobByUser`，它把 `attemptCount` 清零——于是人工干预
  天然地把自动预算也一起复位，不需要第二处状态。

### 补正：`_managedEpisodeKeys` 里 needsAttention 也要排除

原实现只排除 `cancelled` / `failed`，**保留 needsAttention**。于是一条卡在 needsAttention、
但文件已经下好的任务，会在文件级把自己的订阅条目判成「已经有人管」而走 `_markItemSkipped`
——那是个**终态写入**，此后 `subscriptionItemStillClaimed` 永远返回 true，这一集被静默判了
永久跳过。现在这段只认 `active` / `completed`；真正已入库的集数由 collection items 那一段
兜住，不受影响。（下面那句「_managedEpisodeKeys 保持不动」是第一版的说法，已被本补正取代。）

`_managedEpisodeKeys`（文件级「这一集是否已经在库里」）保持不动：它排除 cancelled/failed
但保留 needsAttention 是对的，因为一个 needsAttention 的任务可能已经把文件下好了。两者
语义不同、层级不同，顺序上先判任务级再判文件级，自洽。

### 测试期间发现的假绿（记录下来防止后人重蹈）

新测试第一版「不重复入队」的用例是**假绿**：`_drain()` 只认领**已到期**的订阅
（`claimNextVideoDownloadSubscription(nowAt:)`），第一轮跑完 `nextCheckAt = 当前 + checkInterval`。
测试里 `now` 固定，第二轮 `checkNow()` 根本认领不到订阅、整轮空转——断言「没有重复入队」
于是恒真，测的是「压根没跑」而不是「跑了但正确地没派」。修法是让第二轮的 service 时钟
前进到 nextCheckAt 之后（`runRound(atMs:)`）。

### 变异实测

- 判据退回「派过就算数」（`stillCounts` 恒 true）→ needsAttention / failed 两条用例必红 ✅
- 判据把 cancelled 也算作可重试 → 「用户取消不会被自动补回来」用例必红 ✅
- 两次还原后源文件 sha256 逐字节一致 ✅

### 未修（另立）

订阅面板不显示条目级状态，用户无从看出「这几集失败了」。`items.status` 也确实不跟随
job lifecycle（13 条全停在 `queued`），但它没有 UI 消费者、只用于去重，本次不动它——
真正该做的是面板上给订阅条目一个可见的失败/取消态，属功能新增而非本 bug 范围。
