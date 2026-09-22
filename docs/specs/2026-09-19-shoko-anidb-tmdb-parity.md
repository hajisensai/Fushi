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
| 4.1 | 来源集 | AniDB 集（HTTP 资料：多语言标题 + 播出日） | ① MAL cour 分集（Jikan `aired` + 按资料语言选的标题）；② 本地文件 AniDB 身份里的三语集标题（**无播出日**） | 🟡 第三轮时生产 registry 不装配 AniDB HTTP 资料链，拿不到 AniDB 集播出日；② 只能靠标题 → 第四轮 UDP `EPISODE` 补播出日 → **第 10 节起 HTTP anime XML 装配为首选来源** |
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

结构性差异（第四轮已补，见第 7 节；第 10 节起 HTTP anime XML 成为首选、UDP `EPISODE` 兜底）：第四轮时生产 registry 不装配 AniDB HTTP 资料链，AniDB 集播出日改由 UDP `EPISODE` 逐集取得；②路径现在带播出日 + 三语集标题。

## 7. 第四轮（2026-09-20）：集级链接成为主判据 + 全面盘点

用户拍板「对齐 Shoko 的实现，并把剩下的差距也对齐」。本轮先补齐第 4 节的结构性缺口，再按两份盘点（AniDB 文件身份链 / TMDB 链接层）逐项处理。分支 `worktree-shoko-anidb-episode-link`，schema v109。

### 7.1 集级链接（`TmdbLinkingService.MatchAnidbToTmdbEpisodes` 主路径）

| # | 项 | Shoko | 本仓（本轮后） | 状态 |
|---|---|---|---|---|
| 7.1.1 | 文件落到哪一集 | AniDB 集身份（播出日 + 标题）在 TMDB 剧全部季里逐集对出来；文件名从不参与识别 | `linkAnidbEpisodesToTmdb`（`video_metadata_merge.dart`）+ 协调器 `_applyAnidbEpisodeLinks`：有 AniDB 身份的成员以链接结果为 (季, 集)，与文件名不符时按身份归位并记说明；无身份成员仍按文件名 | ✅ |
| 7.1.2 | AniDB 集播出日 | HTTP anime XML 全集自带 | UDP `EPISODE eid=`（`AnidbUdpFileClient.episode`，240/340，会话续期同 FILE）；FILE 命中后紧接着问一次，存量行 sweep 时补问回填；`anidb_file_identities.episode_aired_at` | ✅（第四轮：多一个 UDP 请求 / 新文件；第 10 节起 HTTP anime XML 首选、UDP 兜底） |
| 7.1.3 | 候选池 | 整剧非特典季；无偏移算术 | 同：整剧；Fribb 切片只用于把 TMDB (S,E) 换算成卡片键（卡片季 = cour），不再决定集号 | ✅ |
| 7.1.4 | TMDB (S,E) → 本地呈现 | 直接就是 S/E | 三步换算：TMDB 主源直用 / 卡片里已带该 TMDB id 的集 / Fribb 切片（`_cardKeyFromSlices`，越过 cour 已知集数不落）；都不行 → 链接成立但 `cardKey` 为 null、记说明、保留文件名键 | 🟡 卡片模型是 cour，不是 TMDB 季 |
| 7.1.5 | 特典 | `IsSpecialEpisode ? tmdbSpecialEpisodes : tmdbNormalEpisodes`；C/T/P/O 不匹配 | `matchSpecialsToTmdb`（S0 池、同一评分链）；`S<n>` 型 epno 落卡片 (0, E)、卡片无第 0 季就补一季；C/T/P/O 不进池；AniDB HTTP 解析器 `S` 型特典落第 0 季 | ✅ |
| 7.1.6 | `CrossRef_AniDB_TMDB_Episode` 持久化 | 独立表，UserVerified 保留 | 不建独立表（输入全在本地缓存、重算确定性）；落到 `video_metadata_episodes.anidb_episode_id / anidb_episode_number / anidb_match_rating`（随绑定写，换书 / 解绑清掉）。**第六轮（schema v111）补 UserVerified**：集卡菜单「手动指定季集…」写 `video_episode_binding_overrides`（`book_uid` → 季集）并立刻改绑分集行（`rebindVideoEpisodeToBook`，评级 `userVerified`）；刮削时协调器把它当最高优先级——`_applyAnidbEpisodeLinks` 跳过这些成员、`episodeOverrides` 以它为准、xref 评级写 `userVerified`；可清除回自动 | ✅ |
| 7.1.7 | 两套编号并存 | API 同时给 AniDB (type, epno) 与 TMDB (S,E) | 分集行三列 + 合集详情集卡序号下小字「AniDB 第 04 集」（`CollectionEpisodeCard.identityLabel`，i18n `collection_episode_anidb_number`）；序号本身仍是文件名 / 卡片键 | ✅ |
| 7.1.8 | firstAvailable | 第四遍「every match is accepted」，含 FirstAvailable | 第五轮起同样成链：`linkAnidbEpisodesToTmdb` 不再丢弃，评级 `firstAvailable` 随行落 `anidb_match_rating`、说明里标「顺序兜底 N」；`fillEmptySeasonsFromEpisodeTitles`（输入不是文件身份）仍丢弃 | ✅ |

