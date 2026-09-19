# AniDB / TMDB 链路对齐 Shoko：逐项对照（2026-09-19）

参考实现：`references/ShokoServer`（git submodule，只读）。本表回答两个问题：Shoko 在这件事上怎么做、本仓现在怎么做、差异为什么存在。状态：✅ 已对齐 / 🟡 部分对齐或本仓变体 / ❌ 有意不做 / — 不适用。

## 1. AniDB UDP：超时、封禁、退避

| # | 项 | Shoko | 本仓（`packages/fushi_engine/lib/media/video/metadata/anidb_udp_file_client.dart`） | 状态 |
|---|---|---|---|---|
| 1.1 | 收发超时 | `AniDBSocketHandler.cs:22-23` 收发各 30 s | `AnidbUdpConfig.timeout` 30 s（原 15 s） | ✅ |
| 1.2 | 无应答重试 | `AniDBUDPConnectionHandler.cs:312-343` Polly `Retry(1)`，重试前做一次网络探测；第二次仍超时按 `SocketException` 抛，**不标 ban** | 同 tag 原样重发一次；第二次仍无应答抛 `timeout`，不标 ban | ✅（网络探测见 1.9） |
| 1.3 | 超时之后 | 队列层 `RetryPolicy.cs:10-12`：30 s × 2ⁿ，上限 1 h，最多 8 次 | 进程级指数退避 30 s × 2ⁿ⁻¹，封顶 10 min；窗口内新请求报 `backoff`（不发包）；任何一条应答清零 | 🟡 封顶 10 min 而非 1 h（sweep 是前台交互，等 1 h 没意义；真被静默 ban 时每 10 min 探一次也只是两个包） |
| 1.4 | 什么算 ban | `UDPRequest.cs:102-149`：只有 `555 BANNED` 置 `IsBanned`；任何其它响应码把它写回 false；`SendInternal` 里「全 0 应答」也当 ban | 只有 555 / 504 置封禁；任何应答清超时退避 | 🟡 「全 0 应答」在 Dart 里是 malformedResponse（不封禁）：AniDB 从不发空报文，Shoko 那条是 .NET `ReceiveFrom` 的产物 |
| 1.5 | ban 时长 | `AniDBUDPConnectionHandler.cs:47` `BanTimerResetLength` 1.5 h；再次 ban 重启计时 | 555/504 → 90 min，重复 `_block` 覆盖终点 | ✅ |
| 1.6 | 6xx 服务端「稍后再试」 | 600/601/602/604 → `StartBackoffTimer(300)`，只停 ping/logout 定时器，**不阻塞发送** | 600/601/602/604 → `maintenance`，5 min 内新请求直接报维护（不发包） | 🟡 本仓选择阻塞：sweep 里没有独立队列可挂起，继续发只会让每个文件多等 30 s×2 |
| 1.7 | ban / 退避期间新请求 | `Send()` 立即抛 `AniDBBannedException`，`BaseJob` 转 `RequeueJobException`（不计重试、不退避），acquisition filter 整体挂起 UDP job | 立即抛（`banned` / `maintenance` / `backoff`），协调器把该文件记警告跳过；下一次 sweep 由 `_hashBacklog` 把没身份的文件重新排队 | 🟡 等价于「requeue 到下一轮 sweep」 |
| 1.8 | 节流 | `UDPRateLimiter.cs:98-164`：基准 2 s；连续活跃 >10 s 后 6 s；空闲 >120 s 重置；全局单锁串行 | `_rateLimitDelayMs`：2 s / >10 s 活跃后 6 s / 120 s 空闲重置；全进程 `_sendTail` 串行 | ✅（Shoko 额外 +50 ms 抖动没抄） |
| 1.9 | 发送前网络可达性 | `_connectivityService.NetworkAvailability < PartialInternet` → 直接抛 HostUnreachable；`CheckNetworkAvailabilityJob` 30 min 一次 | 无独立连通性服务；socket send 失败 → `network`（不封禁、清会话） | ❌ 本仓没有全局连通性探针；UDP 发送失败已经是同一信号 |
| 1.10 | 505 | `IsInvalidSession = true` → `NotLoggedInException` → 队列重登 | 505 与 501/506 同路：清会话、重新 AUTH、同一条 FILE 重发一次 | ✅ |
| 1.11 | 506 / 598 | `ClearSession()` → 下次请求自动重登 | 506 同上；598 归 `session` 并清会话 | ✅ |
| 1.12 | ban 时清会话 | `IsBanned` setter 清 `SessionID` / `_isLoggedOn` | 555/504 时 `_session = null` | ✅ |
| 1.13 | 500 LOGIN FAILED | `IsLoginFailed`，只有重新 `Init()` 才恢复 | `_terminalFailure`：本客户端永久失败，换配置新建客户端才重试 | ✅ |
| 1.14 | 登录失败重试 | `Login()` 失败非 ban/非密码错 → `ForceLogout` 再登；`UnexpectedResponse` → 改 Unicode 再登；登录超时 → 重建 socket 再登 | AUTH 双超时 → 关掉旧 socket、重建传输、再 AUTH 一次（第一轮登录超时不进退避，第二轮才退避）；本仓 AUTH 恒 `enc=UTF-8` 没有非 Unicode 模式 | ✅（「改编码再登」不适用：本仓从未用非 UTF-8） |
| 1.15 | 会话保活 PING | `UDPPingFrequency` 60 s | 不 PING；501/506 时重登 | ❌ 会话只在一批 sweep 内使用，AniDB 35 min 空闲过期由 1.11 兜底；PING 只为 NAT 保活，这里不需要 |
| 1.16 | 空闲登出 | 5 min 无业务请求自动 LOGOUT（`AniDBUDPConnectionHandler.cs:33`） | `idleLogout` 5 min：空闲到点发 LOGOUT 清会话，下一条请求重新 AUTH | ✅ |
| 1.17 | 请求编码 | HTML 实体 | HTML 实体 | ✅（本来就是） |

