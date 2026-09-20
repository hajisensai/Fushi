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

结构性差异（第四轮已补，见第 7 节）：生产 registry 不装配 AniDB HTTP 资料链（CLAUDE.md 规则），AniDB 集播出日改由 UDP `EPISODE` 逐集取得；②路径现在带播出日 + 三语集标题。

## 7. 第四轮（2026-09-20）：集级链接成为主判据 + 全面盘点

用户拍板「对齐 Shoko 的实现，并把剩下的差距也对齐」。本轮先补齐第 4 节的结构性缺口，再按两份盘点（AniDB 文件身份链 / TMDB 链接层）逐项处理。分支 `worktree-shoko-anidb-episode-link`，schema v109。

### 7.1 集级链接（`TmdbLinkingService.MatchAnidbToTmdbEpisodes` 主路径）

| # | 项 | Shoko | 本仓（本轮后） | 状态 |
|---|---|---|---|---|
| 7.1.1 | 文件落到哪一集 | AniDB 集身份（播出日 + 标题）在 TMDB 剧全部季里逐集对出来；文件名从不参与识别 | `linkAnidbEpisodesToTmdb`（`video_metadata_merge.dart`）+ 协调器 `_applyAnidbEpisodeLinks`：有 AniDB 身份的成员以链接结果为 (季, 集)，与文件名不符时按身份归位并记说明；无身份成员仍按文件名 | ✅ |
| 7.1.2 | AniDB 集播出日 | HTTP anime XML 全集自带 | UDP `EPISODE eid=`（`AnidbUdpFileClient.episode`，240/340，会话续期同 FILE）；FILE 命中后紧接着问一次，存量行 sweep 时补问回填；`anidb_file_identities.episode_aired_at` | ✅（多一个 UDP 请求 / 新文件；HTTP anime 链仍不装配） |
| 7.1.3 | 候选池 | 整剧非特典季；无偏移算术 | 同：整剧；Fribb 切片只用于把 TMDB (S,E) 换算成卡片键（卡片季 = cour），不再决定集号 | ✅ |
| 7.1.4 | TMDB (S,E) → 本地呈现 | 直接就是 S/E | 三步换算：TMDB 主源直用 / 卡片里已带该 TMDB id 的集 / Fribb 切片（`_cardKeyFromSlices`，越过 cour 已知集数不落）；都不行 → 链接成立但 `cardKey` 为 null、记说明、保留文件名键 | 🟡 卡片模型是 cour，不是 TMDB 季 |
| 7.1.5 | 特典 | `IsSpecialEpisode ? tmdbSpecialEpisodes : tmdbNormalEpisodes`；C/T/P/O 不匹配 | `matchSpecialsToTmdb`（S0 池、同一评分链）；`S<n>` 型 epno 落卡片 (0, E)、卡片无第 0 季就补一季；C/T/P/O 不进池；AniDB HTTP 解析器 `S` 型特典落第 0 季 | ✅ |
| 7.1.6 | `CrossRef_AniDB_TMDB_Episode` 持久化 | 独立表，UserVerified 保留 | 不建独立表（输入全在本地缓存、重算确定性）；落到 `video_metadata_episodes.anidb_episode_id / anidb_episode_number / anidb_match_rating`（随绑定写，换书 / 解绑清掉）；手动指定作品身份即 UserVerified，集级手动链接没有 UI | 🟡 |
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
| 7.3.4 | 电影型作品 | AniDB 集 → TMDB 电影（`CrossRef_AniDB_TMDB_Movie`，≤4 集短篇先搜电影再退剧） | **未做**。本仓 kind 由本地文件形状决定（多文件 = tv）；三部剧场版一个目录时哈希给出三个不同 aid → 现报「成员分属不同作品，请拆分合集」。要对齐得让协调器在「成员分属不同 AniDB 作品且各自映射 Fribb 电影条目」时按成员拆成独立电影作品——涉及计划器 / works 表以合集为锚的持久模型，需先拍板卡片形态 | ❌ 待决策 |
| 7.3.5 | TMDB 备选排序 | `TMDB_AlternateOrdering` 下载 + 每剧 `PreferredAlternateOrderingID`，API 按它给 S/E | 第五轮：`VideoMetadataEpisodeGroupProvider.listEpisodeGroups`（`/tv/{id}/episode_groups` 全部类型）经 `VideoSourceScrapeEpisodeOrdering` / controller 暴露；合集详情页菜单「TMDB 集编排…」列分组 + 「TMDB 默认排序」单选（`video_tmdb_ordering_dialog.dart`），选定写作品行 `episode_group_id` 并上 `episodeGroup` 字段锁（`setVideoMetadataWorkEpisodeGroup`；刮削不再用自动挑的分组覆盖）→ 以既有身份重刮，`_hydrateWork` 拿到的季集即分组编排、AniDB 集级链接按它重算；分组模式下 Fribb 切片停用（两套编号对不上）、集名别名按默认季拉再换回分组集号。不自动挑非 type=6 的分组（与 Shoko 一样由用户选） | ✅ |
| 7.3.6 | 图片 / 网络 / 公司 / 多语言标题 | 各类型上限、`Main` 原语槽、people/studio 图 | 每层每类 1 张（backdrop ≤3）、语言序 `[locale, en, '']`、无原语槽 | 🟡 低价值，不动 |

### 7.4 本轮新增守卫 / 测试

`anidb_udp_file_client_test.dart`（EPISODE 5 条 + FILE 列 5 条）、`anidb_hash_identity_service_test.dart`（播出日回填 4 条 + other_episodes 编解码）、`tmdb_episode_matcher_test.dart`（特典池 + 链接换算 7 条）、`tvdb_season_offset_coordinator_test.dart`（Bleach 端到端：文件名 S17E12 / S00E02 错、哈希身份对 → 按身份归位；分集行 xref）、`anidb_video_metadata_provider_test.dart`（第 0 季）、`video_metadata_provider_contract_test.dart`（include_adult、/tv/changes 分页与 14 天窗口）、`video_library_scrape_sweep_test.dart`（刷新探针 / 过期 / 上限 / 探针失败）、`migration_v109_anidb_episode_aired_at_test.dart`。