### 7.2 AniDB 文件身份链（盘点 A）

| # | 项 | Shoko | 本仓（本轮后） | 状态 |
|---|---|---|---|---|
| 7.2.1 | FILE 掩码 | fmask `77 00 C0 D9 00`（aid/eid/gid/other eps/deprecated/state/quality/source/langs/描述/播出/文件名）+ amask 组名 | fmask `67 00 00 00 00`（aid/eid/other eps/deprecated/state）+ amask 三语作品名 / epno / 三语集名；不取 gid / 画质 / 语言 / 组名（刮削不消费） | ✅ 消费到的都取了 |
| 7.2.2 | 一文件多集 | `CrossRef_File_Episode` Percentage / EpisodeOrder，一文件绑多集 | 第五轮（schema v110）：`video_metadata_episodes.book_uid` 去掉列级 UNIQUE（alterTable 重建，FK OFF 夹住）；其余集的集号 / 播出日 / 三语集名由 `EPISODE eid=` 补问（`AnidbEpisodeShare.isResolved`，与主集播出日同一回填路径，落 `other_episodes` JSON 7 元组）并与主集同池进 TMDB 逐集链接；成链的落成同一文件的**额外绑定**（`AnidbAdditionalEpisodeBindings`，store `apply(additionalEpisodeBindings:)`），各带自己的 eid / 评级。进度仍按文件（`video_books`）记——看完一个文件两集都算完成，与 Shoko 同。合集详情页集卡把两集集名 / AniDB 集号用「 / 」并列；sidecar / 旧投影只跟主集 | ✅ |
| 7.2.3 | 过时 / CRC / 版本 | `deprecated` → IsCorrupted；state 位 CRCMatch/CRCErr/IsV2…；重扫补资料 | `isDeprecated` / `fileState`（`crcMatches` / `fileVersion`）落库并写进识别说明；不做周期重问 FILE（Shoko 也只在资料缺失时） | ✅ |
| 7.2.4 | 特典类型 | EpisodeType 枚举，S/C/T/P/O 都存 | `S` 型进 S0 链接；C/T/P/O 身份照存（epno 原文）、不进池、按文件名落 | ✅（与 Shoko 匹配面一致） |
| 7.2.5 | 哈希 / 搬家 / MAL 映射 / 关系 / 复查节奏 | — | 盘点结论：等价或更强（红蓝双 ED2K、`(ed2k,size)` 键、Fribb 一对多显式确认、320 每日 ≤15 次）；`<relatedanime>` 只服务 Shoko 的分组，本仓无分组概念 | ✅ / 不适用 |

### 7.3 TMDB 链接层（盘点 B）