## 2. AniDB FILE 结果与重试

| # | 项 | Shoko | 本仓 | 状态 |
|---|---|---|---|---|
| 2.1 | 320 NO SUCH FILE | `RequestGetFile.cs:248-249` 返回 null（非异常）；provider 层把 Banned/NotLoggedIn 也吞成 null | 320 → `notFound`，批内 1 h 去重；持久层落 320 行 7 天复查 | ✅ |
| 2.2 | 未识别文件重试 | `CheckAniDBFileUpdatesJob`：按 `File_UpdateFrequency`（默认每日）重扫，尝试 ≤ `MaxAutoScanAttemptsPerFile`（默认 15） | `anidb_file_identities.miss_attempts`（schema v108）：320 行每日复查，连续 15 次仍未收录不再自动问（换内容即新键重来）；识别成功归零。复查由 sweep 触发（用户 / 扫描后自动），没有独立每日调度器 | ✅（触发方式不同：Shoko 有 cron 式 job，本仓靠 sweep） |
| 2.3 | 已识别但资料不全的复查 | `ScanForMissingReleaseInfoJob` 24 h + `RescanDelayHours [6h,1d,3d,1w,90d]` 最多 5 次 | — | — 本仓只取文件身份（fid/aid/eid/epno/标题），没有「资料不全」这一维度 |
| 2.4 | 成功结果缓存 | 内存 30 min | 内存永久（客户端寿命）+ 持久层 `(ed2k,file_size)` 行 | ✅ 更强 |

## 3. AniDB 作品 → TMDB 剧

| # | 项 | Shoko | 本仓 | 状态 |
|---|---|---|---|---|
| 3.1 | 找 TMDB 剧 | `TmdbSearchService.cs:449-624`：沿 Prequel 链回溯到根作品的标题搜索 + 自身标题择优，六种查询变体，按「集数最接近的季」和 E1 播出日 ±3 天打分 | Fribb `anime-lists` 显式 `themoviedb_id` 直接换 id（`_tmdbLookupFromMapping`）；映射缺失才按标题搜索：候选 = 自身标题 + 别名 + **MAL Prequel 链根作品标题**（`VideoMetadataRelationsProvider`，≤8 跳）；续作（根 ≠ 自己）**不带年份**搜（cour 年份晚于剧首播，±1 年的门会挡掉整部剧）；仍歧义（≤5 候选）按「集数最接近的非特典季 + 该季首播与 MAL 首播 ±3 天」打分，唯一赢家才用 | ✅（多了 Fribb 显式映射在前；Shoko 的去副标题/去续作后缀变体由本仓 resolver 的标题归一化覆盖） |
| 3.2 | 季/集偏移 | **无偏移算术**：`TmdbLinkingService.cs` 里没有 offset | 有：Fribb `season.{tvdb,tmdb}` + `episode_offset.{tvdb,tmdb}` 用来解析 `Season NN` 目录与切片补集（BUG-2593） | 🟡 有意保留：偏移是映射表**显式**数据，不是跨站推断；逐集匹配（第 4 节）作为没偏移时的兜底 |

## 4. 集级匹配（`TmdbLinkingService.MatchAnidbToTmdbEpisodes`）

本仓移植：`packages/fushi_engine/lib/media/video/metadata/tmdb_episode_matcher.dart`，两个用法在 `video_metadata_merge.dart`（`enrichSeasonsByTmdbEpisodeMatch` / `fillEmptySeasonsFromEpisodeTitles`），接线在 `video_source_scrape_coordinator.dart` `_resolveWork`。

