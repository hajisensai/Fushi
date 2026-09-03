## BUG-1891 · Emby/Jellyfin 一进视频页就全库递归枚举且带 MediaSources 重字段
- **报告**：2026-08-27（用户：「能不能把 emby 做成不刮削的那种，或者让用户可以自定义。tg 上买的 emby 服都是几十万视频的资源，添加进去直接开始刮削，会卡死，而且会封号。」）
- **真实性**：✅ 真 bug，**但用户看到的不是刮削**。

  先排除刮削嫌疑，三条独立证据：① Jellyfin/Emby 不是 `MediaSources` 表的行，走不到来源级刮削管线（`VideoSourceScrapeSettings` 按 `media_sources.id` 挂）；② 本地 sidecar sweep 明确排除 http/https 路径（`fushi/lib/src/media/metadata/auto_scrape_service.dart:148-163` 的 `_isLocal`）；③ 远端条目只渲染成占位卡、不落 `VideoBooks`，不进任何刮削判据集合。接入 Emby **不会**触发 AniDB/TMDB/NFO 任何一条。

  真实根因是**登录后一进视频页就对整台服务器做全库递归枚举，并且带了 Emby 上最重的 `Fields=MediaSources`**。在几十万条目的服务器上，这个行为和刮削在观感与服务器负载上完全一致（几十~上百个重查询连发 → 触发 Emby 的滥用检测/风控）。

  触发链（行号为修复前）：
  - `fushi/lib/src/pages/implementations/home_video_page.dart:365` `initState` → `_loadRemoteVideos()`
  - `:404` `onTabActivated` → 每次切回视频 tab 再来一轮
  - `:490` `_refresh(remote: true)` / `:519` `_pullToRefresh(forceRefresh: true)`（绕 TTL）/ `:5113` 合集详情
  - → `fushi/lib/src/sync/jellyfin_video_client.dart:784-791` `listRemoteVideos()` → `api.recursiveVideoItems(userId)`
  - → `fushi/lib/src/sync/jellyfin_video_client.dart:399-425` `recursiveVideoItems`，**全库递归**：
    - `:414` `'Fields': 'ProductionYear,MediaSources'` —— **单次请求昂贵的真正原因**：服务器要为每一条目展开 MediaSource/MediaStream（Emby 侧还含外挂字幕文件的磁盘探测）；
    - `:285` `kMaxRecursiveItems = 20000` 在几十万库上不是保护，是**静默截断 + 仍然打 40 次重查询**；
    - 页与页之间**零间隔**（爬虫特征），`_getJson` 只有 15s 超时；
    - `parentId` 参数存在但 `:786` 调用点不传——`views()`（`:366-369`）与 `isVideoish`（`:135-138`）早就实现却没被用上。
  - 现有开关都够不着：`show_remote_entries` 是全局闸（会连带关掉互联/云盘远端卡）、`video_auto_scrape` 只管本地 sidecar sweep、`VideoSourceScrapeSettings` 按 MediaSource 行挂而 Jellyfin 根本不是那种行。

- **[x] ① 已修复** — 四条按重要性排列，全部落在根因上，没有加延迟/重试/特例分支绕过：

  **1. 清单不再要 `MediaSources`（`jellyfin_video_client.dart`）。** `recursiveVideoItems` 的 `Fields` 收成 `'ProductionYear'`。功能一件没砍，只是把重字段从「列表阶段 N 次重查询」改成「单条目用到时 1 次」：
  - 新增可选能力接口 `RemoteVideoDetailFetch`（`fushi/lib/src/sync/remote_video_client.dart`，与既有 `RemoteVideoPlaybackSync` 同一分级理由——不并进 `RemoteVideoClient`，否则十几个测试 fake 要补恒等实现），`JellyfinVideoClient.remoteVideoDetail()` 打一次 `/Items/{id}` 拿全量 MediaSources；
  - 消费点两处（`home_video_page.dart`）：下载入库前的 `_downloadRemoteSubtitleForBook` 在 `subtitleFileName == null` 时先补齐（**这条是必须的**——文件名为空会让按扩展名选解析器那行恒落 `srt`，ASS 轨会被 srt 解析器解成 0 条 cue），远端信息弹窗 `_showRemoteVideoInfo` 用 `FutureBuilder` 先渲染清单值、详情到了原地补上文件大小；
  - 清单卡的字幕角标退回服务器的粗粒度 `HasSubtitles`（会把 PGS/DVDSub 图形轨也算 true）——这是 `parseItem` 里**本来就写好的回落分支**，且下载路径靠上面的补齐把它纠回精确值，真正会出错的那条路径没有退化。

  **2. 枚举面收窄到媒体库视图。** 新增 `JellyfinVideoClient.resolveEnumerationParents()`，三档从窄到宽：用户点名的库 → `/Users/{uid}/Views` 里 `isVideoish` 的库（滤掉音乐/图书/照片） → `[null]` 整库递归兜底（Views 失败/为空时，宁可多扫也不能让用户的库整个消失）。跨库按条目 id 去重。

  **3. 每服务器的库点名 + 全局的「自动列出」开关。**
  - `JellyfinServerConfig.libraryIds`（`copyWithLibraryIds` / toJson / fromJson，脏值过滤）随服务器配置整条落 `sync_jellyfin_server`；
  - `PreferencesRepository.jellyfinAutoListVideos`（键 `jellyfin_auto_list_videos` 已进 `preference_keys.dart` 字母序白名单）；
  - 闸门是顶层纯函数 `shouldFetchRemoteVideoList()`（`home_video_page.dart`），`_readRemoteVideoList` 是唯一调用点；关掉后进页面**一个请求都不发**，改读 `RemoteLibraryCache.peek()`（新增，纯读不取数、不看 TTL）把上一次手动刷新的清单留在屏幕上；
  - 设置 UI 在 `fushi/lib/src/sync/jellyfin_settings_widget.dart`（已登录态：`AdaptiveSettingsSwitchRow` + 媒体库勾选面板，改选择即失效该服务器的远端清单槽）。新 i18n key 5 条（`jellyfin_auto_list_title/_hint`、`jellyfin_libraries_title/_hint/_load_failed`）经 `tool/i18n_sync.dart --add` 进 17 语。

  **4. 分页节流 + 截断可见。** `JellyfinApi.kPageInterval = 150ms` 插在页**之间**（第一页不等，小库 3 页只多 300ms）；`recursiveVideoItems` 改返回 `JellyfinRecursiveResult{items, truncated, totalCount}`，撞上 `kMaxRecursiveItems` 时 `listRemoteVideos` 打日志说明「拿到的不是全部、去设置里点名媒体库」，不再假装拉全了。

  **默认值取舍（Never break userspace）**：
  - `jellyfinAutoListVideos` **默认 true**。绝大多数用户是自建小库（几百到几千条），自动列出正是他们要的体验；改默认等于把所有人的远端卡片关掉去迁就少数超大公共服用户。大库用户有开关可以止血，小库用户零感知。
  - `libraryIds` **默认空 = 全部视频域媒体库**（不是「整台服务器」）。可见结果与整库递归一致——`IncludeItemTypes=Movie,Episode` 本来就只在视频库里有命中，所以这一档是**纯减负、零可见变化**；音乐/图书/照片库不再被白扫。
  - 库 id 是**每服务器的 GUID**，所以 `libraryIds` 刻意落在 `JellyfinServerConfig` 的 JSON 里（登出随 `sync_jellyfin_server` 一起删）而不是全局偏好表——放全局键会让 A 服务器的库 id 在换服务器后继续生效，枚举出空库。反过来「自动列出」是用户对枚举行为的取舍、与服务器身份无关，所以它才是全局偏好。