| # | 项 | Shoko | 本仓（本轮后） | 状态 |
|---|---|---|---|---|
| 7.3.1 | 成人向 | `AutoLinkRestricted` + 搜索 `include_adult = anime.IsRestricted` | `VideoMetadataSearchRequest.includeAdult` → `include_adult=true`，主源分级 MAL `Rx` / AniDB `R18+` 时打开（MAL 作品补 `contentRating`）；无单独开关（默认过滤即 Shoko 的 AutoLinkRestricted=false 语义） | ✅ |
| 7.3.2 | 刷新节奏 | `UpdateShow` 1 h 跳过窗口 + 每日 `/tv/changes` 增量（14 天窗口）+ 过期整拉 | `VideoLibraryScrapeSweep` 加刷新积压：`TmdbVideoMetadataProvider.changedTvShowIds`（`/tv/changes` 按 13 天窗口分页）每 12 h 问一次、与库内 TMDB id 求交集只重刷变过的；上次刮削 >14 天的整部重刷、每轮 ≤20 部 | ✅ |
| 7.3.3 | 链接卫生 | 刷新后重跑集级匹配，UserVerified 保留，孤儿 xref 清理 | 重刷走 `scrapeWorkSubsets`：已确认身份复用、集级链接按新资料重算、分集行整季替换（xref 随绑定重写，解绑即清） | ✅ |
| 7.3.4 | 电影型 / 多作品 | AniDB 作品类型决定形态；一个目录几部作品就是几个 series；电影链 `CrossRef_AniDB_TMDB_Movie` | 第五轮拆电影；**第六轮泛化为 `_splitByAnidbWork`**：成员哈希分属不同 AniDB 作品（全部成员都有身份）→ 电影型成员各自成单文件电影单元，其余每个 AniDB 作品**新建一个播放列表合集**收下该组成员当 `collection:` 剧集单元（Shoko 多 series 的合集等价物），身份按主源顺序给或让子单元自己识别；原播放列表视频成员全被拆走时 `deleteMediaCollectionWithAssets` 整删（写墓碑，重扫不按原名重建），否则只移走已拆成员并清合集级残留；重扫归组器不再把已属别的播放列表的文件按 overlap 并回。**形态来源对齐**：FILE amask 加 anime type（`anidb_file_identities.anime_type`，v111），单文件单元哈希决定身份时 kind 跟 AniDB `Movie`/非 Movie 走，Fribb `isMovie` 只作旧行兜底。目录合集本就不进剧集单元（计划器把目录成员各自当 `book:`），不在此路径 | ✅ |
| 7.3.5 | TMDB 备选排序 | `TMDB_AlternateOrdering` 下载 + 每剧 `PreferredAlternateOrderingID`，API 按它给 S/E | 第五轮：`VideoMetadataEpisodeGroupProvider.listEpisodeGroups`（`/tv/{id}/episode_groups` 全部类型）经 `VideoSourceScrapeEpisodeOrdering` / controller 暴露；合集详情页菜单「TMDB 集编排…」列分组 + 「TMDB 默认排序」单选（`video_tmdb_ordering_dialog.dart`），选定写作品行 `episode_group_id` 并上 `episodeGroup` 字段锁（`setVideoMetadataWorkEpisodeGroup`；刮削不再用自动挑的分组覆盖）→ 以既有身份重刮，`_hydrateWork` 拿到的季集即分组编排、AniDB 集级链接按它重算；分组模式下 Fribb 切片停用（两套编号对不上）、集名别名按默认季拉再换回分组集号。不自动挑非 type=6 的分组（与 Shoko 一样由用户选） | ✅ |
| 7.3.6 | 图片 / 网络 / 公司 / 多语言标题 | 各类型上限（`MaxAutoPosters/Backdrops/Logos` 默认 10，0 不限）、语言序 `[None, Main, English]`、`AutoDownloadStaffImages`、公司 logo | 第六轮：全局偏好 `video_metadata_max_covers/backdrops/logos`（默认 10，0 不限；设置页三个步进器）进 `VideoSourceScrapeGlobalConfig` + 指纹，`selectVideoMetadataImages(maxPerKind:)` 按上限保留、同 URL 去重、剧照恒 1；原语 `Main` 槽：`imageLanguageOrderWithMain` 把作品原语插在资料语言之后英文之前（保留本仓「资料语言最先」的既定行为），TMDB provider 在原语不在资料语言序时按原语补拉一次 `/images`；演职员头像 `video_metadata_download_staff_images`（默认关，与 Shoko `AutoDownloadCrewAndCast=false` 的净效果一致）开了落 `<video_covers>/people/`、回写 `profile_path`、每部 ≤10。**公司 logo 仍不落**：模型 `studios` 是字符串、无消费点 | ✅ / 🟡 公司 logo |

### 7.4 本轮新增守卫 / 测试