| # | 项 | Shoko | 本仓 | 状态 |
|---|---|---|---|---|
| 4.1 | 来源集 | AniDB 集（HTTP 资料：多语言标题 + 播出日） | ① MAL cour 分集（Jikan `aired` + 按资料语言选的标题）；② 本地文件 AniDB 身份里的三语集标题（**无播出日**） | 🟡 生产 registry 不装配 AniDB HTTP 资料链（CLAUDE.md 规则），拿不到 AniDB 集播出日；② 只能靠标题 |
| 4.2 | 候选池 | 全部非特典季的 TMDB 集，特典单独一池 | 全部非特典季；本作品其它季已用掉的 TMDB 集（按 tmdb 集 id）不进池 | ✅（特典池未做：本仓来源集只有正片） |
| 4.3 | 四轮接受 | Pass1 `DateAndTitle`；Pass2 `Title`；Pass3 除 `FirstAvailable/None`；Pass4 全部 | 同 | ✅ |
| 4.4 | 定季锁定 | 第二轮起候选池收窄到已链接的季（+S0） | 同（无 S0） | ✅ |
| 4.5 | 单集评分链 | 精确标题（子串 + 长度差 <3）→ 近似标题（距离 <0.2、长度差 <6）→ 播出日 ±2 天 → 任意模糊标题 → 最近播出日 ≤120 天且限锚定季 → FirstAvailable | 同：精确 = 归一化后相等/互为子串且长度差 <3；近似 = `TitleNormalizer.similarity` ≥0.8 且长度差 <6 | ✅ 相似度算法不同（Shoko 拉丁编辑距离 / 非拉丁子串；本仓 Dice ∨ Levenshtein，带全半角/繁简折叠） |
| 4.6 | FirstAvailable | 池中第一个，Pass4 无条件接受（一集都没对上也会从 S1E1 顺序填，交用户核对） | 只在已有更强链接锁定季之后接受，且只取**前一条链接之后**的第一个未用候选 | 🟡 有意：本仓没有 Shoko 的链接核对界面，宁可留空交人工；「前一条之后」避免 cour 中段一集没对上被填成该季第 1 集 |
| 4.7 | 弱评级保序 | `ReconcileEpisodeOrderInversions`：相邻弱链接倒置则交换 | 同 | ✅ |
| 4.8 | 标题语言 | AniDB 英文集名（跳过 `Episode N`）→ 原语；TMDB en-US + 原语 | 来源多语言标题全部参与；TMDB 集除资料语言外再按季拉 **en-US + 剧原语**集名（`VideoMetadataEpisodeAliasProvider`，只在真要逐集匹配时拉、独立缓存键、与资料语言同主子标签的跳过） | ✅ |
| 4.9 | 多 cour 共用一季 | `ConsiderExistingOtherLinks`（默认关）打开才剔除其它 AniDB 作品已占用的 TMDB 集 | 同作品内其它季已用集恒剔除；跨作品不剔除 | 🟡 |
| 4.10 | 用户手动链接 | `UserVerified` 自动重匹配时保留 | 手动指定作品身份（confirmedLookup）保留；没有集级手动链接 | — |

## 5. Jikan（MAL）

Shoko 不用 Jikan/MAL，无对照。本仓：429 按 `Retry-After` 冷却后就地重试 2 次、间隔 1.1 s（BUG-2595）。

## 6. 仍存差异（第三轮之后）

有意保留（Shoko 方向对刮削没有好处或不适用）：
- 1.3 超时退避封顶 10 min（Shoko 1 h）；1.6 6xx 阻塞 5 min（Shoko 不阻塞）；4.6 `firstAvailable` 只在锁定季后、前一条链接之后接受（Shoko 从 S1E1 顺序填）；3.2 保留 Fribb 季号 + 集偏移（Shoko 无偏移）；1.4「全 0 应答 = ban」是 .NET 产物。
- 1.9 发送前网络预检：本仓没有全局连通性服务，`connect` 里的 DNS 查询 + socket 发送失败已是同一信号。
- 1.15 60 s PING 保活：会话只在一批 sweep 内用，空闲 5 min 自动登出，35 min 过期由重登兜底。
- 2.3 已识别但资料不全的复查：本仓只取文件身份，没有这一维度。
- 4.9 跨作品剔除已占用 TMDB 集：Shoko 默认关；本仓同作品内剔除。
- 4.5 相似度算法逐字照搬：阈值对齐，算法用本仓带全半角 / 繁简折叠的 Dice ∨ Levenshtein。

结构性差异：生产 registry 不装配 AniDB HTTP 资料链（CLAUDE.md 规则），Shoko「AniDB 集播出日 → TMDB 集」的原始输入本仓拿不到；②路径只有 AniDB 文件身份的三语集标题（无播出日），靠 4.8 的 en-US / 原语集名对齐。