- **[x] ② 已加自动化测试** —
  - 新增 `fushi/test/sync/jellyfin_enumeration_gate_test.dart`（15 条，真 DB + 真缓存）：[A] 偏好键已登记/默认 true/写读回并通知；[B] `libraryIds` 随服务器配置往返、旧配置读成空、`copyWithLibraryIds` 不动凭据、脏 JSON 过滤；[C] `RemoteLibraryCache.peek` 命中不取数 / 不看 TTL / 失效后返 null / 空槽返 null；[D] `shouldFetchRemoteVideoList` 四格真值表。
  - 改写 `fushi/test/sync/jellyfin_video_client_hardening_test.dart`：[2] 加「分页之间有最小间隔」（fake_async）与截断 `truncated` 断言；[3] 整组重写成「清单 `Fields=ProductionYear` 且**全程没有一条请求要过 MediaSources**、重字段由 `remoteVideoDetail` 按需补齐、PGS 图形轨在详情侧被纠回 false」；新增 [8] 组：默认只递归视频域库（音乐/图书不被扫）、点名后连 Views 都不问、Views 失败退回整库递归、跨库去重。
  - `fushi/test/sync/jellyfin_video_client_test.dart` 的 `listRemoteVideos` 用例补上 Views 分流。
  - **变异实测（python 精确锚点替换 + sha256 前后比对，未用 `git checkout`）11 条，全部被杀，无一存活**：`Fields` 加回 `MediaSources` → [3] 红；`libraryIds` 分支短路 → [8] 点名用例红；`views` 分支短路 → [8] + 基础用例红；`truncated` 恒 false → [2] 熔断用例红；`kPageInterval` 改 `Duration.zero` → [2] 节流用例红；去重条件删掉 → [8] 去重用例红；闸门恒 true / 删掉 `forceRefresh` 短路 → [D] 对应格各红一条；偏好默认改 false → [A] 红；`peek` 的 `maxAge` 判据短路 → [C] 红；`toJson` 丢掉 `libraryIds` → [B] 红。每条还原后四个被改文件的 sha256 均回到基线（`jellyfin_video_client.dart` = `548358ca8a7d7228a5a653e8246ca787d1fbae4279c169aa83a28f87241b111a`）。
  - 回归面：`test/models/preference_keys_guard_test.dart`、`test/settings/md3_design_system_static_test.dart`、`test/i18n`、10 个 `home_video_*remote*` / `remote_library_cache` 用例全绿；`flutter analyze`（整个 `fushi`）零问题。

- **备注**：
  - **真机验证缺口**：没有对着真 Emby/Jellyfin 服务器复测原始失败路径（用户已取消真机验证环节）。未验证的具体项是：几十万条目服务器上收窄后的实际请求量与耗时、Emby 对 `Fields=ProductionYear` 的响应确实带 `HasSubtitles`（Jellyfin 侧是 BaseItemDto 基础字段，Emby 同源兼容，但没有实测样本）、以及设置页媒体库勾选面板在真服务器上的 Views 返回形态。Dart 侧全链路由上述离线测试覆盖。
  - 截断目前只落 `debugPrint`，没有 UI 提示。要真正告诉用户「你的库有 30 万条、只列了 2 万」需要把 `truncated` 沿 `RemoteLibraryCache` 一路带到库页横幅，那是另一条改动面；本轮先把「静默」变成「日志里看得见」。
  - 清单卡的字幕角标现在会把 PGS/DVDSub 图形轨也算成「有字幕」（服务器 `HasSubtitles` 的粗粒度语义）。这是用「列表阶段 N 次重查询」换来的，下载路径已按详情纠回精确值，不会出现「以为有字幕结果下不下来」。