`anidb_udp_file_client_test.dart`（EPISODE 5 条 + FILE 列 5 条）、`anidb_hash_identity_service_test.dart`（播出日回填 4 条 + other_episodes 编解码）、`tmdb_episode_matcher_test.dart`（特典池 + 链接换算 7 条）、`tvdb_season_offset_coordinator_test.dart`（Bleach 端到端：文件名 S17E12 / S00E02 错、哈希身份对 → 按身份归位；分集行 xref）、`anidb_video_metadata_provider_test.dart`（第 0 季）、`video_metadata_provider_contract_test.dart`（include_adult、/tv/changes 分页与 14 天窗口）、`video_library_scrape_sweep_test.dart`（刷新探针 / 过期 / 上限 / 探针失败）、`migration_v109_anidb_episode_aired_at_test.dart`。

## 8. 第五轮（2026-09-20）：把第四轮留作待决策的三项也对齐

用户目标「全量对齐 Shoko」。本轮落地 7.1.8（firstAvailable 成链）、7.2.2（一文件多集，schema v110）、7.3.4（电影型作品按 AniDB 作品拆分）、7.3.5（TMDB 备选排序用户选择），各行状态已就地更新。仍有意保留的差异只剩 7.3.6（图片张数上限 / 原语槽 / 人物·公司图——资料呈现量的偏好，不影响识别与链接）与 7.3.4 里的「电视剧混放」（剧集作品以合集为锚，一合集只能有一部；Shoko 按 AniDB 作品建多个 series）。

### 8.1 本轮新增守卫 / 测试

- `migration_v110_episode_book_multi_binding_test.dart`：v109 → v110 重建表去 UNIQUE、既有行 / id / 子表引用保留、同一文件再绑第二集不撞约束、唯一自动索引消失 + 普通索引在；fresh 库一文件两行。
- `anidb_udp_file_client_test.dart`：EPISODE 240 三语集名。
- `anidb_hash_identity_service_test.dart`：其余集经 EPISODE 补集号 / 集名 / 播出日并落库，340 的留待下次；`other_episodes` 7 元组编解码。
- `tmdb_episode_matcher_test.dart`：firstAvailable 成链、落锁定季下一条空位、评级保留。
- `tvdb_season_offset_coordinator_test.dart`：顺序兜底成链 + 评级落行 + 说明；一文件多集额外绑定（各带自己的 eid / 评级、`getVideoMetadataEpisodesByBook` 两行）；两部剧场版一目录 → 拆成两部电影作品（合集级作品行不存在、各自 MAL + AniDB 身份、说明）。
- `video_metadata_provider_contract_test.dart`：`listEpisodeGroups` 全类型 / 电影空表；分组模式集名别名按默认季拉再换回分组集号。
- `video_metadata_locked_fields_test.dart`：`setVideoMetadataWorkEpisodeGroup` 写排序 + 上锁，apply 不覆盖，选回默认同样锁住。
- `video_tmdb_ordering_dialog_test.dart`：选分组 → 写行 + 锁 + 以带分组 id 的 lookup 重刮；选回默认；取消不动。
- `video_library_scrape_sweep_test.dart`：成员各自拥有带身份的电影作品行的合集单元算已识别。

## 9. 第六轮（2026-09-20）：第五轮尾表里「仍未对齐」的五项

用户目标仍是「全量对齐 Shoko」，把第五轮尾表列出的五项也做掉：电视剧混放拆分（7.3.4 泛化）、图片上限 / 原语槽 / 人物图（7.3.6）、集级 UserVerified 手动链接（7.1.6）、互联 host 端备选排序、作品 kind 来自 AniDB 动画类型（7.3.4）。schema v111（`anidb_file_identities.anime_type` + `video_episode_binding_overrides`）。

互联面：`VideoMetadataOrderingHost`（`listVideoMetadataEpisodeGroups` / `setVideoMetadataEpisodeGroup`）经 `POST /api/library/metadata/episode-groups` / `episode-group` 暴露，能力位 `liveLibrary.videoMetadataOrdering`；客户端 `InterconnectSyncBackend.listRemoteVideoMetadataEpisodeGroups / setRemoteVideoMetadataEpisodeGroup`，远端合集详情页菜单「在 host 上选择 TMDB 集编排…」复用同一张 `showVideoTmdbOrderingPicker`，host 回传 entry 落本地镜像；老 host 404 → 「对端不支持」。

第六轮结束时仍保留的差异：① 生产 registry 不装配 AniDB HTTP 资料链，播出日走 UDP `EPISODE`；② 作品资料主源 MAL / TMDB 用户可选、AniDB 只做身份；③ 公司 logo 不落；④ 图片语言序「资料语言最先」；⑤ 无独立 CrossRef 表。①② 在第 10 节按 Shoko 对齐；③④⑤ 用户 2026-09-20 拍板保持不变。

