## BUG-1272 · Bangumi 刮削单次请求无重试，链路丢连接直接失败

- **报告**：2026-07-31（用户：封面刮削弹窗报「搜索失败，没能从封面源取到有效响应」，怀疑被 Bangumi 限流；但浏览器打开 bgm.tv 官网正常，网络并不差）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/metadata/bangumi_api_client.dart:169`（原 `_run`：一次请求 = 一次成败，传输失败直接抛，无任何重试）

### 定位过程（先证伪「限流」）

用户展开弹窗详情拿到的原文是 `ScrapeNetworkException: Bangumi search request timed out` —— **timed out，不是 429/403**。逐条实测：

| 实验 | 结果 | 结论 |
|---|---|---|
| 带 `hibiki-reader/scraper` UA 请求 | `200` | UA 硬编码**生效** |
| 不带 UA 请求 | 稳定 `403 Forbidden` | Bangumi 拒裸 UA，但那是 403 不是超时 |
| 连打 35 次（GET+POST 搜索） | **一次 429 都没有**，无 `Retry-After` | 未触发限流；且 galgame 侧有令牌桶、视频自动刮削串行+600ms |
| 直连 `api.bgm.tv` 20 次 | **成功 12 / 失败 8** | 失败率约 40% |
| 同样请求经代理 12 次 | 12/12 成功 | 链路问题，非服务端 |
| 超时放宽到 30s 再测 15 次 | 成功的 **0.5~0.8s** 返回；失败的**全部卡在 21.0s** | 见下 |

**关键数据是最后一行**：失败一律停在 21 秒（Windows 内核 TCP SYN 重传放弃时间），而不是我设的 30 秒。也就是说要么 0.8 秒回来，要么 SYN 石沉大海——**中间不存在「再多等一会儿就能成」的区间**。所以「把超时调长」对这个失败模式完全无效，只会让用户多盯着转圈。

本机链路环境（FlClash TUN + fake-ip：`api.bgm.tv` 被解析成 `198.18.6.4`）会放大丢连接率，但这不是个例——本 app 用户群普遍挂代理，且任何弱网都有同类表现。

**浏览器为什么「正常」**：它连接复用 + 失败自动重连，把同样的丢连接悄悄补掉了。app 是单发单收，一次丢包整条报废。**根因是这条链路没有任何容错，不是网差。**

### ① 修复

- 新增 `hibiki/lib/src/media/metadata/transport_retry.dart` —— `runWithTransportRetry`，默认 3 次尝试、退避 `400ms * n`，失败时**原样抛最后一次异常与堆栈**，调用方的异常映射/文案零改动。
- `bangumi_api_client.dart`：`_run` 用重试包住 `_gate(send)`，**包在 gate 外层**——每次重试都重新过一遍限流器，否则重试会绕过令牌桶，把链路抖动变成对公益 API 的连打。单次超时 `15s → 8s`（`kBangumiRequestTimeout`）：这个值不是「等多久算慢」，而是「多快认定连接已死、该换一条」。一处改动覆盖视频刮削 / 书籍刮削 / galgame 元数据三域。
- `cover_downloader.dart`：海报下载同一根因，同样加重试（幂等 GET，重放安全）；30s 单次超时保留——海报是几百 KB 响应体，不能按建连成败取值。
- `bangumi_adapter.dart`：默认超时改为引用共享常量。

**正确性前提（写进 `transport_retry.dart` 文件头）**：`package:http` 对非 2xx **不抛异常**，因此在「发一次请求」这层捕获到异常 ⟺ 传输失败。403 / 404 / 429 这类服务端已明确回话的结果根本走不到重试分支——尤其 429，重放只会加重限流。**写操作（收藏、进度上报）不得套用本函数。**

### ② 自动化测试

`hibiki/test/media/metadata/transport_retry_test.dart`（13 例，全绿）：

- 正向：首次失败→重试成功、连失两次→第三次成功、超时同样重试、退避按 `backoff * n` 递增、`maxAttempts=1` 退回旧行为、用尽次数仍抛 `BangumiTransportException`（异常契约不变）。
- **负向（关键）**：`403` / `429` / `404` 各断言**只发 1 次**——服务端已回话的结果绝不能被重放。
- 限流不变量：`重试穿过限流 gate` 断言 gate 被调用次数 == 尝试次数。

**变异实测**（按仓库纪律，防假绿）：把 `kTransportMaxAttempts` 改 3→1，**4 个测试立刻转红**；还原后用 `diff` 校验与备份逐字节一致（未用 `git checkout --`，避免抹掉未提交修改）。

相邻测试 `test/media/metadata/ test/media/video/scraper/ test/mining/metadata/` 共 **344 例全绿**。其中 `book_cover_scrape_dialog_test.dart` 的「搜索失败显示错误行」需同步更新：它原本让 mock **只失败一次**来测手动重试，而自动重试现在会把这种情况直接救回来、错误行不再出现（**这正是本次修复的效果**）；改为打满一整轮尝试才判失败，手动重试从下一轮开始成功，测试原意不变。

### 备注 / 未覆盖范围

- **同步侧（`media/tracking/bangumi_api_client.dart`）未纳入**：其 `createCollection` / `patchCollection` / `markEpisodesDone` 是写操作，自动重放需要先做幂等性分析，且已有 outbox 退避兜底。其只读的 `getMe` / `getSubject` / `getCollection` 会被同一根因击中（点「连接并验证」可能失败），值得后续单独处理。
- `vndb_adapter.dart` 同样是单次请求无重试，属另一站点，本轮未动。
- 用户可见文案仍是「没能从封面源取到有效响应」，对**超时**而言不够准确（听起来像服务端返回了坏数据）；BUG-1219 的详情展开已能露出真因，文案本身的收敛留待后续。