### 9.1 本轮新增守卫 / 测试

- `migration_v111_anime_type_episode_pin_test.dart`：v110 → v111 加列建表、持久层写读 `anime_type`、`rebindVideoEpisodeToBook` 改绑 + 身份随文件走 + 目标不存在不动 + 清除 + FK 级联。
- `tvdb_season_offset_coordinator_test.dart`：两部电视剧一个播放列表 → 拆成两个合集各自刮、原合集删除带墓碑；电影拆分改为整删原合集；用户钉死的季集胜过 AniDB 链接且评级 `userVerified`。
- `anidb_udp_file_client_test.dart`：FILE 14 列（anime type）。
- `video_folder_group_coordinator_test.dart`：已属别的播放列表的文件重扫不并回。
- `video_episode_binding_dialog_test.dart`：选集写钉 + 立刻改绑；清除；无季集提示。
- `video_metadata_merge_test.dart`：每类上限 / 0 不限 / 剧照恒 1 / 同 URL 去重 / 原语槽次序与落选。
- `anidb_hash_config_test.dart`：图片上限与人物图偏好读取（负数回默认）、进指纹。
- `video_metadata_provider_contract_test.dart`：原语不在资料语言序时补拉一次 `/images`，重复 URL 不进池。
- `settings_schema_coverage_test.dart`：四个新设置项登记专项覆盖。
- `interconnect_video_metadata_ordering_host_test.dart`：能力位、列分组 + current、设排序写行 / 上锁 / 带分组 lookup 重刮、选回默认、无 TMDB 身份空表、未知键 409、坏 groupId 400。

## 10. 第六轮 b（2026-09-20）：AniDB 主源 + HTTP anime XML 链 + MAL 交叉引用

用户对第六轮尾表五项的决定：「1. 路径差异按照 Shoko 的走 2. 按照 Shoko 的走 3、4、5 保持不变」；随后「刮削直接砍掉 MAL」又改为「不砍 MAL，按 Shoko 的做法看是否要加」——Shoko 的形态是 AniDB 识别 / 组织（必需）+ TMDB 补充 + MAL 只作交叉引用 id，据此落地：

| # | Shoko | Fushi（本轮） | 状态 |
|---|---|---|---|
| 10.1 | `AnidbService.GetAnime`：`AnimeDoc_{aid}.xml` 落盘，`MinimumHoursToRedownloadAnimeInfo`=24h 内直接用；过期才远程；远程失败 / 封禁回旧 XML | `AniDbVideoMetadataProvider(xmlCacheDirectory:)` → `<support>/anidb_anime/AnimeDoc_{aid}.xml`，`_loadAnime` 同一取数顺序；生产 registry 装配 AniDB provider（client 仍是随包 `fushiplayer` / 用户自定义，进程级 2s+ 限流闸不变） | ✅ |
| 10.2 | 集播出日 / 集名来自本地 `AniDB_Episode` 表（整部作品一次 HTTP） | `AnidbHashIdentityService(episodeInfoSource:)` 先问 `AniDbVideoMetadataProvider.episodeInfo(aid, eid)`（XML），拿不到才 UDP `EPISODE`；一文件多集的其它集同路径 | ✅ |
| 10.3 | 默认主源 AniDB；`SeriesTitleSourceOrder=[AniDB,TMDB]`、`DescriptionSourceOrder=[TMDB,AniDB]` | `kDefaultVideoMetadataPrimaryProvider = anidb`，`kSelectableVideoMetadataProviders = [anidb, mal, tmdb]`，`videoMetadataFallbackProvider(anidb) = tmdb`（TMDB 恒为补充：AniDB 主源无条件跑 `_tmdbSupplement`，简介按资料语言感知择优；MAL 主源仍缺项才补）；设置页下拉由白名单生成，`video_metadata_provider_anidb` 文案 | ✅ |
| 10.4 | 哈希 aid = series 身份，与 MAL 无关 | AniDB 主源：`hashLookup` = `anidb:<aid>`，`hashMappingAmbiguous` 只在非 AniDB 主源成立（Fribb 一对多不算歧义）；`_splitByAnidbWork` 拆出的单元直接给 `anidb` lookup；离线标题索引命中 AniDB 也直接成身份 | ✅ |
| 10.5 | `CrossRef_AniDB_MAL`：anime XML `<resources type="2">` | `_parseAnime` 收 `malIds`，`_mapAnime` 落 `VideoMetadataId(type: 'mal', isDefault: false)`；Fribb 的一对多 MAL 映射**不**落交叉引用 | ✅ |
| 10.6 | `MatchAnidbToTmdbEpisodes` 来源池 = 整部作品的 AniDB 集 | AniDB 主源：`_anidbWorkLinkSources` = 文件身份集 ∪ anime XML 全集（同一集合并集名 / 播出日，`fetchEpisodeTitleAliases` 给全部语言集名）；其它主源仍只有有身份的文件那几集 | ✅ |
| 10.7 | `TmdbSearchService` 沿 Prequel 链回溯根作品搜 TMDB 剧 | `AniDbVideoMetadataProvider implements VideoMetadataRelationsProvider`：`fetchPrequels` 读 `<relatedanime type="Prequel">`，`_prequelRootTitles` 对 AniDB 主源也生效 | ✅ |
| 10.8 | 切换资料源不重识别既有 series | `acceptsCanonical` / resolver `_acceptsIdentity` / `searchManualCandidates`：来自三家可选主源的已确认 / 落库 / NFO 默认 / 显式 / 手动身份一律直取，不因默认主源变化换源重搜；`primaryLookupForWork` 只认 `isPrimary` 行为「旧主源」（NFO 索引出的纯交叉引用不算退役、提示保留）；`<movie>` NFO 的 TMDB id 不进剧集单元的规范身份 | ✅ |
| 10.9 | MAL 只是交叉引用 | MAL provider 保留可选主源（MAL ↔ TMDB 互为兜底）；AniDB 主源下不参与识别、不落 Fribb 映射 | ✅（用户决定：不砍） |
| ③④⑤ | 公司 logo / 图片语言序 `[None, Main, English]` / 独立 CrossRef 表 | 不落 / 「资料语言最先」`[locale, Main, en, '']` / 分集行内联交叉引用 | 保持不变（用户拍板） |

### 10.1 本轮新增 / 改写守卫与测试

- `anidb_provider_shoko_chain_test.dart`（新）：MAL 交叉引用只收 type 2 且非默认；前传只收 Prequel；逐集全部语言别名（季 0 = 特典，季 2 空）；`episodeInfo` 正片 / `S` 型特典 / 不在作品里 → null、一次请求；磁盘缓存：下载落盘 + 新实例 24h 内零请求、过期重下失败回旧 XML、成功覆盖、封禁回旧、无缓存时作品层 catalog-only + 集层抛网络异常；身份服务 XML 优先、XML 空 / 抛错退 UDP。
- `anidb_primary_coordinator_test.dart`（新）：默认主源 AniDB + 哈希 aid（Fribb 一对多）直接成身份、MAL 零调用、TMDB 补充；无哈希按 AniDB 标题识别 + TMDB 交叉引用；存量 MAL 主身份在 AniDB 默认下原样保留；AniDB 文件身份决定 TMDB (季, 集)（与文件名相反的绑定）。
- `video_source_scrape_coordinator_test.dart`：「registry 缺 AniDB 即 fail closed」改为「TMDB 按兜底源识别」；手动 `tmdb=` / `mal=` 不再是格式错误；「退役 provider 交叉引用保留」在 AniDB 双源语义下仍成立（`primaryLookupForWork` 修法）；`<movie>` NFO TMDB id 不进 TV 命名空间（新形态门）。
- `mal_hash_coordinator_test.dart`：夹具 `provider_override` 由历史值 `anidb` 改为显式 `mal`；三条「退役 AniDB 主身份」改为「既有 AniDB 主身份在 MAL 来源下保持规范、TMDB 只补充」；「不同作品要人工确认」改为第六轮的「按 AniDB 作品拆合集」语义（该用例自第六轮起已红，本轮补正）。
- `video_metadata_production_registry_test.dart` / `video_source_scrape_provider_override_test.dart` / `video_source_scrape_global_settings_test.dart`：白名单三家、默认 AniDB、`anidb` 可解析、AniDB → TMDB 兜底、AniDB 身份 URL 直取。
- 其余 MAL 形态的协调器用例显式传 `primaryProvider: VideoMetadataProviderKind.mal`。
